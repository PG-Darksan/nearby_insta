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

class ReverseGeoResult {
  const ReverseGeoResult({this.town, this.prefCode, this.muniCode});

  /// 町名（例: 渋谷二丁目）。国外や海上では null。
  final String? town;

  /// 都道府県コード（1〜47）。
  final int? prefCode;

  /// 市区町村コード（5桁、例: 14108）。
  final String? muniCode;
}

/// 地名・住所から場所を探す。国内の住所は国土地理院、施設名などは Nominatim (OSM) を使う。
class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final _reverseCache = <String, ReverseGeoResult>{};
  final _addressCache = <String, LatLng?>{};

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

  /// 地点のおおよその町名（例: 渋谷二丁目）と都道府県コード。国外や海上では空。
  Future<ReverseGeoResult> reverse(LatLng p) async {
    final key = '${p.latitude.toStringAsFixed(3)}_${p.longitude.toStringAsFixed(3)}';
    if (_reverseCache[key] case final cached?) return cached;
    try {
      final uri = Uri.https('mreversegeocoder.gsi.go.jp', '/reverse-geocoder/LonLatToAddress',
          {'lat': '${p.latitude}', 'lon': '${p.longitude}'});
      final res = await _client.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return const ReverseGeoResult();
      final results = (jsonDecode(res.body) as Map<String, dynamic>)['results'] as Map<String, dynamic>?;
      if (results == null) return const ReverseGeoResult();
      final rawName = results['lv01Nm'];
      final town = rawName is String && rawName.isNotEmpty && rawName != '－' ? rawName : null;
      final muni = results['muniCd'] as String?;
      final pref = muni != null && muni.length >= 2 ? int.tryParse(muni.substring(0, 2)) : null;
      final out = ReverseGeoResult(town: town, prefCode: pref, muniCode: muni);
      _reverseCache[key] = out;
      return out;
    } catch (_) {
      return const ReverseGeoResult();
    }
  }

  /// 地点のおおよその町名（例: 渋谷二丁目）。国外や海上では null。
  Future<String?> placeName(LatLng p) async => (await reverse(p)).town;

  /// 日本国内の住所文字列から座標を1件求める（イベント会場の住所変換用）。
  Future<LatLng?> geocodeAddress(String address) async {
    final cleaned = _cleanAddressForGsi(address);
    if (cleaned.isEmpty) return null;
    if (_addressCache.containsKey(cleaned)) return _addressCache[cleaned];
    final results = await _gsi(cleaned);
    if (results.isNotEmpty) {
      return _addressCache[cleaned] = results.first.position;
    }
    // ビル名・会場名が末尾に付いていると一致しないことがあるため、空白の前の住所部分だけで再試行する
    final firstPart = cleaned.split(' ').first;
    if (firstPart != cleaned && firstPart.length >= 5) {
      final retry = await _gsi(firstPart);
      if (retry.isNotEmpty) {
        return _addressCache[cleaned] = retry.first.position;
      }
    }
    return _addressCache[cleaned] = null;
  }

  static String _cleanAddressForGsi(String raw) {
    return raw
        .replaceAll(RegExp(r'〒\s*\d{3}-?\d{4}'), '')
        .replaceAll(RegExp(r'[　\t\r\n]+'), ' ')
        .replaceAllMapped(RegExp(r'(北海道|東京都|(?:京都|大阪)府|.{2,3}県)\s*\1+'), (m) => m[1]!)
        .replaceAll(RegExp(r'【[^】]*】|（[^）]*）|\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\s+\d+\s*[階FＦ].*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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
