import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Instagram のフォロー中・フォロワー一覧から抽出した 1 アカウント分の判定対象。
class InstagramAccountCandidate {
  const InstagramAccountCandidate({required this.username, this.displayName = ''});

  final String username;
  final String displayName;

  String get cacheKey => '${username.trim().toLowerCase()}|${displayName.trim().toLowerCase()}';
}

/// TypeSafe AI の判断特化モデル「Jev」（System One API）を用いて、
/// Instagram のフォロー中・フォロワー一覧にあるアカウント名（@username・表示名）が
/// 男性個人のアカウントかどうかを判定するサービス。
///
/// API キーは端末内の設定ファイル（`jev_settings.json`）にのみ保存し、リポジトリには一切含めない。
class JevService extends ChangeNotifier {
  JevService({http.Client? client, File? settingsFile, File? cacheFile, bool inMemoryOnly = false})
      : _client = client ?? http.Client(),
        _settingsFile = settingsFile,
        _cacheFile = cacheFile,
        _inMemoryOnly = inMemoryOnly,
        _loaded = inMemoryOnly;

  static const endpoint = 'https://api.typesafe.ai/v1/systemone';
  static const modelName = 'jev-latest';
  static const defaultThreshold = 0.65;
  static const batchSize = 15;
  static const _cacheMaxAge = Duration(days: 90);
  static const _maxCacheEntries = 8000;

  static const _envApiKey = String.fromEnvironment('TYPESAFE_API_KEY');

  final http.Client _client;
  File? _settingsFile;
  File? _cacheFile;
  final bool _inMemoryOnly;
  bool _loaded;
  Future<void>? _loading;

  String _apiKey = _envApiKey;
  bool _hideMaleAccounts = false;
  double _threshold = defaultThreshold;
  String? lastError;

  /// `username|displayName` -> 判定済みの男性確率（0.0〜1.0）。
  /// 確率そのものを保存しておくことで、しきい値を変えたときも再課金なしで即時反映できる。
  final _cache = <String, ({double noul, DateTime at})>{};

  String get apiKey => _apiKey;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  bool get hideMaleAccounts => _hideMaleAccounts;
  double get threshold => _threshold;

  /// Jev による男性アカウント非表示が現在有効に動作する状態か。
  bool get isActive => _hideMaleAccounts && hasApiKey;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      if (_settingsFile == null || _cacheFile == null) {
        final dir = await getApplicationSupportDirectory();
        _settingsFile ??= File('${dir.path}${Platform.pathSeparator}jev_settings.json');
        _cacheFile ??= File('${dir.path}${Platform.pathSeparator}jev_account_cache.json');
      }
      if (await _settingsFile!.exists()) {
        final json = jsonDecode(await _settingsFile!.readAsString()) as Map<String, dynamic>;
        final savedKey = (json['apiKey'] as String?)?.trim() ?? '';
        if (savedKey.isNotEmpty) _apiKey = savedKey;
        _hideMaleAccounts = json['hideMaleAccounts'] as bool? ?? savedKey.isNotEmpty;
        _threshold = ((json['threshold'] as num?)?.toDouble() ?? defaultThreshold).clamp(0.45, 0.90);
      } else if (_envApiKey.isNotEmpty) {
        _hideMaleAccounts = true;
      }

      if (await _cacheFile!.exists()) {
        final json = jsonDecode(await _cacheFile!.readAsString()) as Map<String, dynamic>;
        final now = DateTime.now();
        for (final MapEntry(:key, :value) in json.entries) {
          if (value is Map) {
            final noul = (value['p'] as num?)?.toDouble();
            final epoch = value['t'] as int?;
            if (noul != null && epoch != null) {
              final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
              if (now.difference(at) <= _cacheMaxAge) {
                _cache[key] = (noul: noul, at: at);
              }
            }
          }
        }
      }
    } on MissingPluginException {
      // 単体テスト環境では path_provider が無効なためメモリ内設定のみで動作する
    } catch (e) {
      debugPrint('Jev 設定の読み込みに失敗: $e');
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> updateSettings({
    String? apiKey,
    bool? hideMaleAccounts,
    double? threshold,
  }) async {
    await ensureLoaded();
    if (apiKey != null) _apiKey = apiKey.trim();
    if (hideMaleAccounts != null) _hideMaleAccounts = hideMaleAccounts;
    if (threshold != null) _threshold = threshold.clamp(0.45, 0.90);
    lastError = null;
    notifyListeners();
    if (!_inMemoryOnly) await _saveSettings();
  }

  Future<void> _saveSettings() async {
    try {
      final file = _settingsFile;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'apiKey': _apiKey,
        'hideMaleAccounts': _hideMaleAccounts,
        'threshold': _threshold,
      }));
    } catch (e) {
      debugPrint('Jev 設定の保存に失敗: $e');
    }
  }

  Future<void> clearCache() async {
    _cache.clear();
    try {
      if (_cacheFile != null && await _cacheFile!.exists()) {
        await _cacheFile!.delete();
      }
    } catch (_) {}
    notifyListeners();
  }

  /// [candidates] の各アカウントについて、`username -> 男性アカウントか(bool)` を返す。
  /// キャッシュ済みのものは通信せずに即座に返し、未判定のものだけを Jev にまとめて問い合わせる。
  Future<Map<String, bool>> judgeMaleAccounts(List<InstagramAccountCandidate> candidates) async {
    await ensureLoaded();
    if (!hasApiKey || candidates.isEmpty) return const {};

    final result = <String, bool>{};
    final pending = <InstagramAccountCandidate>[];
    final seenKeys = <String>{};

    for (final c in candidates) {
      final user = c.username.trim();
      if (user.isEmpty) continue;
      final hit = _cache[c.cacheKey];
      if (hit != null && DateTime.now().difference(hit.at) <= _cacheMaxAge) {
        result[user] = hit.noul >= _threshold;
      } else if (seenKeys.add(c.cacheKey)) {
        pending.add(c);
      }
    }

    if (pending.isEmpty) return result;

    final batches = <List<InstagramAccountCandidate>>[
      for (var i = 0; i < pending.length; i += batchSize)
        pending.sublist(i, (i + batchSize).clamp(0, pending.length)),
    ];

    var cacheDirty = false;
    var index = 0;
    Future<void> worker() async {
      while (index < batches.length) {
        final batch = batches[index++];
        final probs = await _queryBatch(batch, key: _apiKey);
        if (probs == null) continue;
        final now = DateTime.now();
        for (final c in batch) {
          final p = probs[c.username];
          if (p == null) continue;
          _cache[c.cacheKey] = (noul: p, at: now);
          result[c.username] = p >= _threshold;
          cacheDirty = true;
        }
      }
    }

    await Future.wait([for (var w = 0; w < (batches.length < 2 ? batches.length : 2); w++) worker()]);
    if (cacheDirty) unawaited(_saveCache());
    return result;
  }

  /// 設定ダイアログ用の接続テスト。サンプル 2 件（男性名・女性名）で Jev の応答と確率を確かめる。
  Future<({bool ok, String message})> testConnection(String candidateKey) async {
    final trimmed = candidateKey.trim();
    if (trimmed.isEmpty) {
      return (ok: false, message: 'API キーを入力してください');
    }
    const sample = [
      InstagramAccountCandidate(username: 'taro_yamada_1998', displayName: '山田 太郎'),
      InstagramAccountCandidate(username: 'hanako_sato_04', displayName: '佐藤 花子'),
    ];
    final probs = await _queryBatch(sample, key: trimmed, recordError: true);
    if (probs == null || probs.isEmpty) {
      return (ok: false, message: lastError ?? 'Jev からの応答を取得できませんでした');
    }
    final maleP = ((probs['taro_yamada_1998'] ?? 0) * 100).round();
    final femaleP = ((probs['hanako_sato_04'] ?? 0) * 100).round();
    return (
      ok: true,
      message: 'Jev に接続できました（テスト判定: 山田太郎 $maleP% / 佐藤花子 $femaleP%）',
    );
  }

  Future<Map<String, double>?> _queryBatch(
    List<InstagramAccountCandidate> batch, {
    required String key,
    bool recordError = true,
  }) async {
    try {
      final res = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(buildRequestBody(batch)),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        final msg = switch (res.statusCode) {
          401 || 403 => 'Jev API キーが無効です（HTTP ${res.statusCode}）',
          402 => 'TypeSafe API のクレジット残高が不足しています（HTTP 402）',
          429 => 'Jev のリクエスト上限に達しました。しばらく待ってから再試行してください',
          _ => 'Jev エラー（HTTP ${res.statusCode}）',
        };
        if (recordError && lastError != msg) {
          lastError = msg;
          notifyListeners();
        }
        return null;
      }
      if (lastError != null) {
        lastError = null;
        notifyListeners();
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return parseResponseProbabilities(decoded, batch);
    } catch (e) {
      final msg = 'Jev への通信に失敗しました: $e';
      if (recordError && lastError != msg) {
        lastError = msg;
        notifyListeners();
      }
      return null;
    }
  }

  /// TypeSafe System One (`jev-latest`) に送るリクエスト JSON を組み立てる。
  static Map<String, dynamic> buildRequestBody(List<InstagramAccountCandidate> batch) {
    final state = StringBuffer()
      ..writeln(
        'Task: Judge whether each numbered Instagram account belongs to a male individual '
        'based on its @username and display name.',
      )
      ..writeln(
        '- True (male): Japanese or foreign male given names in kanji, hiragana, katakana, or romaji '
        '(e.g. 太郎, 翔太, 健太, 大輔, 拓哉, 裕太, 涼太, 航平, 蓮, 颯太, 陽翔, 誠, 剛, 隆, 浩, 徹, 駿, 翼, 陸, 海斗, 大樹, 悠真, 直樹, 和樹, 達也, '
        'taro, kenji, shota, kenta, daisuke, takuya, yuta, ryota, kohei, hiroshi, makoto, kazuki, tatsuya, naoki, shun, daiki, kaito, haruto, souta, etc.) '
        'or explicit male self-identifiers (男子, パパ, 俺, 僕, くん, Mr.).',
      )
      ..writeln(
        '- False (not male): Female names, shops, cafes, salons, brands, companies, schools, clubs, '
        'event accounts, or ambiguous handles with no clear male name signal.',
      )
      ..writeln()
      ..writeln('Accounts:');

    final questions = <String, Map<String, dynamic>>{};
    for (var i = 0; i < batch.length; i++) {
      final item = batch[i];
      final u = item.username.trim().replaceAll('"', '');
      var d = item.displayName.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll('"', "'");
      if (d.length > 80) d = d.substring(0, 80);
      state.writeln('#$i: @username="$u" | display_name="${d.isEmpty ? '(none)' : d}"');
      questions['q_$i'] = {
        'type': 'noul',
        'instructions': "Is account #$i (@$u) a male person's account?",
        'criteria': {
          'true': 'Male personal name or male personal account',
          'false': 'Female name, shop/organization/club, or gender-ambiguous',
        },
      };
    }

    return {
      'model': modelName,
      'state': state.toString().trimRight(),
      'questions': questions,
    };
  }

  /// Jev のレスポンス JSON から `username -> noul(男性確率 0.0〜1.0)` を取り出す。
  static Map<String, double> parseResponseProbabilities(
    Map<String, dynamic> json,
    List<InstagramAccountCandidate> batch,
  ) {
    final out = <String, double>{};
    final answers = json['answers'];
    if (answers is! Map) return out;
    for (var i = 0; i < batch.length; i++) {
      final raw = answers['q_$i'];
      if (raw is! Map) continue;
      double? prob = (raw['noul'] as num?)?.toDouble();
      if (prob == null && raw['probabilities'] is Map) {
        final probs = raw['probabilities'] as Map;
        prob = (probs['true'] as num?)?.toDouble();
      }
      if (prob != null && prob.isFinite) {
        out[batch[i].username] = prob.clamp(0.0, 1.0);
      }
    }
    return out;
  }

  Future<void> _saveCache() async {
    final file = _cacheFile;
    if (file == null) return;
    try {
      if (_cache.length > _maxCacheEntries) {
        final sorted = _cache.entries.toList()..sort((a, b) => b.value.at.compareTo(a.value.at));
        _cache
          ..clear()
          ..addEntries(sorted.take(_maxCacheEntries));
      }
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        for (final MapEntry(:key, :value) in _cache.entries)
          key: {
            'p': double.parse(value.noul.toStringAsFixed(4)),
            't': value.at.millisecondsSinceEpoch ~/ 1000,
          },
      }));
    } catch (_) {
      // キャッシュ保存失敗は動作に影響しない
    }
  }
}
