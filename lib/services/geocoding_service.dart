import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'overpass_service.dart';

class GeoResult {
  const GeoResult(this.title, this.position, {this.subtitle});
  final String title;
  final String? subtitle;
  final LatLng position;
}

/// 地名・住所から場所を探す。国内の住所は国土地理院、施設名などは Nominatim (OSM) を使う。
class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 入力が確定したときだけ呼ぶこと（Nominatim は入力途中の自動補完での利用が禁止されている）。
  Future<List<GeoResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final results = await Future.wait([_gsi(q), _nominatim(q)]);
    final merged = <GeoResult>[];
    for (final r in [...results[1], ...results[0]]) {
      // ほぼ同じ地点の重複は除く
      if (merged.any((m) => const Distance().distance(m.position, r.position) < 50)) continue;
      merged.add(r);
    }
    return merged.take(15).toList();
  }

  /// 地点のおおよその町名（例: 渋谷二丁目）。国外や海上では null。
  Future<String?> placeName(LatLng p) async {
    try {
      final uri = Uri.https('mreversegeocoder.gsi.go.jp', '/reverse-geocoder/LonLatToAddress',
          {'lat': '${p.latitude}', 'lon': '${p.longitude}'});
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final name = (jsonDecode(res.body) as Map<String, dynamic>)['results']?['lv01Nm'];
      return name is String && name.isNotEmpty && name != '－' ? name : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<GeoResult>> _gsi(String q) async {
    try {
      final uri = Uri.https('msearch.gsi.go.jp', '/address-search/AddressSearch', {'q': q});
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      return [
        for (final f in (jsonDecode(utf8.decode(res.bodyBytes)) as List).take(8))
          GeoResult(
            f['properties']['title'] as String,
            LatLng((f['geometry']['coordinates'][1] as num).toDouble(),
                (f['geometry']['coordinates'][0] as num).toDouble()),
            subtitle: '住所',
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<GeoResult>> _nominatim(String q) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': q,
        'format': 'jsonv2',
        'limit': '8',
        'accept-language': 'ja',
      });
      final res = await _client
          .get(uri, headers: {'User-Agent': OverpassService.userAgent})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      return [
        for (final r in jsonDecode(utf8.decode(res.bodyBytes)) as List)
          GeoResult(
            r['name'] is String && (r['name'] as String).isNotEmpty
                ? r['name'] as String
                : (r['display_name'] as String).split(',').first,
            LatLng(double.parse(r['lat'] as String), double.parse(r['lon'] as String)),
            subtitle: r['display_name'] as String,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
