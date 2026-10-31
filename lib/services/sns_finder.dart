import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/place.dart';
import 'overpass_service.dart';

/// 配信データの範囲外（Overpass API から取得した場所）の学校・施設について、
/// Wikidata の SNS アカウント（Instagram・X など）と公式サイトに掲載されたリンクから
/// アカウントを探す。結果は端末に保存し、30 日間は再確認しない。
class SnsFinder {
  SnsFinder({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _maxAge = Duration(days: 30);
  static const _maxSitesPerRun = 40;
  static const _parallelSites = 4;

  /// Wikidata のプロパティと SNS の対応。
  static const _wikidataProps = {
    'P2003': SnsPlatform.instagram,
    'P2002': SnsPlatform.x,
    'P2013': SnsPlatform.facebook,
    'P7085': SnsPlatform.tiktok,
    'P11245': SnsPlatform.youtube,
    'P2397': SnsPlatform.youtube,
    'P11892': SnsPlatform.threads,
    'P12361': SnsPlatform.bluesky,
  };

  final _cache = <String, _Found>{};
  File? _file;
  bool _loaded = false;

  /// 確認済みの結果。未確認なら null。
  List<SocialLink>? cached(String placeId) {
    final found = _cache[placeId];
    if (found == null || DateTime.now().difference(found.checkedAt) > _maxAge) return null;
    return found.links;
  }

  /// [places] のうち未確認のものを調べ、見つかるたびに [onFound] を呼ぶ。
  /// 配信データの場所はサーバー側で確認済みなので対象外。
  Future<void> find(
    List<Place> places, {
    required void Function(String placeId, List<SocialLink> links) onFound,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await _load();
    final targets =
        places.where((p) => p.isInstitution && !p.isListing && !p.precomputed && cached(p.id) == null).toList();
    if (targets.isEmpty) return;

    // 1. Wikidata（まとめて問い合わせられるので先に）
    final wikidata = await _fromWikidata(targets.where((p) => p.wikidata != null).toList());
    for (final p in targets) {
      final links = wikidata[p.id]?.links ?? const <SocialLink>[];
      if (links.isNotEmpty) onFound(p.id, links);
    }

    // 2. 公式サイト（OSM の website、なければ Wikidata の公式サイト）
    final sites = <(Place, String)>[
      for (final p in targets)
        if (p.website ?? wikidata[p.id]?.website case final url?) (p, url),
    ].take(_maxSitesPerRun).toList();

    var done = 0;
    onProgress?.call(0, sites.length);
    final queue = [...sites];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (isCancelled?.call() ?? false) return;
        final (place, url) = queue.removeAt(0);
        final links = dedupeLinks([...?wikidata[place.id]?.links, ...await _fromWebsite(url)]);
        _cache[place.id] = _Found(DateTime.now(), links);
        if (links.isNotEmpty) onFound(place.id, links);
        onProgress?.call(++done, sites.length);
      }
    }

    await Future.wait([for (var i = 0; i < _parallelSites; i++) worker()]);

    // サイトがないものも「確認済み」として記録する
    for (final p in targets) {
      _cache.putIfAbsent(p.id, () => _Found(DateTime.now(), wikidata[p.id]?.links ?? const []));
    }
    await _save();
  }

  Future<Map<String, ({List<SocialLink> links, String? website})>> _fromWikidata(List<Place> places) async {
    final result = <String, ({List<SocialLink> links, String? website})>{};
    final byQid = {for (final p in places) p.wikidata!: p};
    final qids = byQid.keys.where((q) => RegExp(r'^Q\d+$').hasMatch(q)).toList();
    for (var i = 0; i < qids.length; i += 50) {
      final batch = qids.sublist(i, (i + 50).clamp(0, qids.length));
      try {
        final uri = Uri.https('www.wikidata.org', '/w/api.php', {
          'action': 'wbgetentities',
          'ids': batch.join('|'),
          'props': 'claims',
          'format': 'json',
        });
        final res = await _client
            .get(uri, headers: {'User-Agent': OverpassService.userAgent})
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        final entities = (jsonDecode(res.body) as Map<String, dynamic>)['entities'] as Map<String, dynamic>;
        for (final MapEntry(key: qid, value: entity) in entities.entries) {
          final claims = (entity as Map<String, dynamic>)['claims'] as Map<String, dynamic>? ?? const {};
          List<String> values(String property) => [
                for (final c in (claims[property] as List? ?? const []))
                  // 廃止されたアカウント（終了日つき・非推奨）は除く
                  if (c['rank'] != 'deprecated' && (c['qualifiers'] as Map?)?['P582'] == null)
                    if (c['mainsnak']?['datavalue']?['value'] case final String v) v,
              ];
          final place = byQid[qid];
          if (place == null) continue;
          result[place.id] = (
            links: dedupeLinks([
              for (final MapEntry(key: prop, value: platform) in _wikidataProps.entries)
                for (final v in values(prop))
                  if (platform == SnsPlatform.youtube)
                    SocialLink(platform, prop == 'P2397' ? 'channel/$v' : '@${v.replaceFirst('@', '')}',
                        SnsSource.wikidata)
                  else
                    for (final l in parseSnsTag(platform, v)) SocialLink(l.platform, l.id, SnsSource.wikidata),
              // Instagram の場所 ID（その場所でタグ付けされた投稿のページ）
              for (final v in values('P4173'))
                if (int.tryParse(v) != null)
                  SocialLink(SnsPlatform.instagram, 'https://www.instagram.com/explore/locations/$v/',
                      SnsSource.wikidata),
            ]),
            website: values('P856').firstOrNull,
          );
        }
      } catch (_) {
        // Wikidata に繋がらなくても公式サイトの確認は続ける
      }
    }
    return result;
  }

  Future<List<SocialLink>> _fromWebsite(String url) async {
    try {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      final res = await _client
          .get(uri, headers: {'User-Agent': OverpassService.userAgent})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      // 学校のサイトは Shift_JIS のこともあるが、URL 部分は ASCII なので latin1 で読めば十分。
      return socialFromHtml(latin1.decode(res.bodyBytes, allowInvalid: true));
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}sns_found.json');
      if (await _file!.exists()) {
        final json = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        for (final MapEntry(:key, :value) in json.entries) {
          final v = value as Map<String, dynamic>;
          _cache[key] = _Found(
            DateTime.parse(v['checkedAt'] as String),
            [for (final l in v['links'] as List) ?SocialLink.fromJson(l)],
          );
        }
      }
    } catch (_) {
      // 読めなければ確認し直す
    }
  }

  /// 起動直後でも保存済みの結果を使えるよう、先に読み込んでおく。
  Future<void> warmUp() => _load();

  Future<void> _save() async {
    try {
      await _file?.writeAsString(jsonEncode({
        for (final MapEntry(:key, :value) in _cache.entries)
          key: {
            'checkedAt': value.checkedAt.toIso8601String(),
            'links': [for (final l in value.links) l.toJson()],
          },
      }));
    } catch (_) {
      // 保存できなくても表示には影響しない
    }
  }
}

class _Found {
  _Found(this.checkedAt, this.links);
  final DateTime checkedAt;
  final List<SocialLink> links;
}
