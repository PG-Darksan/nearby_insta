import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/place.dart';

/// OpenStreetMap の Overpass API で、近くの対象スポットをまとめて取得する。
class OverpassService {
  OverpassService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const userAgent = 'nearby_insta/0.2 (+https://github.com/PG-Darksan/nearby_insta)';

  /// 公開サーバーは混雑しやすいので、待ち時間を挟みながら順番に試す。
  static const _attempts = [
    ('https://overpass-api.de/api/interpreter', Duration.zero),
    ('https://overpass.private.coffee/api/interpreter', Duration.zero),
    ('https://overpass-api.de/api/interpreter', Duration(seconds: 5)),
    ('https://overpass.kumi.systems/api/interpreter', Duration.zero),
  ];

  /// [center] から [radiusMeters] を囲む矩形内の場所を返す。円内への絞り込みは呼び出し側で行う。
  /// [onRetry] には再試行するたびに状況説明の文字列が渡される。
  Future<List<Place>> search(LatLng center, int radiusMeters, {void Function(String)? onRetry}) async {
    final query = buildQuery(center, radiusMeters);
    var busy = false;
    Object? lastError;

    for (var i = 0; i < _attempts.length; i++) {
      final (endpoint, wait) = _attempts[i];
      if (i > 0) onRetry?.call('地図データのサーバーが混雑しています。再試行中… (${i + 1}/${_attempts.length})');
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        final res = await _client
            .post(Uri.parse(endpoint), headers: {'User-Agent': userAgent}, body: {'data': query})
            .timeout(const Duration(seconds: 45));
        if (res.statusCode == 200) {
          final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          return parse(json);
        }
        busy |= const {429, 502, 503, 504}.contains(res.statusCode);
        lastError = 'HTTP ${res.statusCode}';
      } on TimeoutException {
        busy = true;
        lastError = 'タイムアウト';
      } catch (e) {
        lastError = e;
      }
    }
    if (busy) {
      throw Exception('地図データのサーバー（Overpass API）が混雑しています。少し時間をおいて再検索してください。');
    }
    throw Exception('地図データを取得できませんでした: $lastError');
  }

  static String buildQuery(LatLng center, int radiusMeters) {
    final dLat = radiusMeters / 111320;
    final dLon = radiusMeters / (111320 * math.cos(center.latitude * math.pi / 180));
    final bbox = [
      center.latitude - dLat,
      center.longitude - dLon,
      center.latitude + dLat,
      center.longitude + dLon,
    ].map((v) => v.toStringAsFixed(6)).join(',');
    return '[out:json][timeout:25][bbox:$bbox];'
        '('
        'nwr["contact:instagram"];'
        'nwr["instagram"];'
        'nwr["amenity"~"^(school|university|college)\$"];'
        'nwr["name"~"ボランティア|社会福祉協議会|市民活動|NPOセンター|volunteer",i];'
        'nwr["name"~"体験|ワークショップ|workshop|陶芸",i];'
        'nwr["craft"~"^(pottery|glassblower)\$"];'
        ');'
        'out tags center 2000;';
  }

  static List<Place> parse(Map<String, dynamic> json) {
    final seen = <String>{};
    final places = <Place>[];
    for (final el in (json['elements'] as List).cast<Map<String, dynamic>>()) {
      final place = Place.fromOsm(el);
      if (place == null) continue;
      // 同じ施設が建物とノードの両方に登録されていることがあるので、名前と Instagram で重複を除く。
      final key = '${place.name}|${place.instagram?.url ?? ''}'.toLowerCase();
      if (!seen.add(key)) continue;
      places.add(place);
    }
    return places;
  }
}
