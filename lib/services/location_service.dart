import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

enum LocationSource { device, ip, manual }

class _DeviceUnavailable implements Exception {
  const _DeviceUnavailable(this.reason);
  final String reason;
}

class LocationResult {
  const LocationResult(this.position, this.source, {this.label, this.note});
  final LatLng position;
  final LocationSource source;
  final String? label;

  /// 端末の位置情報が使えなかった理由など、ユーザーに伝える補足。
  final String? note;
}

/// 現在地を取得する。Windows の位置情報サービスを優先し、使えなければ IP アドレスから推定する。
class LocationService {
  LocationService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<LocationResult> getCurrentLocation() async {
    String reason;
    try {
      final device = await _fromDevice();
      return LocationResult(device, LocationSource.device, label: '端末の位置情報');
    } on _DeviceUnavailable catch (e) {
      reason = e.reason;
    } catch (_) {
      reason = '端末の位置情報を取得できませんでした';
    }
    final ip = await _fromIp();
    return LocationResult(ip.$1, LocationSource.ip,
        label: ip.$2, note: '$reason。IP アドレスからおおよその位置を推定しています。');
  }

  Future<LatLng> _fromDevice() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const _DeviceUnavailable('Windows の位置情報サービスがオフです');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw const _DeviceUnavailable('位置情報へのアクセスが許可されていません');
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return LatLng(pos.latitude, pos.longitude);
  }

  Future<(LatLng, String)> _fromIp() async {
    final providers = <(String, (LatLng, String)? Function(Map<String, dynamic>))>[
      ('https://ipapi.co/json/', (j) => _pick(j['latitude'], j['longitude'], j['city'])),
      ('https://ipwho.is/', (j) => _pick(j['latitude'], j['longitude'], j['city'])),
    ];
    for (final (url, parse) in providers) {
      try {
        final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final result = parse(jsonDecode(res.body) as Map<String, dynamic>);
        if (result != null) return result;
      } catch (_) {
        // 次のプロバイダを試す
      }
    }
    throw Exception('現在地を取得できませんでした。地図を右クリックして検索地点を指定してください。');
  }

  (LatLng, String)? _pick(Object? lat, Object? lon, Object? city) {
    if (lat is! num || lon is! num) return null;
    return (LatLng(lat.toDouble(), lon.toDouble()), 'IP 推定${city is String ? '（$city 付近）' : ''}');
  }
}
