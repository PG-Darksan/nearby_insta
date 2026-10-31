import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'overpass_service.dart';

/// 配信データの目次（meta.json）。
class SpotMeta {
  SpotMeta({required this.generated, required this.tileDeg, required this.coverage, required this.tiles});

  /// データを作った日時。タイルの保存先をこの単位で分ける。
  final String generated;
  final double tileDeg;

  /// データがある範囲（1 度四方の区画 `緯度_経度`）。
  final Set<String> coverage;

  /// 1 件以上の場所があるタイル。ここにないタイルは空なので取得しない。
  final Set<String> tiles;

  factory SpotMeta.fromJson(Map<String, dynamic> json) => SpotMeta(
        generated: json['generated'] as String,
        tileDeg: (json['tileDeg'] as num).toDouble(),
        coverage: {...(json['coverage'] as List).cast<String>()},
        tiles: {...(json['tiles'] as List).cast<String>()},
      );

  bool covers(LatLng p) => coverage.contains('${p.latitude.floor()}_${p.longitude.floor()}');

  /// [center] から [radiusMeters] の範囲にかかるタイルのうち、データがあるものを中心に近い順に返す。
  List<String> tilesAround(LatLng center, int radiusMeters) {
    final dLat = radiusMeters / 111320;
    final dLon = radiusMeters / (111320 * math.cos(center.latitude * math.pi / 180));
    int idx(double v) => (v / tileDeg).floor();
    final keys = <(String, double)>[];
    for (var y = idx(center.latitude - dLat); y <= idx(center.latitude + dLat); y++) {
      for (var x = idx(center.longitude - dLon); x <= idx(center.longitude + dLon); x++) {
        final key = '${y}_$x';
        if (!tiles.contains(key)) continue;
        final cy = (y + 0.5) * tileDeg - center.latitude;
        final cx = ((x + 0.5) * tileDeg - center.longitude) * math.cos(center.latitude * math.pi / 180);
        keys.add((key, cy * cy + cx * cx));
      }
    }
    keys.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final k in keys) k.$1];
  }
}

/// GitHub Pages で配信している、日本全国の場所と SNS アカウントのデータ（毎週更新）。
/// Wikidata や公式サイトの確認まで済ませてあるので、タイルを読むだけですぐに表示できる。
class SpotDataService {
  SpotDataService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 配信元。動作確認では `--dart-define=SPOT_DATA_URL=http://localhost:8000/data/v1` のように差し替えられる。
  static const baseUrl =
      String.fromEnvironment('SPOT_DATA_URL', defaultValue: 'https://pg-darksan.github.io/nearby_insta/data/v1');

  /// 目次はこの間隔で更新を確認する（それまでは保存済みのものを使う）。
  static const _metaMaxAge = Duration(hours: 12);
  static const _parallel = 6;

  SpotMeta? _meta;
  DateTime? _metaCheckedAt;
  final _memory = <String, List<Map<String, dynamic>>>{};
  Directory? _dir;

  Future<Directory> _root() async => _dir ??= await Directory(
        '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}spot_data',
      ).create(recursive: true);

  File _metaFile(Directory root) => File('${root.path}${Platform.pathSeparator}meta.json');

  /// 目次を返す。配信サーバーに繋がらず、保存済みのものもなければ null。
  Future<SpotMeta?> meta({bool refresh = false}) async {
    final root = await _root();
    if (_meta == null) {
      try {
        final file = _metaFile(root);
        if (await file.exists()) {
          _meta = SpotMeta.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
          _metaCheckedAt = (await file.lastModified());
        }
      } catch (_) {
        // 壊れていれば取り直す
      }
    }
    final stale = _metaCheckedAt == null || DateTime.now().difference(_metaCheckedAt!) > _metaMaxAge;
    if (refresh || stale || _meta == null) {
      try {
        final res = await _client
            .get(Uri.parse('$baseUrl/meta.json'), headers: {'User-Agent': OverpassService.userAgent})
            .timeout(Duration(seconds: _meta == null ? 10 : 5));
        if (res.statusCode == 200) {
          final text = utf8.decode(res.bodyBytes);
          final fresh = SpotMeta.fromJson(jsonDecode(text) as Map<String, dynamic>);
          if (fresh.generated != _meta?.generated) {
            _memory.clear();
            _removeOldVersions(root, fresh.generated);
          }
          _meta = fresh;
          _metaCheckedAt = DateTime.now();
          await _metaFile(root).writeAsString(text);
        }
      } catch (_) {
        // オフラインなどのときは保存済みの目次で続ける
      }
    }
    return _meta;
  }

  /// [keys] のタイルを読む。保存済みのものは [onCached] でまとめて先に、
  /// 取得したものは [onFetched] で 1 枚ずつ（中心に近いものから）渡す。
  Future<void> tiles(
    SpotMeta meta,
    List<String> keys, {
    required void Function(Map<String, List<Map<String, dynamic>>> tiles) onCached,
    required void Function(String key, List<Map<String, dynamic>> elements) onFetched,
    bool refresh = false,
  }) async {
    final dir = await Directory('${(await _root()).path}${Platform.pathSeparator}${_versionDir(meta)}')
        .create(recursive: true);
    final cached = <String, List<Map<String, dynamic>>>{};
    final missing = <String>[];
    for (final key in keys) {
      final hit = refresh ? null : (_memory[key] ?? await _readFile(dir, key));
      if (hit != null) {
        cached[key] = _memory[key] = hit;
      } else {
        missing.add(key);
      }
    }
    onCached(cached);

    final queue = [...missing];
    Object? error;
    Future<void> worker() async {
      while (queue.isNotEmpty && error == null) {
        final key = queue.removeAt(0);
        try {
          final res = await _client
              .get(Uri.parse('$baseUrl/t/$key.json'), headers: {'User-Agent': OverpassService.userAgent})
              .timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
          final text = utf8.decode(res.bodyBytes);
          final elements = await _decode(text);
          _memory[key] = elements;
          onFetched(key, elements);
          File('${dir.path}${Platform.pathSeparator}$key.json').writeAsString(text).ignore();
        } catch (e) {
          error ??= e;
        }
      }
    }

    await Future.wait([for (var i = 0; i < math.min(_parallel, missing.length); i++) worker()]);
    if (error != null) throw Exception('スポットデータを取得できませんでした（$error）');
  }

  Future<List<Map<String, dynamic>>?> _readFile(Directory dir, String key) async {
    try {
      final file = File('${dir.path}${Platform.pathSeparator}$key.json');
      if (!await file.exists()) return null;
      return await _decode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// 都心部のタイルは 1MB 近くあるので、画面が固まらないよう別スレッドで読む。
  static Future<List<Map<String, dynamic>>> _decode(String text) {
    List<Map<String, dynamic>> parse() =>
        ((jsonDecode(text) as Map<String, dynamic>)['elements'] as List).cast<Map<String, dynamic>>();
    return text.length < 200000 ? Future.value(parse()) : Isolate.run(parse);
  }

  static String _versionDir(SpotMeta meta) => meta.generated.replaceAll(RegExp('[^0-9A-Za-z]'), '');

  void _removeOldVersions(Directory root, String generated) {
    final keep = generated.replaceAll(RegExp('[^0-9A-Za-z]'), '');
    () async {
      try {
        await for (final entry in root.list()) {
          if (entry is Directory && !entry.path.endsWith(keep)) await entry.delete(recursive: true);
        }
      } catch (_) {
        // 消せなくても動作には影響しない
      }
    }();
  }
}
