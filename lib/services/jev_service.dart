import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// TypeSafe System One (`assets`) に渡せる形式（320×320 ピクセルの PNG / JPG）へ整えたアイコン画像。
typedef PreparedAvatar = ({String base64, String format});

/// アカウントのアイコン URL から画像を取得し、TypeSafe API の制限（280〜1568px, PNG/JPEG）に合わせて整形する関数。
typedef AvatarPreparer = Future<PreparedAvatar?> Function(String url, http.Client client);

/// Instagram・TikTok のフォロー中・フォロワー一覧から抽出した 1 アカウント分の判定対象（アイコン画像＋名前）。
class InstagramAccountCandidate {
  const InstagramAccountCandidate({
    required this.username,
    this.displayName = '',
    this.avatarUrl = '',
    this.avatarBase64,
    this.avatarFormat,
    this.platform = 'instagram',
  });

  final String username;
  final String displayName;

  /// 抽出元 SNS（`'instagram'` または `'tiktok'`）。
  final String platform;

  /// SNS CDN のプロフィールアイコン URL（WebView 側で `<canvas>` 取得できなかった場合のフォールバック用）。
  final String avatarUrl;

  /// WebView 側で 320×320 に描画して取得済みの Base64 画像データ（`data:` プレフィックスなし）。
  final String? avatarBase64;

  /// [avatarBase64] の画像形式（`'jpg'` または `'png'`）。
  final String? avatarFormat;

  bool get isTikTok => platform.trim().toLowerCase() == 'tiktok';

  bool get hasAvatarSource =>
      avatarUrl.trim().isNotEmpty || (avatarBase64 != null && avatarBase64!.trim().isNotEmpty);

  /// Instagram / TikTok CDN の署名クエリ（`?oh=...&oe=...` / `?x-expires=...&x-signature=...`）を除いた安定したアイコン識別子。
  String get avatarId {
    final rawUrl = avatarUrl.trim();
    if (rawUrl.isNotEmpty) {
      final uri = Uri.tryParse(rawUrl);
      final nonEmpty = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const <String>[];
      if (nonEmpty.isNotEmpty) {
        final last = nonEmpty.last;
        // TikTok CDN で末尾が "100x100.jpeg" 等の解像度名のみの場合は直前のハッシュも連結する
        if (nonEmpty.length >= 2 && RegExp(r'^\d+x\d+\.[a-z0-9]+$', caseSensitive: false).hasMatch(last)) {
          return '${nonEmpty[nonEmpty.length - 2]}_$last'.toLowerCase();
        }
        return last.toLowerCase();
      }
      return rawUrl.toLowerCase();
    }
    final b64 = avatarBase64?.trim() ?? '';
    if (b64.isNotEmpty) {
      // Base64 の末尾付近から短い識別子を作る
      final start = b64.length > 24 ? b64.length - 24 : 0;
      return 'b64_${b64.length}_${b64.substring(start)}';
    }
    return '';
  }

  /// Instagram の既存キャッシュキーと完全互換を保ちつつ、TikTok は `tt:` プレフィックスで衝突を防ぐ。
  String get cacheKey {
    final base = '${username.trim().toLowerCase()}|${displayName.trim().toLowerCase()}|$avatarId';
    return isTikTok ? 'tt:$base' : base;
  }
}

/// TypeSafe AI の判断特化モデル「Jev」（System One API）を用いて、
/// Instagram のフォロー中・フォロワー一覧にあるアカウントが「女性個人のアカウント」かどうかを
/// **プロフィールアイコン画像**・**@username**・**表示名**から判定し、掛かった費用を集計するサービス。
///
/// API キーは端末内の設定ファイル（`jev_settings.json`）にのみ保存し、リポジトリには一切含めない。
class JevService extends ChangeNotifier {
  JevService({
    http.Client? client,
    File? settingsFile,
    File? cacheFile,
    AvatarPreparer? avatarPreparer,
    bool inMemoryOnly = false,
  })  : _client = client ?? http.Client(),
        _settingsFile = settingsFile,
        _cacheFile = cacheFile,
        _avatarPreparer = avatarPreparer ?? defaultPrepareAvatar,
        _inMemoryOnly = inMemoryOnly,
        _loaded = inMemoryOnly;

  static const endpoint = 'https://api.typesafe.ai/v1/systemone';
  static const modelName = 'jev-latest';
  static const defaultThreshold = 0.55;

  /// アイコン画像を同時送信するため 1 リクエスト最大 8 アカウントにまとめ、コンテキスト長・容量制限内に余裕を持たせる。
  static const batchSize = 8;

  /// TypeSafe 公表料金: 入力 $0.042 / 100万トークン、出力トークンは無料 ($0)。
  static const inputUsdPerMTok = 0.042;

  /// 日本円換算の目安レート（表示用）。
  static const usdToJpyRate = 155.0;

  /// TypeSafe の画像サイズ制限（280〜1568px）を満たしつつ顔・雰囲気を判別しやすいアイコン解像度。
  static const avatarTargetPx = 320;

  static const _cacheMaxAge = Duration(days: 90);
  static const _maxCacheEntries = 8000;
  static const _envApiKey = String.fromEnvironment('TYPESAFE_API_KEY');

  final http.Client _client;
  final AvatarPreparer _avatarPreparer;
  File? _settingsFile;
  File? _cacheFile;
  final bool _inMemoryOnly;
  bool _loaded;
  Future<void>? _loading;
  int _nonceCounter = 0;

  String _apiKey = _envApiKey;
  bool _onlyFemaleAccounts = false;
  double _threshold = defaultThreshold;
  String? lastError;

  // Jev の利用料金・トークン集計（端末内に永続化）
  int _totalInputTokens = 0;
  int _totalApiCalls = 0;
  int _totalJudgedAccounts = 0;
  double _totalCostUsd = 0.0;

  // 今回のアプリ起動中の集計
  int _sessionInputTokens = 0;
  int _sessionApiCalls = 0;
  double _sessionCostUsd = 0.0;

  /// `username|displayName|avatarId` -> 判定済みの女性アカウント確率（0.0〜1.0）。
  final _cache = <String, ({double noul, DateTime at, bool hasImage})>{};

  /// 同一セッション中のアイコン整形結果キャッシュ（`avatarId` -> `PreparedAvatar`）。
  final _avatarMemory = <String, PreparedAvatar>{};

  String get apiKey => _apiKey;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;

  /// 女性アカウントのみを表示するフィルタが ON か。
  bool get onlyFemaleAccounts => _onlyFemaleAccounts;
  double get threshold => _threshold;

  /// Jev による女性アカウント抽出が現在有効に動作する状態か。
  bool get isActive => _onlyFemaleAccounts && hasApiKey;

  int get totalInputTokens => _totalInputTokens;
  int get totalApiCalls => _totalApiCalls;
  int get totalJudgedAccounts => _totalJudgedAccounts;
  double get totalCostUsd => _totalCostUsd;
  double get totalCostJpy => _totalCostUsd * usdToJpyRate;

  int get sessionInputTokens => _sessionInputTokens;
  int get sessionApiCalls => _sessionApiCalls;
  double get sessionCostUsd => _sessionCostUsd;
  double get sessionCostJpy => _sessionCostUsd * usdToJpyRate;

  /// 米ドルの金額を微小額でも 0 に潰れない桁数で整形する（例: `$0`, `$0.00042`, `$0.0125`）。
  static String formatUsd(double usd) {
    if (!usd.isFinite || usd <= 0) return r'$0';
    if (usd < 0.0001) return '\$${usd.toStringAsFixed(6)}';
    if (usd < 0.01) {
      final s = usd.toStringAsFixed(5).replaceFirst(RegExp(r'0+$'), '');
      return '\$${s.endsWith('.') ? '${s}0' : s}';
    }
    if (usd < 1) return '\$${usd.toStringAsFixed(4)}';
    return '\$${usd.toStringAsFixed(2)}';
  }

  /// 米ドルから日本円の目安表記を作る（例: `¥0`, `約¥0.07`, `約¥3.2`）。
  static String formatJpy(double usd) {
    if (!usd.isFinite || usd <= 0) return '¥0';
    final jpy = usd * usdToJpyRate;
    if (jpy < 0.01) return '約¥${jpy.toStringAsFixed(4)}';
    if (jpy < 1) return '約¥${jpy.toStringAsFixed(2)}';
    if (jpy < 100) return '約¥${jpy.toStringAsFixed(1)}';
    return '約¥${jpy.round()}';
  }

  /// ツールバーや設定欄に並べて出しやすい費用表記（例: `$0.0012 (約¥0.19)`）。
  static String formatCostCompact(double usd) {
    if (!usd.isFinite || usd <= 0) return r'$0 (¥0)';
    return '${formatUsd(usd)} (${formatJpy(usd)})';
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      if (_settingsFile == null || _cacheFile == null) {
        final dir = await getApplicationSupportDirectory();
        _settingsFile ??= File('${dir.path}${Platform.pathSeparator}jev_settings.json');
        _cacheFile ??= File('${dir.path}${Platform.pathSeparator}jev_female_cache_v2.json');
      }
      if (await _settingsFile!.exists()) {
        final json = jsonDecode(await _settingsFile!.readAsString()) as Map<String, dynamic>;
        final savedKey = (json['apiKey'] as String?)?.trim() ?? '';
        if (savedKey.isNotEmpty) _apiKey = savedKey;
        _onlyFemaleAccounts = (json['onlyFemaleAccounts'] as bool?) ??
            (json['hideMaleAccounts'] as bool?) ??
            savedKey.isNotEmpty;
        _threshold = ((json['threshold'] as num?)?.toDouble() ?? defaultThreshold).clamp(0.35, 0.90);
        _totalInputTokens = (json['totalInputTokens'] as num?)?.toInt() ?? 0;
        _totalApiCalls = (json['totalApiCalls'] as num?)?.toInt() ?? 0;
        _totalJudgedAccounts = (json['totalJudgedAccounts'] as num?)?.toInt() ?? 0;
        _totalCostUsd = (json['totalCostUsd'] as num?)?.toDouble() ?? 0.0;
      } else if (_envApiKey.isNotEmpty) {
        _onlyFemaleAccounts = true;
      }

      if (await _cacheFile!.exists()) {
        final json = jsonDecode(await _cacheFile!.readAsString()) as Map<String, dynamic>;
        final now = DateTime.now();
        for (final MapEntry(:key, :value) in json.entries) {
          if (value is Map) {
            final noul = (value['p'] as num?)?.toDouble();
            final epoch = value['t'] as int?;
            final hasImg = value['img'] == 1 || value['img'] == true;
            if (noul != null && epoch != null) {
              final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
              if (now.difference(at) <= _cacheMaxAge) {
                _cache[key] = (noul: noul, at: at, hasImage: hasImg);
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
    bool? onlyFemaleAccounts,
    double? threshold,
  }) async {
    await ensureLoaded();
    if (apiKey != null) _apiKey = apiKey.trim();
    if (onlyFemaleAccounts != null) _onlyFemaleAccounts = onlyFemaleAccounts;
    if (threshold != null) _threshold = threshold.clamp(0.35, 0.90);
    lastError = null;
    notifyListeners();
    if (!_inMemoryOnly) await _saveSettings();
  }

  /// 累計・セッションの Jev 費用カウンタを 0 にリセットする。
  Future<void> resetUsageStats() async {
    await ensureLoaded();
    _totalInputTokens = 0;
    _totalApiCalls = 0;
    _totalJudgedAccounts = 0;
    _totalCostUsd = 0.0;
    _sessionInputTokens = 0;
    _sessionApiCalls = 0;
    _sessionCostUsd = 0.0;
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
        'onlyFemaleAccounts': _onlyFemaleAccounts,
        'threshold': _threshold,
        'totalInputTokens': _totalInputTokens,
        'totalApiCalls': _totalApiCalls,
        'totalJudgedAccounts': _totalJudgedAccounts,
        'totalCostUsd': _totalCostUsd,
      }));
    } catch (e) {
      debugPrint('Jev 設定の保存に失敗: $e');
    }
  }

  Future<void> clearCache() async {
    _cache.clear();
    _avatarMemory.clear();
    try {
      if (_cacheFile != null && await _cacheFile!.exists()) {
        await _cacheFile!.delete();
      }
    } catch (_) {}
    notifyListeners();
  }

  /// [candidates] の各アカウントについて、`username -> 女性アカウントか(bool)` を返す。
  /// アイコン画像（Base64 または CDN URL から取得・320×320 化した画像）とアカウント名・表示名を Jev に渡して判定する。
  Future<Map<String, bool>> judgeFemaleAccounts(List<InstagramAccountCandidate> candidates) async {
    await ensureLoaded();
    if (!hasApiKey || candidates.isEmpty) return const {};

    final result = <String, bool>{};
    final pending = <InstagramAccountCandidate>[];
    final seenKeys = <String>{};

    for (final c in candidates) {
      final user = c.username.trim();
      if (user.isEmpty) continue;
      final hit = _cache[c.cacheKey];
      // 以前アイコン未取得で判定したものに今回アイコンが付いた場合は再判定する
      final needsUpgradeWithAvatar = hit != null && !hit.hasImage && c.hasAvatarSource;
      if (hit != null && !needsUpgradeWithAvatar && DateTime.now().difference(hit.at) <= _cacheMaxAge) {
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
        final avatars = await _prepareBatchAvatars(batch);
        final probs = await _queryBatch(batch, avatars: avatars, key: _apiKey);
        if (probs == null) continue;
        final now = DateTime.now();
        for (var i = 0; i < batch.length; i++) {
          final c = batch[i];
          final p = probs[c.username];
          if (p == null) continue;
          _cache[c.cacheKey] = (noul: p, at: now, hasImage: avatars.containsKey(i));
          result[c.username] = p >= _threshold;
          cacheDirty = true;
        }
      }
    }

    await Future.wait([for (var w = 0; w < (batches.length < 2 ? batches.length : 2); w++) worker()]);
    if (cacheDirty && !_inMemoryOnly) unawaited(_saveCache());
    return result;
  }

  /// バッチ内の各アカウントのアイコン画像を並列で用意する。
  Future<Map<int, PreparedAvatar>> _prepareBatchAvatars(List<InstagramAccountCandidate> batch) async {
    final out = <int, PreparedAvatar>{};
    await Future.wait([
      for (var i = 0; i < batch.length; i++)
        () async {
          final prepared = await _resolveAvatar(batch[i]);
          if (prepared != null) out[i] = prepared;
        }(),
    ]);
    return out;
  }

  Future<PreparedAvatar?> _resolveAvatar(InstagramAccountCandidate c) async {
    final id = c.avatarId;
    if (id.isNotEmpty) {
      final cached = _avatarMemory[id];
      if (cached != null) return cached;
    }

    final inlineB64 = _cleanBase64(c.avatarBase64);
    if (inlineB64 != null) {
      final fmt = _normalizeFormat(c.avatarFormat);
      final prepared = (base64: inlineB64, format: fmt);
      if (id.isNotEmpty) _putAvatarMemory(id, prepared);
      return prepared;
    }

    final url = c.avatarUrl.trim();
    if (url.isEmpty) return null;
    try {
      final prepared = await _avatarPreparer(url, _client);
      if (prepared != null && prepared.base64.isNotEmpty) {
        final clean = _cleanBase64(prepared.base64);
        if (clean != null) {
          final normalized = (base64: clean, format: _normalizeFormat(prepared.format));
          if (id.isNotEmpty) _putAvatarMemory(id, normalized);
          return normalized;
        }
      }
    } catch (_) {}
    return null;
  }

  void _putAvatarMemory(String id, PreparedAvatar avatar) {
    if (_avatarMemory.length >= 200) {
      _avatarMemory.remove(_avatarMemory.keys.first);
    }
    _avatarMemory[id] = avatar;
  }

  static String? _cleanBase64(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    final comma = s.indexOf(',');
    if (s.startsWith('data:') && comma >= 0) {
      s = s.substring(comma + 1);
    }
    s = s.replaceAll(RegExp(r'\s+'), '');
    return s.length >= 32 ? s : null;
  }

  static String _normalizeFormat(String? fmt) {
    final lower = (fmt ?? '').trim().toLowerCase();
    if (lower == 'png' || lower.endsWith('/png')) return 'png';
    return 'jpg';
  }

  /// 設定ダイアログ用の接続テスト。サンプル 2 件（アイコン画像付き女性名・男性名）で Jev の応答・確率・費用を確かめる。
  Future<({bool ok, String message})> testConnection(String candidateKey) async {
    await ensureLoaded();
    final trimmed = candidateKey.trim();
    if (trimmed.isEmpty) {
      return (ok: false, message: 'API キーを入力してください');
    }
    final testIconB64 = base64Encode(makeSolidPng(width: avatarTargetPx, height: avatarTargetPx));
    final sample = [
      InstagramAccountCandidate(
        username: 'hanako_sato_04',
        displayName: '佐藤 花子',
        avatarBase64: testIconB64,
        avatarFormat: 'png',
      ),
      InstagramAccountCandidate(
        username: 'taro_yamada_1998',
        displayName: '山田 太郎',
        avatarBase64: testIconB64,
        avatarFormat: 'png',
      ),
    ];
    final avatars = await _prepareBatchAvatars(sample);
    final beforeCost = _totalCostUsd;
    final probs = await _queryBatch(sample, avatars: avatars, key: trimmed, recordError: true);
    if (probs == null || probs.isEmpty) {
      return (ok: false, message: lastError ?? 'Jev からの応答を取得できませんでした');
    }
    final femaleP = ((probs['hanako_sato_04'] ?? 0) * 100).round();
    final maleAsFemaleP = ((probs['taro_yamada_1998'] ?? 0) * 100).round();
    final deltaUsd = math.max(0.0, _totalCostUsd - beforeCost);
    return (
      ok: true,
      message: 'Jev に接続できました（女性確率: 佐藤花子 $femaleP% / 山田太郎 $maleAsFemaleP% · '
          '今回の通信費 ${formatCostCompact(deltaUsd)}）',
    );
  }

  Future<Map<String, double>?> _queryBatch(
    List<InstagramAccountCandidate> batch, {
    required Map<int, PreparedAvatar> avatars,
    required String key,
    bool recordError = true,
  }) async {
    final nonce = '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}${_nonceCounter++}';
    try {
      final hasImages = avatars.isNotEmpty;
      final res = await _postSystemOne(
        key: key,
        body: buildRequestBody(batch, avatars: avatars, nonce: nonce),
        includeImageHeader: hasImages,
      );

      // 万が一いずれかのアイコン画像が上流で形式エラー(400/415/422)になった場合はテキストのみで再試行する
      if (hasImages && (res.statusCode == 400 || res.statusCode == 415 || res.statusCode == 422)) {
        final fallbackRes = await _postSystemOne(
          key: key,
          body: buildRequestBody(batch, avatars: const {}, nonce: '${nonce}_txt'),
          includeImageHeader: false,
        );
        return _handleResponse(fallbackRes, batch, recordError: recordError);
      }

      return _handleResponse(res, batch, recordError: recordError);
    } catch (e) {
      final msg = 'Jev への通信に失敗しました: $e';
      if (recordError && lastError != msg) {
        lastError = msg;
        notifyListeners();
      }
      return null;
    }
  }

  Future<http.Response> _postSystemOne({
    required String key,
    required Map<String, dynamic> body,
    required bool includeImageHeader,
  }) {
    return _client
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
            if (includeImageHeader) 'TypeSafe-Danger-Zone-Images': 'true',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
  }

  Map<String, double>? _handleResponse(
    http.Response res,
    List<InstagramAccountCandidate> batch, {
    required bool recordError,
  }) {
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
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    _recordUsage(decoded, accountCount: batch.length);
    notifyListeners();
    return parseResponseProbabilities(decoded, batch);
  }

  void _recordUsage(Map<String, dynamic> responseJson, {required int accountCount}) {
    final usage = responseJson['usage'];
    var inputTokens = 0;
    double? explicitUsd;
    if (usage is Map) {
      inputTokens = ((usage['input_tokens'] ?? usage['prompt_tokens'] ?? 0) as num).toInt();
      final rawCost = usage['cost_usd'] ?? usage['total_cost'] ?? usage['cost'];
      if (rawCost is num && rawCost.isFinite && rawCost >= 0) {
        explicitUsd = rawCost.toDouble();
      }
    }
    final costUsd = explicitUsd ?? ((inputTokens / 1e6) * inputUsdPerMTok);
    _totalInputTokens += inputTokens;
    _totalApiCalls += 1;
    _totalJudgedAccounts += accountCount;
    _totalCostUsd += costUsd;

    _sessionInputTokens += inputTokens;
    _sessionApiCalls += 1;
    _sessionCostUsd += costUsd;

    if (!_inMemoryOnly) {
      unawaited(_saveSettings());
    }
  }

  /// TypeSafe System One (`jev-latest`) に送るリクエスト JSON を組み立てる。
  /// [avatars] があるアカウントは `assets` に画像を載せ、各質問 (`q_i`) の `instructions` から 1 回だけ参照する。
  static Map<String, dynamic> buildRequestBody(
    List<InstagramAccountCandidate> batch, {
    Map<int, PreparedAvatar> avatars = const {},
    String nonce = 'jev0',
  }) {
    final hasTikTok = batch.any((c) => c.isTikTok);
    final hasInstagram = batch.any((c) => !c.isTikTok);
    final platformScope = (hasTikTok && hasInstagram)
        ? 'SNS (Instagram / TikTok)'
        : (hasTikTok ? 'TikTok' : 'Instagram');
    final state = StringBuffer()
      ..writeln(
        'Task: Judge whether each numbered $platformScope account is a FEMALE individual\'s personal account '
        'using BOTH its profile icon image (when provided in the question) and its @username + display_name.',
      )
      ..writeln(
        '- True (female personal account): '
        '(1) Profile icon shows a woman/girl or feminine personal portrait/selfie/avatar of a female user, OR '
        '(2) @username or display_name contains a Japanese or foreign female given name in kanji, hiragana, katakana, or romaji '
        '(e.g. 花子, 美咲, 結衣, 葵, 陽菜, 凛, さくら, みゆ, あや, まな, ゆい, りな, もも, なな, まい, えり, かな, みなみ, はるか, まりな, ゆか, ちひろ, あかり, ほのか, '
        'hanako, misaki, yui, aoi, hina, sakura, miyu, aya, mana, rina, momo, nana, mai, eri, kana, minami, haruka, marina, yuka, akari, honoka, etc.) '
        'or female self-identifiers (女子, 女の子, ママ, ちゃん, OL, JD, JK, ♀, she/her, girl, miss), '
        'WITHOUT male face/portrait or business/shop indicators.',
      )
      ..writeln(
        '- False (do NOT show — non-female): '
        'Male personal accounts (male face/portrait icon or male given name / 男子 / パパ / 俺 / 僕 / くん / Mr.), '
        'shops, cafes, salons, restaurants, brands, companies, schools, clubs, event/official/media/bot accounts '
        '(logos, storefronts, flyers, menus, products), '
        'or gender-unknown accounts where neither the profile icon nor the name indicates a female person '
        '(e.g. default grey silhouette, landscape, food, pet, or object icon paired with a gender-neutral handle).',
      )
      ..writeln()
      ..writeln('Accounts:');

    final assets = <String, Map<String, dynamic>>{};
    final questions = <String, Map<String, dynamic>>{};

    for (var i = 0; i < batch.length; i++) {
      final item = batch[i];
      final snsLabel = item.isTikTok ? 'TikTok' : 'Instagram';
      final u = item.username.trim().replaceAll('"', '');
      var d = item.displayName.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll('"', "'");
      if (d.length > 80) d = d.substring(0, 80);
      final displayLabel = d.isEmpty ? '(none)' : d;
      state.writeln('#$i: [$snsLabel] @username="$u" | display_name="$displayLabel"');

      final avatar = avatars[i];
      String iconClause;
      if (avatar != null && avatar.base64.isNotEmpty) {
        final ref = 'jevimg_${nonce}_$i';
        assets[ref] = {
          'type': 'image',
          'format': _normalizeFormat(avatar.format),
          'data_base64': avatar.base64,
        };
        iconClause = 'profile_icon: $ref';
      } else {
        iconClause = 'profile_icon: (unavailable)';
      }

      questions['q_$i'] = {
        'type': 'noul',
        'instructions':
            'Account #$i ($snsLabel @$u, display_name: "$displayLabel"), $iconClause — '
            'Is this a female person\'s personal $snsLabel account?',
        'criteria': {
          'true': 'Personal $snsLabel account of a female individual (from profile icon and/or name)',
          'false': 'Male person, shop/brand/organization/club/bot, or gender-unknown account',
        },
      };
    }

    return {
      'model': modelName,
      'state': state.toString().trimRight(),
      if (assets.isNotEmpty) 'assets': assets,
      'questions': questions,
    };
  }

  /// Jev のレスポンス JSON から `username -> noul(女性アカウント確率 0.0〜1.0)` を取り出す。
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

  /// アイコン URL をダウンロードし、TypeSafe API が受け付ける 320×320 PNG へリサイズ・変換する。
  static Future<PreparedAvatar?> defaultPrepareAvatar(String url, http.Client client) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
    final hostLower = uri.host.toLowerCase();
    final referer = (hostLower.contains('tiktok') || hostLower.contains('musical.ly') || hostLower.contains('byteimg'))
        ? 'https://www.tiktok.com/'
        : ((hostLower.contains('instagram') || hostLower.contains('fbcdn')) ? 'https://www.instagram.com/' : null);
    final res = await client.get(uri, headers: {
      'Accept': 'image/jpeg,image/png,image/webp,image/*,*/*;q=0.8',
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36',
      'Referer': ?referer,
    }).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;

    ui.Codec? codec;
    ui.Image? src;
    ui.Picture? picture;
    ui.Image? outImage;
    try {
      codec = await ui.instantiateImageCodec(res.bodyBytes);
      final frame = await codec.getNextFrame();
      src = frame.image;
      const target = avatarTargetPx;
      final t = target.toDouble();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, t, t),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
      final sw = src.width.toDouble();
      final sh = src.height.toDouble();
      if (sw <= 0 || sh <= 0) return null;
      final scale = math.max(t / sw, t / sh);
      final dw = sw * scale;
      final dh = sh * scale;
      final dx = (t - dw) / 2;
      final dy = (t - dh) / 2;
      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, sw, sh),
        ui.Rect.fromLTWH(dx, dy, dw, dh),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      picture = recorder.endRecording();
      outImage = await picture.toImage(target, target);
      final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final pngBytes = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      return (base64: base64Encode(pngBytes), format: 'png');
    } finally {
      outImage?.dispose();
      picture?.dispose();
      src?.dispose();
      codec?.dispose();
    }
  }

  /// 接続テストや単体テストで使える純粋 Dart 製の単色 PNG（デフォルト 320×320）を生成する。
  static Uint8List makeSolidPng({
    int width = avatarTargetPx,
    int height = avatarTargetPx,
    int r = 245,
    int g = 232,
    int b = 238,
  }) {
    final rowLen = 1 + width * 3;
    final raw = Uint8List(rowLen * height);
    for (var y = 0; y < height; y++) {
      final offset = y * rowLen;
      raw[offset] = 0; // filter type: None
      for (var x = 0; x < width; x++) {
        final px = offset + 1 + x * 3;
        raw[px] = r;
        raw[px + 1] = g;
        raw[px + 2] = b;
      }
    }
    final idatData = Uint8List.fromList(zlib.encode(raw));
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8) // bit depth 8
      ..setUint8(9, 2) // color type 2 (RGB)
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);

    final out = BytesBuilder(copy: false)
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(_pngChunk('IHDR', ihdr.buffer.asUint8List()))
      ..add(_pngChunk('IDAT', idatData))
      ..add(_pngChunk('IEND', const []));
    return out.toBytes();
  }

  static Uint8List _pngChunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final lenBytes = ByteData(4)..setUint32(0, data.length);
    final crcInput = Uint8List(typeBytes.length + data.length)
      ..setRange(0, typeBytes.length, typeBytes)
      ..setRange(typeBytes.length, typeBytes.length + data.length, data);
    final crcBytes = ByteData(4)..setUint32(0, _crc32(crcInput));
    return (BytesBuilder(copy: false)
          ..add(lenBytes.buffer.asUint8List())
          ..add(typeBytes)
          ..add(data)
          ..add(crcBytes.buffer.asUint8List()))
        .toBytes();
  }

  static int _crc32(Uint8List bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
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
            if (value.hasImage) 'img': 1,
          },
      }));
    } catch (_) {
      // キャッシュ保存失敗は動作に影響しない
    }
  }
}
