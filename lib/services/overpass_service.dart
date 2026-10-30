import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 緯度経度の矩形。
class Bounds {
  const Bounds(this.south, this.west, this.north, this.east);

  final double south, west, north, east;

  String get overpass => [south, west, north, east].map((v) => v.toStringAsFixed(6)).join(',');
}

/// OpenStreetMap の Overpass API から、対象スポットの生データ（要素）を取得する。
class OverpassService {
  static const userAgent = 'nearby_insta/0.3 (+https://github.com/PG-Darksan/nearby_insta)';

  /// 公開サーバーは混雑しやすいので、応答が遅いときは次のサーバーにも並行して問い合わせ、
  /// 最初に返ってきた結果を使う。
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];
  static const _hedgeDelay = Duration(seconds: 10);
  static const _requestTimeout = Duration(seconds: 90);

  Future<List<Map<String, dynamic>>> fetch(Bounds bounds, {void Function(String)? onStatus}) async {
    final query = buildQuery(bounds);
    try {
      return await _hedged(query, onStatus);
    } catch (_) {
      onStatus?.call('地図データのサーバーが混雑しています。再試行中…');
      await Future<void>.delayed(const Duration(seconds: 3));
      return _hedged(query, onStatus);
    }
  }

  Future<List<Map<String, dynamic>>> _hedged(String query, void Function(String)? onStatus) {
    final completer = Completer<List<Map<String, dynamic>>>();
    final clients = <http.Client>[];
    final errors = <Object>[];
    var started = 0;
    var running = 0;

    void startNext() {
      if (completer.isCompleted || started >= _endpoints.length) return;
      final endpoint = _endpoints[started++];
      if (started > 1) onStatus?.call('サーバーの応答が遅いため、別のサーバーにも問い合わせています… ($started/${_endpoints.length})');
      final client = http.Client();
      clients.add(client);
      running++;
      () async {
        try {
          final res = await client
              .post(Uri.parse(endpoint), headers: {'User-Agent': userAgent}, body: {'data': query})
              .timeout(_requestTimeout);
          if (res.statusCode == 200) {
            final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
            if (!completer.isCompleted) completer.complete((json['elements'] as List).cast<Map<String, dynamic>>());
          } else {
            errors.add('HTTP ${res.statusCode}');
            startNext();
          }
        } catch (e) {
          errors.add(e);
          startNext();
        } finally {
          running--;
          if (running == 0 && started >= _endpoints.length && !completer.isCompleted) {
            completer.completeError(Exception(
                '地図データのサーバー（Overpass API）が混雑しています。少し時間をおいて再検索してください。（${errors.join(' / ')}）'));
          }
        }
      }();
    }

    startNext();
    final hedge = Timer.periodic(_hedgeDelay, (_) => startNext());
    return completer.future.whenComplete(() {
      hedge.cancel();
      for (final c in clients) {
        c.close();
      }
    });
  }

  /// 小中学校は取らず、高校は名前か isced:level で絞って転送量を減らす。
  static String buildQuery(Bounds b) {
    return '[out:json][timeout:90][bbox:${b.overpass}];'
        '('
        'nwr["contact:instagram"];'
        'nwr["instagram"];'
        'nwr["amenity"="school"]["name"~"高等学校|高校|中等教育学校|high school",i];'
        'nwr["amenity"="school"]["isced:level"~"3"];'
        'nwr["amenity"~"^(university|college)\$"];'
        'nwr["name"~"ボランティア|社会福祉協議会|市民活動|NPOセンター|volunteer",i];'
        'nwr["name"~"体験|ワークショップ|workshop|陶芸",i];'
        'nwr["craft"~"^(pottery|glassblower)\$"];'
        ');'
        'out tags center;';
  }
}
