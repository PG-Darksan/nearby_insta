import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../models/place.dart';
import 'geocoding_service.dart';
import 'overpass_service.dart';

/// 都道府県の定義（JIS コード 1〜47 と各サイトの URL スラッグ）。
class PrefectureInfo {
  const PrefectureInfo(this.code, this.name, this.slug, this.lat, this.lon, {String? omikare, String? activo})
      : omikareSlug = omikare ?? slug,
        activoSlug = activo ?? slug;

  final int code;
  final String name;
  final String slug;
  final String omikareSlug;
  final String activoSlug;
  final double lat;
  final double lon;

  String get shortName => name == '北海道' ? name : name.substring(0, name.length - 1);
}

const prefectures = <PrefectureInfo>[
  PrefectureInfo(1, '北海道', 'hokkaido', 43.064, 141.347),
  PrefectureInfo(2, '青森県', 'aomori', 40.824, 140.740),
  PrefectureInfo(3, '岩手県', 'iwate', 39.704, 141.153),
  PrefectureInfo(4, '宮城県', 'miyagi', 38.269, 140.872),
  PrefectureInfo(5, '秋田県', 'akita', 39.719, 140.102),
  PrefectureInfo(6, '山形県', 'yamagata', 38.240, 140.364),
  PrefectureInfo(7, '福島県', 'fukushima', 37.750, 140.468),
  PrefectureInfo(8, '茨城県', 'ibaraki', 36.342, 140.447),
  PrefectureInfo(9, '栃木県', 'tochigi', 36.566, 139.884),
  PrefectureInfo(10, '群馬県', 'gunma', 36.391, 139.060),
  PrefectureInfo(11, '埼玉県', 'saitama', 35.857, 139.649),
  PrefectureInfo(12, '千葉県', 'chiba', 35.605, 140.123),
  PrefectureInfo(13, '東京都', 'tokyo', 35.690, 139.692),
  PrefectureInfo(14, '神奈川県', 'kanagawa', 35.448, 139.643),
  PrefectureInfo(15, '新潟県', 'niigata', 37.902, 139.023, activo: 'nigata'),
  PrefectureInfo(16, '富山県', 'toyama', 36.695, 137.211),
  PrefectureInfo(17, '石川県', 'ishikawa', 36.594, 136.626),
  PrefectureInfo(18, '福井県', 'fukui', 36.065, 136.222),
  PrefectureInfo(19, '山梨県', 'yamanashi', 35.664, 138.568),
  PrefectureInfo(20, '長野県', 'nagano', 36.651, 138.181),
  PrefectureInfo(21, '岐阜県', 'gifu', 35.391, 136.722),
  PrefectureInfo(22, '静岡県', 'shizuoka', 34.977, 138.383),
  PrefectureInfo(23, '愛知県', 'aichi', 35.180, 136.907),
  PrefectureInfo(24, '三重県', 'mie', 34.730, 136.509),
  PrefectureInfo(25, '滋賀県', 'shiga', 35.005, 135.869),
  PrefectureInfo(26, '京都府', 'kyoto', 35.021, 135.756),
  PrefectureInfo(27, '大阪府', 'osaka', 34.686, 135.520),
  PrefectureInfo(28, '兵庫県', 'hyogo', 34.691, 135.183),
  PrefectureInfo(29, '奈良県', 'nara', 34.685, 135.833),
  PrefectureInfo(30, '和歌山県', 'wakayama', 34.226, 135.168),
  PrefectureInfo(31, '鳥取県', 'tottori', 35.504, 134.238),
  PrefectureInfo(32, '島根県', 'shimane', 35.472, 133.051),
  PrefectureInfo(33, '岡山県', 'okayama', 34.662, 133.934),
  PrefectureInfo(34, '広島県', 'hiroshima', 34.397, 132.460),
  PrefectureInfo(35, '山口県', 'yamaguchi', 34.186, 131.471),
  PrefectureInfo(36, '徳島県', 'tokushima', 34.066, 134.559),
  PrefectureInfo(37, '香川県', 'kagawa', 34.340, 134.043),
  PrefectureInfo(38, '愛媛県', 'ehime', 33.842, 132.765),
  PrefectureInfo(39, '高知県', 'kochi', 33.560, 133.531, omikare: 'kouchi'),
  PrefectureInfo(40, '福岡県', 'fukuoka', 33.607, 130.418),
  PrefectureInfo(41, '佐賀県', 'saga', 33.249, 130.299),
  PrefectureInfo(42, '長崎県', 'nagasaki', 32.745, 129.874),
  PrefectureInfo(43, '熊本県', 'kumamoto', 32.790, 130.742),
  PrefectureInfo(44, '大分県', 'oita', 33.238, 131.613, omikare: 'ooita'),
  PrefectureInfo(45, '宮崎県', 'miyazaki', 31.911, 131.424),
  PrefectureInfo(46, '鹿児島県', 'kagoshima', 31.560, 130.558),
  PrefectureInfo(47, '沖縄県', 'okinawa', 26.212, 127.681),
];

/// まだ座標が確定していないイベント候補（一覧ページから取り出した状態）。
class RawEventCandidate {
  const RawEventCandidate({
    required this.url,
    required this.title,
    required this.category,
    required this.source,
    this.position,
    this.venue,
    this.address,
    this.coarseArea,
    this.schedule,
    this.startAt,
    this.endAt,
    this.fee,
    this.organizer,
    this.description,
  });

  final String url;
  final String title;
  final PlaceCategory category;
  final String source;
  final LatLng? position;
  final String? venue;
  final String? address;
  final String? coarseArea;
  final String? schedule;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? fee;
  final String? organizer;
  final String? description;
}

/// 近くの「婚活・合コン（街コン・恋活を含む）」「ボランティア（施設ではなく開催地）」「有償体験（開催イベント）」を
/// 公開イベント情報から集める。
///
/// - こくちーずプロ: 一覧の JSON-LD に開催会場の緯度経度（GeoCoordinates）が含まれる（婚活・ボランティア・有償体験）
/// - 街コンジャパン / オミカレ: 都道府県一覧から近くのエリアのイベントを選び、詳細ページの会場住所を国土地理院 API で座標化する
/// - activo: ボランティア募集の活動場所（`JobPosting.jobLocation`。団体所在地 `hiringOrganization` ではない）を座標化する
/// - いこーよ: 都道府県別の有償ワークショップ・体験イベント一覧から開催会場住所を国土地理院 API で座標化する
class EventService {
  EventService({http.Client? client, GeocodingService? geocoding})
      : _client = client ?? http.Client(),
        _geocoding = geocoding ?? GeocodingService();

  final http.Client _client;
  final GeocodingService _geocoding;

  static const _distance = Distance(calculator: Haversine());
  static const _listMaxAge = Duration(hours: 4);
  static const _detailMaxAge = Duration(days: 3);
  static const _geoMaxAge = Duration(days: 30);
  static const _maxDetailLookups = 10;

  static final _ldJsonPattern = RegExp(
    r'''<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>''',
    caseSensitive: false,
  );
  static final _businessExclude = RegExp(
    r'起業|副業|コンサル|マーケティング|1,?000万|セミナー.*ビジネス|経営者異業種|異業種交流.*ビジネス|フランチャイズ|投資|不動産',
  );
  static final _matchmakingMatch = RegExp(
    r'婚活|街コン|合コン|恋活|お見合い|マッチング|独身|相席|出会い|恋.*パーティ|パーティ.*恋|友活.*恋|恋.*カフェ会|1on1.*カフェ',
  );
  static final _volunteerMatch = RegExp(
    r'ボランティア|清掃|ごみ拾い|ゴミ拾い|クリーンアップ|ビーチクリーン|地域清掃|植樹|保護猫|保護犬|子ども食堂|こども食堂|'
    r'フードバンク|フードドライブ|チャリティ|災害支援|傾聴|手話.*支援|学習支援|募金',
  );
  static final _experienceTitleMatch = RegExp(
    r'ワークショップ|workshop|体験(?:会|レッスン|教室|イベント|講座|クラス|コース|ワーク|ツアー|プログラム)?|'
    r'手作り|ハンドメイド|クラフト|ものづくり|モノづくり|陶芸|ろくろ|金継ぎ|ガラス細工|ステンドグラス|切子|'
    r'キャンドル|アロマ|調香|香水作り|ハーバリウム|フラワーアレンジ|リース作り|ブーケ作り|苔テラリウム|'
    r'料理教室|パン作り|お菓子作り|スイーツ作り|和菓子作り|そば打ち|うどん打ち|味噌作り|ソーセージ作り|'
    r'茶道|華道|生け花|書道|美文字|篆刻|着付け|染色|藍染|機織り|編み物|刺繍|つまみ細工|'
    r'レザークラフト|革細工|木工|DIY|シルバーアクセサリー|アクセサリー作り|彫金|'
    r'水彩|油絵|デッサン|アート体験|カリグラフィー|アルコールインク|'
    r'ヨガ体験|ピラティス体験|ダンス体験|ボルダリング体験|SUP体験|カヤック体験|乗馬体験|農業体験|収穫体験',
    caseSensitive: false,
  );
  static final _experienceExclude = RegExp(
    r'出店者募集|出展者募集|スタッフ募集|講師募集|ボランティア募集|異業種交流|ビジネス交流|名刺交換|'
    r'カフェ会.*友達|友達作り.*カフェ会|100人.*交流|朝活.*交流|転職|就職|会社説明会|個別相談会',
  );
  static final _freeEventExclude = RegExp(
    r'参加無料|参加費無料|完全無料|無料体験|受講料無料|入場無料.*無料',
  );
  static final _textFeePattern = RegExp(
    r'(?:参加費|料金|受講料|体験料|材料費|会費|費用)[：:\s・は税込]*([1-9][0-9,，]{2,6}\s*円(?:[〜~～][0-9,，]+\s*円)?)',
  );

  bool _loaded = false;
  File? _cacheFile;

  /// 都道府県・地域キーごとの取得済みイベント一覧。
  final _areaCache = <String, ({DateTime fetchedAt, List<Place> places})>{};

  /// イベント詳細 URL ごとの会場名・住所キャッシュ。
  final _detailCache = <String, ({DateTime checkedAt, String? venue, String? address, String? fee})>{};

  /// 住所文字列ごとの座標キャッシュ。
  final _geoCache = <String, ({DateTime checkedAt, double? lat, double? lon})>{};

  /// キャッシュ済みのイベントがあれば即座に返す（検索開始時に待たずに表示するため）。
  List<Place> cachedAround(LatLng center, int radiusMeters) {
    final all = <String, Place>{};
    for (final entry in _areaCache.values) {
      if (DateTime.now().difference(entry.fetchedAt) > _listMaxAge) continue;
      for (final p in entry.places) {
        if (_distance.distance(center, p.position) <= radiusMeters) {
          all[p.id] = p;
        }
      }
    }
    return _spreadCoLocated(all.values.toList());
  }

  /// [center] から [radiusMeters] 周辺の婚活・合コン・ボランティア開催地を取得する。
  Future<List<Place>> load(
    LatLng center,
    int radiusMeters, {
    String? localArea,
    bool refresh = false,
    bool Function()? isCancelled,
  }) async {
    await _ensureLoaded();
    final pref = await _prefectureOf(center);
    if (pref == null) return const [];
    if (isCancelled?.call() ?? false) return const [];

    final areaClean = localArea
        ?.replaceFirst(RegExp(r'[0-9０-９一二三四五六七八九十〇]+丁目$'), '')
        .replaceAll(RegExp(r'[\s/／・]+'), '')
        .trim();
    // 検索範囲に合わせて詳細ページ解決の対象範囲も決める（キャッシュ再利用のため 10km 単位で丸める）
    final bucket = '${pref.code}_${(center.latitude * 10).round()}_${(center.longitude * 10).round()}';
    final hit = _areaCache[bucket];
    if (!refresh && hit != null && DateTime.now().difference(hit.fetchedAt) <= _listMaxAge) {
      return _spreadCoLocated(hit.places);
    }

    final now = DateTime.now();
    final coarseLimitMeters = math.max(radiusMeters + 12000, 18000);

    final results = await Future.wait<List<Place>>([
      _fromKokuchpro(pref, areaClean, now, isCancelled: isCancelled),
      _fromMachicon(pref, center, coarseLimitMeters, now, isCancelled: isCancelled),
      _fromOmikare(pref, center, coarseLimitMeters, now, isCancelled: isCancelled),
      _fromActivo(pref, center, coarseLimitMeters, isCancelled: isCancelled),
      _fromIkoyo(pref, center, coarseLimitMeters, now, isCancelled: isCancelled),
    ]);

    if (isCancelled?.call() ?? false) return const [];

    final merged = _dedupeEvents([for (final list in results) ...list]);
    _areaCache[bucket] = (fetchedAt: DateTime.now(), places: merged);
    unawaited(_saveCache());
    return _spreadCoLocated(merged);
  }

  Future<PrefectureInfo?> _prefectureOf(LatLng p) async {
    // 日本の緯度経度範囲外なら対象外
    if (p.latitude < 24 || p.latitude > 46 || p.longitude < 122 || p.longitude > 149) return null;
    final rev = await _geocoding.reverse(p);
    if (rev.prefCode != null && rev.prefCode! >= 1 && rev.prefCode! <= prefectures.length) {
      return prefectures[rev.prefCode! - 1];
    }
    // 海沿い・河川敷などで逆ジオコーダが空だった場合は最も近い県庁所在地から推定する
    PrefectureInfo? best;
    var bestDist = 180000.0;
    for (final pref in prefectures) {
      final d = _distance.distance(p, LatLng(pref.lat, pref.lon)).toDouble();
      if (d < bestDist) {
        bestDist = d;
        best = pref;
      }
    }
    return best;
  }

  // ---------------- 1. こくちーずプロ（開催地の緯度経度つき JSON-LD） ----------------

  Future<List<Place>> _fromKokuchpro(
    PrefectureInfo pref,
    String? localArea,
    DateTime now, {
    bool Function()? isCancelled,
  }) async {
    final areaSeg = 'area-${Uri.encodeComponent(pref.name)}';
    final generalUrls = <String>[
      'https://www.kokuchpro.com/s/$areaSeg/q-${Uri.encodeComponent('婚活')}/',
      'https://www.kokuchpro.com/s/$areaSeg/q-${Uri.encodeComponent('街コン')}/',
      'https://www.kokuchpro.com/s/$areaSeg/q-${Uri.encodeComponent('合コン')}/',
      'https://www.kokuchpro.com/s/$areaSeg/q-${Uri.encodeComponent('恋活')}/',
      'https://www.kokuchpro.com/s/$areaSeg/q-${Uri.encodeComponent('ボランティア')}/',
      if (localArea != null && localArea.length >= 2 && !localArea.contains(' '))
        'https://www.kokuchpro.com/s/q-${Uri.encodeComponent(localArea)}/',
    ];
    // et-0: オフライン（会場開催）のみ / charge-1: 有料イベントのみ
    final paidExperienceUrls = <String>[
      'https://www.kokuchpro.com/s/$areaSeg/et-0/charge-1/q-${Uri.encodeComponent('ワークショップ')}/',
      'https://www.kokuchpro.com/s/$areaSeg/et-0/charge-1/q-${Uri.encodeComponent('体験')}/',
    ];

    final allUrls = [...generalUrls, ...paidExperienceUrls];
    final pages = await Future.wait(allUrls.map(_getHtml));
    if (isCancelled?.call() ?? false) return const [];

    final candidates = <String, RawEventCandidate>{};
    for (var i = 0; i < pages.length; i++) {
      final html = pages[i];
      if (html == null) continue;
      final isForcedPaid = i >= generalUrls.length;
      for (final c in parseKokuchproHtml(html, now: now, forcedPaid: isForcedPaid)) {
        candidates.putIfAbsent(c.url, () => c);
      }
    }

    final out = <Place>[];
    for (final c in candidates.values) {
      var pos = c.position;
      if (pos == null && c.address != null && c.address!.length >= 5) {
        pos = await _geocodeCached(c.address!);
      }
      if (pos == null) continue;
      out.add(_candidateToPlace(c, pos));
    }
    return out;
  }

  /// こくちーずプロの検索結果 HTML から、オフライン開催の婚活・合コン・ボランティア・有償体験を抽出する。
  static List<RawEventCandidate> parseKokuchproHtml(String html, {DateTime? now, bool forcedPaid = false}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(hours: 2));
    final out = <RawEventCandidate>[];
    for (final d in _extractLdEvents(html)) {
      final title = (d['name'] as String?)?.trim();
      final url = (d['url'] as String?)?.trim();
      if (title == null || title.isEmpty || url == null || url.isEmpty) continue;
      if (!_isUpcoming(d, cutoff) || _isOnlineOnly(d)) continue;

      final desc = _cleanText(d['description'] as String?);
      final combined = '$title\n${desc ?? ''}';
      if (_businessExclude.hasMatch(title)) continue;

      final offersFee = _extractOffersFee(d['offers']);
      final textFee = _extractTextFee(combined);
      PlaceCategory? category;
      String? effectiveFee = offersFee ?? textFee;

      if (_matchmakingMatch.hasMatch(combined)) {
        category = PlaceCategory.matchmaking;
      } else if (_volunteerMatch.hasMatch(combined)) {
        category = PlaceCategory.volunteer;
      } else if (_isPaidExperienceCandidate(
        title: title,
        combined: combined,
        offers: d['offers'],
        textFee: textFee,
        forcedPaid: forcedPaid,
      )) {
        category = PlaceCategory.experience;
        effectiveFee ??= forcedPaid ? '有料（詳細は申込ページ）' : null;
      }
      if (category == null) continue;

      final loc = d['location'];
      if (loc is! Map) continue;
      final venue = _cleanText(loc['name'] as String?);
      if (venue == 'オンライン' || venue == 'Zoom') continue;
      final address = _extractPostalAddress(loc['address']);
      final geo = loc['geo'];
      LatLng? pos;
      if (geo is Map) {
        final lat = _toDouble(geo['latitude']);
        final lon = _toDouble(geo['longitude']);
        if (lat != null && lon != null && lat != 0 && lon != 0) {
          pos = LatLng(lat, lon);
        }
      }
      if (pos == null && (address == null || address == '日本')) continue;

      final startRaw = d['startDate'] as String?;
      final endRaw = d['endDate'] as String?;
      out.add(RawEventCandidate(
        url: url,
        title: title,
        category: category,
        source: 'こくちーずプロ',
        position: pos,
        venue: venue,
        address: address,
        schedule: _formatSchedule(startRaw, endRaw),
        startAt: _parseEventDateTime(startRaw),
        endAt: _parseEventDateTime(endRaw),
        fee: effectiveFee,
        organizer: _extractOrganizer(d['organizer']),
        description: desc,
      ));
    }
    return out;
  }

  static bool _isPaidExperienceCandidate({
    required String title,
    required String combined,
    required Object? offers,
    required String? textFee,
    required bool forcedPaid,
  }) {
    if (_experienceExclude.hasMatch(combined)) return false;
    if (!_experienceTitleMatch.hasMatch(title)) return false;
    if (_freeEventExclude.hasMatch(title)) return false;
    if (_isZeroOfferPrice(offers)) return false;
    if (_hasPositiveOfferPrice(offers) || textFee != null) return true;
    return forcedPaid && !_freeEventExclude.hasMatch(combined);
  }

  // ---------------- 2. 街コンジャパン ----------------

  Future<List<Place>> _fromMachicon(
    PrefectureInfo pref,
    LatLng center,
    int coarseLimitMeters,
    DateTime now, {
    bool Function()? isCancelled,
  }) async {
    final html = await _getHtml('https://machicon.jp/areas/${pref.slug}/');
    if (html == null || (isCancelled?.call() ?? false)) return const [];
    final list = parseMachiconListHtml(html, now: now);
    final nearby = await _filterNearbyCoarse(list, pref, center, coarseLimitMeters);
    return _resolveVenueAddresses(
      nearby.take(_maxDetailLookups).toList(),
      parseDetail: parseMachiconDetailHtml,
      isCancelled: isCancelled,
    );
  }

  static List<RawEventCandidate> parseMachiconListHtml(String html, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(hours: 2));
    final out = <RawEventCandidate>[];
    for (final d in _extractLdEvents(html)) {
      final title = (d['name'] as String?)?.trim();
      final url = (d['url'] as String?)?.trim();
      if (title == null || title.isEmpty || url == null || url.isEmpty) continue;
      if (!_isUpcoming(d, cutoff) || _isOnlineOnly(d)) continue;
      final loc = d['location'];
      final areaName = loc is Map ? _cleanText(loc['name'] as String?) : null;
      final desc = _cleanText(d['description'] as String?);
      // 説明文「表参道（東京都) 『会場名』で...」や「横浜駅周辺（神奈川県) 個室居酒屋 ...で」から会場名も拾う
      String? descVenue;
      if (desc != null) {
        final m = RegExp(r'[）)]\s*([^\s『「]{2,40}|『[^』]+』|「[^」]+」)で\d+月\d+日').firstMatch(desc);
        if (m != null) descVenue = m.group(1)!.replaceAll(RegExp(r'[『』「」]'), '').trim();
      }
      final startRaw = d['startDate'] as String?;
      final endRaw = d['endDate'] as String?;
      out.add(RawEventCandidate(
        url: url,
        title: title,
        category: PlaceCategory.matchmaking,
        source: '街コンジャパン',
        venue: descVenue,
        coarseArea: areaName,
        schedule: _formatSchedule(startRaw, endRaw),
        startAt: _parseEventDateTime(startRaw),
        endAt: _parseEventDateTime(endRaw),
        fee: _extractOffersFee(d['offers']),
        organizer: _extractOrganizer(d['organizer']),
        description: desc,
      ));
    }
    return out;
  }

  /// 街コンジャパンの詳細ページから、開催会場の名前・住所・料金を取り出す。
  static ({String? venue, String? address, String? fee}) parseMachiconDetailHtml(String html) {
    String? venue;
    String? address;
    String? fee;
    for (final d in _extractLdEvents(html)) {
      fee ??= _extractOffersFee(d['offers']);
      if (d['location'] case final Map loc) {
        final v = _cleanText(loc['name'] as String?);
        final a = _extractPostalAddress(loc['address']);
        if (a != null && a.length >= 6) {
          venue ??= v;
          address ??= a;
        }
      }
    }
    if (address == null) {
      final m = RegExp(r'<th[^>]*>\s*住所\s*</th>\s*<td[^>]*>([^<]+)</td>').firstMatch(html);
      if (m != null) address = _cleanText(m.group(1));
    }
    return (venue: venue, address: address, fee: fee);
  }

  // ---------------- 3. オミカレ ----------------

  Future<List<Place>> _fromOmikare(
    PrefectureInfo pref,
    LatLng center,
    int coarseLimitMeters,
    DateTime now, {
    bool Function()? isCancelled,
  }) async {
    final html = await _getHtml('https://party-calendar.net/area/${pref.omikareSlug}');
    if (html == null || (isCancelled?.call() ?? false)) return const [];
    final list = parseOmikareListHtml(html, now: now);
    final nearby = await _filterNearbyCoarse(list, pref, center, coarseLimitMeters);
    return _resolveVenueAddresses(
      nearby.take(_maxDetailLookups).toList(),
      parseDetail: parseOmikareDetailHtml,
      isCancelled: isCancelled,
    );
  }

  static List<RawEventCandidate> parseOmikareListHtml(String html, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(hours: 2));
    final out = <RawEventCandidate>[];
    for (final d in _extractLdEvents(html)) {
      final title = (d['name'] as String?)?.trim();
      final url = (d['url'] as String?)?.trim();
      if (title == null || title.isEmpty || url == null || url.isEmpty) continue;
      if (!_isUpcoming(d, cutoff) || _isOnlineOnly(d)) continue;
      final loc = d['location'];
      final areaName = loc is Map ? _cleanText(loc['name'] as String?) : null;
      final desc = _cleanText(d['description'] as String?);
      final startRaw = d['startDate'] as String?;
      final endRaw = d['endDate'] as String?;
      out.add(RawEventCandidate(
        url: url,
        title: title,
        category: PlaceCategory.matchmaking,
        source: 'オミカレ',
        coarseArea: areaName,
        schedule: _formatSchedule(startRaw, endRaw),
        startAt: _parseEventDateTime(startRaw),
        endAt: _parseEventDateTime(endRaw),
        fee: _extractOffersFee(d['offers']),
        organizer: _extractOrganizer(d['organizer']),
        description: desc,
      ));
    }
    return out;
  }

  /// オミカレの詳細ページから、開催会場の住所と会場名を取り出す。
  static ({String? venue, String? address, String? fee}) parseOmikareDetailHtml(String html) {
    String? address;
    String? venue;
    final addrMatch = RegExp(r'<dt[^>]*>\s*住所\s*</dt>\s*<dd[^>]*>([\s\S]*?)</dd>').firstMatch(html);
    if (addrMatch != null) address = _cleanText(addrMatch.group(1));
    final venueMatch = RegExp(r'<dt[^>]*>\s*(?:会場|開催場所)\s*</dt>\s*<dd[^>]*>([\s\S]*?)</dd>').firstMatch(html);
    if (venueMatch != null) venue = _cleanText(venueMatch.group(1));
    return (venue: venue, address: address, fee: null);
  }

  // ---------------- 4. activo（ボランティア募集の開催地） ----------------

  Future<List<Place>> _fromActivo(
    PrefectureInfo pref,
    LatLng center,
    int coarseLimitMeters, {
    bool Function()? isCancelled,
  }) async {
    final html = await _getHtml('https://activo.jp/${pref.activoSlug}');
    if (html == null || (isCancelled?.call() ?? false)) return const [];
    final list = parseActivoListHtml(html, prefShortName: pref.shortName);
    final nearby = await _filterNearbyCoarse(list, pref, center, coarseLimitMeters);
    return _resolveVenueAddresses(
      nearby.take(_maxDetailLookups).toList(),
      parseDetail: parseActivoDetailHtml,
      isCancelled: isCancelled,
    );
  }

  /// activo の都道府県ページ内の JSON から、現地開催のボランティア募集を取り出す。
  static List<RawEventCandidate> parseActivoListHtml(String html, {String? prefShortName}) {
    final out = <RawEventCandidate>[];
    final scriptPattern = RegExp(r'<script[^>]*>(\s*\{"request":[\s\S]*?)</script>');
    for (final m in scriptPattern.allMatches(html)) {
      Map<String, dynamic> data;
      try {
        data = jsonDecode(m.group(1)!.trim()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final hits = ((data['response'] as Map?)?['hits'] as Map?)?['hits'];
      if (hits is! List) continue;
      for (final hit in hits) {
        final src = (hit as Map)['_source'];
        if (src is! Map) continue;
        if (src['is_vol'] != true) continue;
        final id = src['id'];
        final title = _cleanText(src['title'] as String?);
        if (id == null || title == null || title.isEmpty) continue;

        final view = (src['_modified_text_for_views'] as Map?)?.cast<String, dynamic>() ?? const {};
        if (view['online_possibility'] == 'online_only') continue;

        final locText = _cleanText(view['display_activity_locations'] as String?);
        // 「神奈川 [横浜市西区/JR横浜駅 徒歩8分]」から該当都道府県の具体的な市区町村・駅を抜き出す
        String? coarseArea;
        if (locText != null) {
          final prefPart = prefShortName != null
              ? RegExp('${RegExp.escape(prefShortName)}\\s*\\[([^\\]]+)\\]').firstMatch(locText)?.group(1)
              : RegExp(r'\[([^\]]+)\]').firstMatch(locText)?.group(1);
          coarseArea = prefPart?.split(',').first.split('/').first.trim();
        }
        if (coarseArea == null || coarseArea.isEmpty) continue;

        final scheduleParts = [
          _cleanText(view['dates_or_terms'] as String?),
          _cleanText(view['frequents'] as String?),
        ].whereType<String>().where((s) => s.isNotEmpty).toList();

        out.add(RawEventCandidate(
          url: 'https://activo.jp/articles/$id',
          title: title,
          category: PlaceCategory.volunteer,
          source: 'activo',
          coarseArea: coarseArea,
          schedule: scheduleParts.isEmpty ? null : scheduleParts.join(' · '),
          fee: _cleanText(view['prices'] as String?),
          organizer: _cleanText((src['user'] as Map?)?['name'] as String?),
          description: _cleanText(src['description'] as String?),
        ));
      }
    }
    return out;
  }

  /// activo の募集詳細ページの `JobPosting.jobLocation` から、団体の事務所ではなく実際の開催地・活動場所を取り出す。
  static ({String? venue, String? address, String? fee}) parseActivoDetailHtml(String html) {
    for (final m in _ldJsonPattern.allMatches(html)) {
      final raw = m.group(1)!.replaceAll('//<![CDATA[', '').replaceAll('//]]>', '').trim();
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      final items = decoded is List ? decoded : [decoded];
      for (final item in items) {
        if (item is! Map || item['@type'] != 'JobPosting') continue;
        final jobLoc = item['jobLocation'];
        final locs = jobLoc is List ? jobLoc : [?jobLoc];
        for (final loc in locs) {
          if (loc is! Map) continue;
          final addrObj = loc['address'];
          if (addrObj is! Map) continue;
          final region = _cleanText(addrObj['addressRegion'] as String?) ?? '';
          final locality = _cleanText(addrObj['addressLocality'] as String?) ?? '';
          final street = _cleanText(addrObj['streetAddress'] as String?) ?? '';
          // 都道府県名しかない（具体的な市区町村・会場がない）広域募集は地図上の開催地としては出さない
          if (locality.isEmpty && street.isEmpty) continue;
          final fullPref = _normalizePrefecturePrefix(region);
          final address = '$fullPref$locality$street'.trim();
          final venue = street.isNotEmpty ? street : locality;
          return (venue: venue, address: address, fee: null);
        }
      }
    }
    return (venue: null, address: null, fee: null);
  }

  // ---------------- 5. いこーよ（有償ワークショップ・体験イベント） ----------------

  Future<List<Place>> _fromIkoyo(
    PrefectureInfo pref,
    LatLng center,
    int coarseLimitMeters,
    DateTime now, {
    bool Function()? isCancelled,
  }) async {
    final urls = <String>[
      'https://iko-yo.net/events?prefecture_ids%5B%5D=${pref.code}&word=${Uri.encodeComponent('ワークショップ')}',
      'https://iko-yo.net/events?prefecture_ids%5B%5D=${pref.code}&word=${Uri.encodeComponent('体験')}',
    ];
    final pages = await Future.wait(urls.map(_getHtml));
    if (isCancelled?.call() ?? false) return const [];

    final byUrl = <String, RawEventCandidate>{};
    for (final html in pages) {
      if (html == null) continue;
      for (final c in parseIkoyoListHtml(html, now: now)) {
        byUrl.putIfAbsent(c.url, () => c);
      }
    }
    if (byUrl.isEmpty) return const [];

    final nearby = await _filterNearbyCoarse(byUrl.values.toList(), pref, center, coarseLimitMeters);
    final out = <Place>[];
    for (final c in nearby.take(14)) {
      if (isCancelled?.call() ?? false) return const [];
      final addr = c.address;
      if (addr == null || addr.length < 5) continue;
      final pos = await _geocodeCached(addr);
      if (pos == null) continue;
      out.add(_candidateToPlace(c, pos));
    }
    return out;
  }

  /// いこーよの都道府県イベント一覧 HTML から、無料イベントを除いた有償の体験・ワークショップ開催イベントを抽出する。
  static List<RawEventCandidate> parseIkoyoListHtml(String html, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(hours: 2));

    // 一覧カードから「タイトル -> イベント詳細 URL」と「完全無料ラベルの有無」を収集する
    final urlByTitle = <String, String>{};
    final freeTitles = <String>{};
    final cardPattern = RegExp(r'<li[^>]*class="[^"]*p-index-list-item\b[\s\S]*?</li>', caseSensitive: false);
    final linkHeadingPattern = RegExp(
      r'href="(/events/\d+)"[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>',
      caseSensitive: false,
    );
    for (final cardMatch in cardPattern.allMatches(html)) {
      final block = cardMatch.group(0)!;
      final lh = linkHeadingPattern.firstMatch(block);
      if (lh == null) continue;
      final path = lh.group(1)!;
      final heading = _cleanText(lh.group(2));
      if (heading == null || heading.isEmpty) continue;
      urlByTitle.putIfAbsent(heading, () => 'https://iko-yo.net$path');
      if (block.contains('完全無料') || block.contains('参加無料')) {
        freeTitles.add(heading);
      }
    }

    final out = <RawEventCandidate>[];
    final seenUrls = <String>{};
    for (final d in _extractLdEvents(html)) {
      final title = _cleanText(d['name'] as String?);
      if (title == null || title.isEmpty) continue;
      if (freeTitles.contains(title)) continue;
      if (!_isUpcoming(d, cutoff) || _isOnlineOnly(d)) continue;
      if (_businessExclude.hasMatch(title) || _experienceExclude.hasMatch(title)) continue;

      final desc = _cleanText(d['description'] as String?);
      final combined = '$title\n${desc ?? ''}';
      if (_freeEventExclude.hasMatch(title) || _isZeroOfferPrice(d['offers'])) continue;
      if (_matchmakingMatch.hasMatch(combined) || _volunteerMatch.hasMatch(combined)) continue;
      if (!_experienceTitleMatch.hasMatch(combined)) continue;

      final directUrl = (d['url'] as String?)?.trim();
      final url = (directUrl != null && directUrl.isNotEmpty) ? directUrl : urlByTitle[title];
      if (url == null || !seenUrls.add(url)) continue;

      final loc = d['location'];
      if (loc is! Map) continue;
      final fullAddress = _extractPostalAddress(loc['address']);
      if (fullAddress == null || fullAddress.length < 5 || fullAddress == '日本') continue;

      // 「神奈川県大和市下鶴間2-5-40 つるカフェ食堂」のように番地の後ろに会場名が続く場合は分離してジオコーダ精度を高める
      String geocodeAddr = fullAddress;
      String? trailingVenue;
      final splitMatch = RegExp(
        r'^((?:北海道|東京都|(?:京都|大阪)府|.{2,3}県)?\S*[0-9０-９]+(?:[-ー−‐][0-9０-９]+)*(?:丁目|番地?|号)?)\s+(.+)$',
      ).firstMatch(fullAddress);
      if (splitMatch != null) {
        geocodeAddr = splitMatch.group(1)!.trim();
        trailingVenue = splitMatch.group(2)!.trim();
      }

      final rawLocName = _cleanText(loc['name'] as String?);
      final venue = (rawLocName != null && rawLocName != title) ? rawLocName : trailingVenue;
      if (venue == 'オンライン' || venue == 'Zoom') continue;

      final cityMatch = RegExp(
        r'^(?:北海道|東京都|(?:京都|大阪)府|.{2,3}県)?([^0-9０-９\s]+?[市区町村郡])',
      ).firstMatch(geocodeAddr);
      final coarseArea = cityMatch?.group(1);

      final startRaw = d['startDate'] as String?;
      final endRaw = d['endDate'] as String?;
      final fee = _extractOffersFee(d['offers']) ?? _extractTextFee(combined) ?? '有料（詳細はイベントページ）';

      out.add(RawEventCandidate(
        url: url,
        title: title,
        category: PlaceCategory.experience,
        source: 'いこーよ',
        venue: venue,
        address: geocodeAddr,
        coarseArea: coarseArea,
        schedule: _formatSchedule(startRaw, endRaw),
        startAt: _parseEventDateTime(startRaw),
        endAt: _parseEventDateTime(endRaw),
        fee: fee,
        organizer: _extractOrganizer(d['organizer']),
        description: desc,
      ));
    }
    return out;
  }

  // ---------------- 詳細ページの解決・ジオコーディング・重複排除 ----------------

  /// 大まかなエリア名（例: 横浜駅周辺、小田原市）で検索地点から遠い候補を先に除外し、近い順にする。
  Future<List<RawEventCandidate>> _filterNearbyCoarse(
    List<RawEventCandidate> list,
    PrefectureInfo pref,
    LatLng center,
    int coarseLimitMeters,
  ) async {
    final scored = <(RawEventCandidate, double)>[];
    for (final c in list) {
      final area = c.coarseArea;
      if (area == null || area.isEmpty) {
        scored.add((c, coarseLimitMeters * 0.8));
        continue;
      }
      // 「関内・桜木町・みなとみらい」のような複数駅表記は最初の地名で調べる
      final primary = area.split(RegExp(r'[・／/]')).first.replaceAll('周辺', '').trim();
      final pos = await _geocodeCached('${pref.name}$primary');
      if (pos == null) {
        scored.add((c, coarseLimitMeters * 0.9));
        continue;
      }
      final dist = _distance.distance(center, pos).toDouble();
      if (dist <= coarseLimitMeters) scored.add((c, dist));
    }
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final s in scored) s.$1];
  }

  Future<List<Place>> _resolveVenueAddresses(
    List<RawEventCandidate> candidates, {
    required ({String? venue, String? address, String? fee}) Function(String html) parseDetail,
    bool Function()? isCancelled,
  }) async {
    final out = <Place>[];
    final queue = [...candidates];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (isCancelled?.call() ?? false) return;
        final c = queue.removeAt(0);
        final detail = await _getDetailCached(c.url, parseDetail);
        final address = detail.address ?? c.address;
        if (address == null || address.length < 4) continue;
        final pos = await _geocodeCached(address);
        if (pos == null) continue;
        final resolved = RawEventCandidate(
          url: c.url,
          title: c.title,
          category: c.category,
          source: c.source,
          position: pos,
          venue: detail.venue ?? c.venue ?? c.coarseArea,
          address: address,
          schedule: c.schedule,
          startAt: c.startAt,
          endAt: c.endAt,
          fee: c.fee ?? detail.fee,
          organizer: c.organizer,
          description: c.description,
        );
        out.add(_candidateToPlace(resolved, pos));
      }
    }

    await Future.wait([for (var i = 0; i < math.min(4, candidates.length); i++) worker()]);
    return out;
  }

  Future<({String? venue, String? address, String? fee})> _getDetailCached(
    String url,
    ({String? venue, String? address, String? fee}) Function(String html) parseDetail,
  ) async {
    final cached = _detailCache[url];
    if (cached != null && DateTime.now().difference(cached.checkedAt) <= _detailMaxAge) {
      return (venue: cached.venue, address: cached.address, fee: cached.fee);
    }
    final html = await _getHtml(url);
    if (html == null) return (venue: null, address: null, fee: null);
    final parsed = parseDetail(html);
    _detailCache[url] = (
      checkedAt: DateTime.now(),
      venue: parsed.venue,
      address: parsed.address,
      fee: parsed.fee,
    );
    return parsed;
  }

  Future<LatLng?> _geocodeCached(String address) async {
    final key = address.trim();
    if (key.isEmpty) return null;
    final hit = _geoCache[key];
    if (hit != null && DateTime.now().difference(hit.checkedAt) <= _geoMaxAge) {
      return hit.lat != null && hit.lon != null ? LatLng(hit.lat!, hit.lon!) : null;
    }
    final pos = await _geocoding.geocodeAddress(key);
    _geoCache[key] = (checkedAt: DateTime.now(), lat: pos?.latitude, lon: pos?.longitude);
    return pos;
  }

  Place _candidateToPlace(RawEventCandidate c, LatLng pos) {
    final idHash = c.url.hashCode.toUnsigned(32).toRadixString(36);
    final kind = switch (c.category) {
      PlaceCategory.volunteer => 'ボランティア（開催地）',
      PlaceCategory.experience => _experienceKind(c.title, c.description),
      _ => _matchmakingKind(c.title, c.description),
    };
    return Place(
      id: 'event/$idHash',
      name: c.title,
      position: pos,
      categories: {c.category},
      kind: kind,
      address: c.address,
      website: c.url,
      precomputed: true,
      audience: audienceOf(const {}, c.title),
      event: EventInfo(
        source: c.source,
        venue: c.venue,
        schedule: c.schedule,
        startAt: c.startAt,
        endAt: c.endAt,
        fee: c.fee,
        organizer: c.organizer,
        description: c.description,
      ),
    );
  }

  static String _experienceKind(String title, String? description) {
    final s = '$title ${description ?? ''}';
    if (RegExp(r'陶芸|ろくろ|金継ぎ|ガラス細工|ステンドグラス|切子|彫金|レザークラフト|木工').hasMatch(s)) {
      return '工芸・クラフト体験イベント';
    }
    if (RegExp(r'料理教室|パン作り|お菓子作り|スイーツ作り|和菓子|そば打ち|うどん打ち|味噌作り').hasMatch(s)) {
      return '料理・食体験イベント';
    }
    if (RegExp(r'ヨガ|ピラティス|ダンス|ボルダリング|SUP|カヤック|乗馬').hasMatch(s)) {
      return 'アクティビティ体験イベント';
    }
    if (RegExp(r'農業体験|収穫体験').hasMatch(s)) {
      return '農業・自然体験イベント';
    }
    if (RegExp(r'ワークショップ|workshop', caseSensitive: false).hasMatch(title)) {
      return '有償ワークショップ';
    }
    return '有償体験イベント';
  }

  static String _matchmakingKind(String title, String? description) {
    final s = '$title ${description ?? ''}';
    if (s.contains('合コン')) return '合コン';
    if (s.contains('街コン')) return '街コン';
    if (s.contains('恋活')) return '恋活イベント';
    return '婚活・交流イベント';
  }

  static List<Place> _dedupeEvents(List<Place> places) {
    final seenUrls = <String>{};
    final seenTitleSchedule = <String>{};
    final out = <Place>[];
    for (final p in places) {
      final url = p.website ?? p.id;
      if (!seenUrls.add(url)) continue;
      final normTitle = p.name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final key = '$normTitle|${p.event?.schedule ?? ''}';
      if (!seenTitleSchedule.add(key)) continue;
      out.add(p);
    }
    return out;
  }

  /// 同じ会場で複数の集まりがあるとき、マーカーが完全に重なって押せなくならないよう約 15m ずつ円形にずらす。
  static List<Place> _spreadCoLocated(List<Place> places) {
    final buckets = <String, int>{};
    return [
      for (final p in places)
        () {
          final cell = '${(p.position.latitude * 10000).round()}_${(p.position.longitude * 10000).round()}';
          final index = buckets[cell] = (buckets[cell] ?? 0) + 1;
          if (index == 1) return p;
          final angle = (index - 1) * (2 * math.pi / 6);
          final radiusDeg = 0.00014 * ((index + 4) ~/ 6);
          return Place(
            id: p.id,
            name: p.name,
            position: LatLng(
              p.position.latitude + radiusDeg * math.sin(angle),
              p.position.longitude + radiusDeg * math.cos(angle),
            ),
            categories: p.baseCategories,
            links: p.links,
            kind: p.kind,
            address: p.address,
            website: p.website,
            event: p.event,
            precomputed: p.precomputed,
            audience: p.audience,
          );
        }(),
    ];
  }

  Future<String?> _getHtml(String url) async {
    try {
      final res = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': OverpassService.userAgent,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'ja,en;q=0.5',
        },
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ---------------- JSON-LD 解析ヘルパー ----------------

  static List<Map<String, dynamic>> _extractLdEvents(String html) {
    final events = <Map<String, dynamic>>[];
    for (final m in _ldJsonPattern.allMatches(html)) {
      final raw = m.group(1)!.replaceAll('//<![CDATA[', '').replaceAll('//]]>', '').trim();
      if (raw.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      void collect(Object? node) {
        if (node is List) {
          for (final item in node) {
            collect(item);
          }
        } else if (node is Map) {
          if (node['@type'] == 'Event') {
            events.add(node.cast<String, dynamic>());
          } else if (node['@graph'] is List) {
            collect(node['@graph']);
          }
        }
      }

      collect(decoded);
    }
    return events;
  }

  static bool _isOnlineOnly(Map<String, dynamic> event) {
    final mode = (event['eventAttendanceMode'] as String?) ?? '';
    return mode.contains('OnlineEventAttendanceMode') && !mode.contains('Mixed');
  }

  static bool _isUpcoming(Map<String, dynamic> event, DateTime cutoff) {
    final raw = (event['endDate'] ?? event['startDate']) as String?;
    if (raw == null) return true;
    final trimmed = raw.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
      final day = DateTime.tryParse(trimmed);
      if (day == null) return true;
      return day.add(const Duration(days: 1)).isAfter(cutoff);
    }
    final parsed = _parseIso(trimmed);
    return parsed == null || parsed.isAfter(cutoff);
  }

  static DateTime? _parseEventDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final trimmed = raw.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
      return DateTime.tryParse(trimmed);
    }
    return _parseIso(trimmed)?.toLocal();
  }

  static DateTime? _parseIso(String raw) {
    // "+0900" のようにコロンなしのオフセットも DateTime.tryParse で読める形に揃える
    final normalized = raw.replaceFirstMapped(RegExp(r'([+-]\d{2})(\d{2})$'), (m) => '${m[1]}:${m[2]}');
    return DateTime.tryParse(normalized);
  }

  static String? _formatSchedule(String? startRaw, String? endRaw) {
    if (startRaw == null) return null;
    final dateOnlyStart = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(startRaw.trim());
    final start = _parseEventDateTime(startRaw);
    if (start == null) return null;
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    final wd = weekdays[start.weekday - 1];
    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final base = dateOnlyStart ? '${start.month}/${start.day}($wd)' : '${start.month}/${start.day}($wd) ${hm(start)}';
    final dateOnlyEnd = endRaw != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(endRaw.trim());
    final end = _parseEventDateTime(endRaw);
    if (end == null) return base;
    if (end.year == start.year && end.month == start.month && end.day == start.day) {
      return (dateOnlyStart || dateOnlyEnd) ? base : '$base〜${hm(end)}';
    }
    final endWd = weekdays[end.weekday - 1];
    return '$base〜${end.month}/${end.day}($endWd)';
  }

  static String? _extractPostalAddress(Object? addr) {
    if (addr is String) return _dedupePref(_cleanText(addr));
    if (addr is Map) {
      final parts = [
        _cleanText(addr['addressRegion'] as String?),
        _cleanText(addr['addressLocality'] as String?),
        _cleanText(addr['streetAddress'] as String?),
      ].whereType<String>().where((s) => s.isNotEmpty).toList();
      if (parts.isEmpty) return null;
      return _dedupePref(parts.join(' '));
    }
    return null;
  }

  static String? _dedupePref(String? s) {
    if (s == null || s.isEmpty) return null;
    return s.replaceAllMapped(RegExp(r'(北海道|東京都|(?:京都|大阪)府|.{2,3}県)\s*\1+'), (m) => m[1]!).trim();
  }

  static String _normalizePrefecturePrefix(String region) {
    if (region.isEmpty) return '';
    if (region == '北海道' || region.endsWith('都') || region.endsWith('府') || region.endsWith('県')) return region;
    if (region == '東京') return '東京都';
    if (region == '京都' || region == '大阪') return '$region府';
    return '$region県';
  }

  static String? _extractOrganizer(Object? org) {
    if (org is String) return _cleanText(org);
    if (org is Map) return _cleanText(org['name'] as String?);
    return null;
  }

  static bool _hasPositiveOfferPrice(Object? offers) {
    final list = offers is List ? offers : [?offers];
    for (final o in list) {
      if (o is! Map) continue;
      final price = _toDouble(o['price']);
      if (price != null && price > 0) return true;
    }
    return false;
  }

  static bool _isZeroOfferPrice(Object? offers) {
    final list = offers is List ? offers : [?offers];
    var sawZero = false;
    for (final o in list) {
      if (o is! Map) continue;
      final price = _toDouble(o['price']);
      if (price == null) continue;
      if (price > 0) return false;
      if (price == 0) sawZero = true;
    }
    return sawZero;
  }

  static String? _extractTextFee(String text) {
    final m = _textFeePattern.firstMatch(text);
    if (m == null) return null;
    return m.group(1)!.replaceAll('，', ',').replaceAll(RegExp(r'\s+'), '');
  }

  static String? _extractOffersFee(Object? offers) {
    final list = offers is List ? offers : [?offers];
    final labels = <String>[];
    for (final o in list) {
      if (o is! Map) continue;
      final price = _toDouble(o['price']);
      if (price == null) continue;
      final formatted = price == 0 ? '無料' : '${_comma(price.round())}円';
      final rawName = _cleanText(o['name'] as String?);
      final name = (rawName != null && !rawName.startsWith('http') && rawName.length <= 16) ? '$rawName ' : '';
      final entry = '$name$formatted';
      if (!labels.contains(entry)) labels.add(entry);
    }
    return labels.isEmpty ? null : labels.take(2).join(' / ');
  }

  static String _comma(int n) =>
      n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  static double? _toDouble(Object? v) => switch (v) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s.trim()),
        _ => null,
      };

  static String? _cleanText(String? raw) {
    if (raw == null) return null;
    final stripped = raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>|</li>|</h\d>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'[ \t\u3000]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return stripped.isEmpty ? null : stripped;
  }

  // ---------------- 端末キャッシュの読み書き ----------------

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _cacheFile = File('${dir.path}${Platform.pathSeparator}event_cache_v1.json');
      if (!await _cacheFile!.exists()) return;
      final json = jsonDecode(await _cacheFile!.readAsString()) as Map<String, dynamic>;
      if (json['details'] case final Map details) {
        for (final MapEntry(:key, :value) in details.entries) {
          if (value is Map) {
            _detailCache[key as String] = (
              checkedAt: DateTime.parse(value['t'] as String),
              venue: value['v'] as String?,
              address: value['a'] as String?,
              fee: value['f'] as String?,
            );
          }
        }
      }
      if (json['geo'] case final Map geo) {
        for (final MapEntry(:key, :value) in geo.entries) {
          if (value is Map) {
            _geoCache[key as String] = (
              checkedAt: DateTime.parse(value['t'] as String),
              lat: (value['lat'] as num?)?.toDouble(),
              lon: (value['lon'] as num?)?.toDouble(),
            );
          }
        }
      }
    } catch (_) {
      // キャッシュが壊れていれば作り直す
    }
  }

  Future<void> _saveCache() async {
    final file = _cacheFile;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode({
        'details': {
          for (final MapEntry(:key, :value) in _detailCache.entries)
            if (DateTime.now().difference(value.checkedAt) <= _detailMaxAge)
              key: {
                't': value.checkedAt.toIso8601String(),
                'v': value.venue,
                'a': value.address,
                'f': value.fee,
              },
        },
        'geo': {
          for (final MapEntry(:key, :value) in _geoCache.entries)
            if (DateTime.now().difference(value.checkedAt) <= _geoMaxAge)
              key: {
                't': value.checkedAt.toIso8601String(),
                'lat': value.lat,
                'lon': value.lon,
              },
        },
      }));
    } catch (_) {
      // 保存に失敗しても動作には影響しない
    }
  }
}
