import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../models/social.dart';

/// 端末内に保存する 1 件分のブラウザ Cookie スナップショット。
class SavedCookie {
  const SavedCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path = '/',
    this.expiresDateMs,
    this.isSecure,
    this.isHttpOnly,
    this.isSessionOnly,
    this.sameSite,
  });

  final String name;
  final String value;
  final String? domain;
  final String path;

  /// 有効期限（Unix エポックミリ秒）。セッション Cookie の場合は `null`。
  final int? expiresDateMs;
  final bool? isSecure;
  final bool? isHttpOnly;
  final bool? isSessionOnly;
  final String? sameSite;

  /// Instagram / TikTok のログインセッション維持に使われる代表的な認証 Cookie か。
  bool get hasAuthHint {
    const authNames = {
      'sessionid',
      'ds_user_id',
      'sid_tt',
      'sessionid_ss',
      'uid_tt',
      'uid_tt_ss',
      'sid_guard',
    };
    return authNames.contains(name.toLowerCase()) && value.isNotEmpty;
  }

  /// Windows WebView2 の `getCookies` は秒単位、Android / `setCookie` はミリ秒単位のためミリ秒へ正規化する。
  static int? normalizeExpiresMs(int? rawExpires, {bool? isSessionOnly}) {
    if (isSessionOnly == true || rawExpires == null || rawExpires <= 0) return null;
    if (rawExpires < 100000000000) {
      return rawExpires * 1000;
    }
    return rawExpires;
  }

  factory SavedCookie.fromInAppCookie(Cookie c) {
    final val = '${c.value ?? ''}';
    final session = c.isSessionOnly == true || (c.expiresDate != null && c.expiresDate! <= 0);
    return SavedCookie(
      name: c.name,
      value: val,
      domain: c.domain,
      path: (c.path == null || c.path!.isEmpty) ? '/' : c.path!,
      expiresDateMs: normalizeExpiresMs(c.expiresDate, isSessionOnly: session),
      isSecure: c.isSecure,
      isHttpOnly: c.isHttpOnly,
      isSessionOnly: session,
      sameSite: c.sameSite?.toNativeValue(),
    );
  }

  Map<String, dynamic> toJson() => {
        'n': name,
        'v': value,
        if (domain != null && domain!.isNotEmpty) 'd': domain,
        'p': path,
        if (expiresDateMs != null) 'e': expiresDateMs,
        if (isSecure != null) 'sec': isSecure,
        if (isHttpOnly != null) 'ho': isHttpOnly,
        if (isSessionOnly != null) 'so': isSessionOnly,
        if (sameSite != null) 'ss': sameSite,
      };

  static SavedCookie? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['n'];
    final value = raw['v'];
    if (name is! String || name.isEmpty || value is! String || value.isEmpty) return null;
    final rawExp = (raw['e'] as num?)?.toInt();
    final session = raw['so'] as bool?;
    return SavedCookie(
      name: name,
      value: value,
      domain: raw['d'] as String?,
      path: (raw['p'] as String?)?.isNotEmpty == true ? raw['p'] as String : '/',
      expiresDateMs: normalizeExpiresMs(rawExp, isSessionOnly: session),
      isSecure: raw['sec'] as bool?,
      isHttpOnly: raw['ho'] as bool?,
      isSessionOnly: session,
      sameSite: raw['ss'] as String?,
    );
  }
}

/// Instagram または TikTok のログインアカウント切り替えスロット（1 アカウント分のセッション）。
class SnsAccountSlot {
  SnsAccountSlot({
    required this.id,
    required this.platform,
    required this.label,
    this.username,
    List<SavedCookie>? cookies,
    Map<String, String>? localStorage,
    DateTime? updatedAt,
  })  : cookies = cookies ?? <SavedCookie>[],
        localStorage = localStorage ?? <String, String>{},
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final SnsPlatform platform;
  String label;

  /// ログイン画面・ナビゲーションから自動検出した `@` なしのユーザー名（任意）。
  String? username;
  List<SavedCookie> cookies;
  Map<String, String> localStorage;
  DateTime updatedAt;

  bool get hasSavedSession => cookies.any((c) => c.hasAuthHint);

  /// ツールバーのコンパクト表示用ラベル。
  String get shortBadge {
    final u = username?.trim() ?? '';
    if (u.isNotEmpty) return '@$u';
    return label;
  }

  /// メニュー・ダイアログでの表示名。
  String get displayTitle {
    final u = username?.trim() ?? '';
    if (u.isEmpty) return label;
    if (label == u || label == '@$u') return '@$u';
    return '$label (@$u)';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform.name,
        'label': label,
        if (username != null && username!.isNotEmpty) 'username': username,
        'cookies': [for (final c in cookies) c.toJson()],
        if (localStorage.isNotEmpty) 'localStorage': localStorage,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static SnsAccountSlot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final pName = raw['platform'];
    final label = raw['label'];
    if (id is! String || id.isEmpty || pName is! String || label is! String) return null;
    final platform = SnsPlatform.values.asNameMap()[pName];
    if (platform == null || (platform != SnsPlatform.instagram && platform != SnsPlatform.tiktok)) return null;
    final rawCookies = raw['cookies'];
    final cookies = <SavedCookie>[
      if (rawCookies is List)
        for (final item in rawCookies) ?SavedCookie.fromJson(item),
    ];
    final rawLs = raw['localStorage'];
    final ls = <String, String>{
      if (rawLs is Map)
        for (final MapEntry(:key, :value) in rawLs.entries)
          if (key is String && value is String) key: value,
    };
    return SnsAccountSlot(
      id: id,
      platform: platform,
      label: label,
      username: (raw['username'] as String?)?.trim(),
      cookies: cookies,
      localStorage: ls,
      updatedAt: DateTime.tryParse((raw['updatedAt'] as String?) ?? '') ?? DateTime.now(),
    );
  }
}

/// 最近開いた／ピン留めした閲覧先アカウント（Instagram / TikTok をワンタップで巡回・再訪する用）。
class RecentSnsTarget {
  const RecentSnsTarget({
    required this.platform,
    required this.username,
    this.label,
    required this.visitedAt,
    this.pinned = false,
  });

  final SnsPlatform platform;
  final String username;
  final String? label;
  final DateTime visitedAt;
  final bool pinned;

  String get handle => '@$username';
  String get url => SocialLink(platform, username).url;

  RecentSnsTarget copyWith({
    String? label,
    DateTime? visitedAt,
    bool? pinned,
  }) =>
      RecentSnsTarget(
        platform: platform,
        username: username,
        label: label ?? this.label,
        visitedAt: visitedAt ?? this.visitedAt,
        pinned: pinned ?? this.pinned,
      );

  Map<String, dynamic> toJson() => {
        'p': platform.name,
        'u': username,
        if (label != null && label!.isNotEmpty) 'l': label,
        't': visitedAt.millisecondsSinceEpoch ~/ 1000,
        if (pinned) 'pin': true,
      };

  static RecentSnsTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pName = raw['p'];
    final username = raw['u'];
    if (pName is! String || username is! String || username.trim().isEmpty) return null;
    final platform = SnsPlatform.values.asNameMap()[pName];
    if (platform == null || (platform != SnsPlatform.instagram && platform != SnsPlatform.tiktok)) return null;
    final sec = (raw['t'] as num?)?.toInt() ?? 0;
    return RecentSnsTarget(
      platform: platform,
      username: username.trim().replaceFirst(RegExp(r'^@'), ''),
      label: raw['l'] as String?,
      visitedAt: sec > 0 ? DateTime.fromMillisecondsSinceEpoch(sec * 1000) : DateTime.now(),
      pinned: raw['pin'] == true,
    );
  }
}

/// WebView の Cookie ストア操作インターフェース（単体テストで差し替え可能にする）。
abstract class BrowserCookieStore {
  Future<List<SavedCookie>> getCookiesForPlatform(SnsPlatform platform);
  Future<void> clearCookiesForPlatform(SnsPlatform platform);
  Future<void> applyCookiesForPlatform(SnsPlatform platform, List<SavedCookie> cookies);
}

/// `flutter_inappwebview` の [CookieManager] を用いた実装。
/// Windows の空 Cookie 時 `deleteCookies` ハングや `expiresDate` 秒/ミリ秒差を吸収し、
/// 対象 SNS ドメインのみの Cookie を高速に入れ替える。
class WebViewCookieStore implements BrowserCookieStore {
  WebViewCookieStore({WebViewEnvironment? environment}) : _environment = environment;

  final WebViewEnvironment? _environment;

  CookieManager get _manager => CookieManager.instance(webViewEnvironment: _environment);

  static List<String> originsOf(SnsPlatform platform) => switch (platform) {
        SnsPlatform.instagram => const [
            'https://www.instagram.com/',
            'https://i.instagram.com/',
          ],
        SnsPlatform.tiktok => const [
            'https://www.tiktok.com/',
            'https://m.tiktok.com/',
          ],
        _ => const [],
      };

  static String rootDomainOf(SnsPlatform platform) => switch (platform) {
        SnsPlatform.instagram => 'instagram.com',
        SnsPlatform.tiktok => 'tiktok.com',
        _ => '',
      };

  static bool matchesPlatformDomain(SnsPlatform platform, String? cookieDomain) {
    final root = rootDomainOf(platform);
    if (root.isEmpty) return false;
    if (cookieDomain == null || cookieDomain.isEmpty) return true;
    final clean = cookieDomain.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
    return clean == root || clean.endsWith('.$root');
  }

  @override
  Future<List<SavedCookie>> getCookiesForPlatform(SnsPlatform platform) async {
    final seen = <String, SavedCookie>{};
    for (final origin in originsOf(platform)) {
      try {
        final list = await _manager.getCookies(url: WebUri(origin));
        for (final c in list) {
          final saved = SavedCookie.fromInAppCookie(c);
          if (saved.name.isEmpty || saved.value.isEmpty) continue;
          if (!matchesPlatformDomain(platform, saved.domain)) continue;
          final key = '${saved.domain ?? ''}|${saved.path}|${saved.name}';
          seen[key] = saved;
        }
      } catch (e) {
        debugPrint('${platform.label} Cookie の取得に失敗: $e');
      }
    }
    return seen.values.toList();
  }

  @override
  Future<void> clearCookiesForPlatform(SnsPlatform platform) async {
    final current = await getCookiesForPlatform(platform);
    if (current.isEmpty) return;
    final fallbackHost = platform == SnsPlatform.tiktok ? 'www.tiktok.com' : 'www.instagram.com';
    await Future.wait([
      for (final c in current)
        () async {
          final host = (c.domain ?? '').replaceFirst(RegExp(r'^\.+'), '');
          final targetHost = host.isNotEmpty ? host : fallbackHost;
          final path = c.path.startsWith('/') ? c.path : '/${c.path}';
          final uri = WebUri('https://$targetHost$path');
          try {
            await _manager.deleteCookie(
              url: uri,
              name: c.name,
              domain: c.domain,
              path: path,
            );
          } catch (_) {}
          try {
            await _manager.deleteCookie(
              url: uri,
              name: c.name,
              path: path,
            );
          } catch (_) {}
        }(),
    ]);
  }

  @override
  Future<void> applyCookiesForPlatform(SnsPlatform platform, List<SavedCookie> cookies) async {
    if (cookies.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final fallbackHost = platform == SnsPlatform.tiktok ? 'www.tiktok.com' : 'www.instagram.com';
    await Future.wait([
      for (final c in cookies)
        if (c.name.isNotEmpty && c.value.isNotEmpty && matchesPlatformDomain(platform, c.domain))
          () async {
            if (c.expiresDateMs != null && c.expiresDateMs! <= nowMs) return;
            final isHostPrefix = c.name.startsWith('__Host-');
            final rawDom = c.domain?.trim() ?? '';
            final host = rawDom.replaceFirst(RegExp(r'^\.+'), '');
            final targetHost = host.isNotEmpty ? host : fallbackHost;
            final path = isHostPrefix ? '/' : (c.path.startsWith('/') ? c.path : '/${c.path}');
            // ドット始まりドメイン (.instagram.com / .tiktok.com) のみ domain 属性を付与し、ホスト限定 Cookie はそのまま再現する
            final effectiveDomain = (!isHostPrefix && rawDom.startsWith('.')) ? rawDom : null;
            try {
              await _manager.setCookie(
                url: WebUri('https://$targetHost$path'),
                name: c.name,
                value: c.value,
                domain: effectiveDomain,
                path: path,
                expiresDate: c.isSessionOnly == true ? null : c.expiresDateMs,
                isSecure: isHostPrefix ? true : c.isSecure,
                isHttpOnly: c.isHttpOnly,
                sameSite: c.sameSite != null ? HTTPCookieSameSitePolicy.fromNativeValue(c.sameSite) : null,
              );
            } catch (e) {
              debugPrint('${platform.label} Cookie(${c.name}) の復元に失敗: $e');
            }
          }(),
    ]);
  }
}

/// WebView 内の `localStorage` / `sessionStorage` を読み書きするコールバック群。
typedef WebStorageCallbacks = ({
  Future<Map<String, String>> Function() readLocalStorage,
  Future<void> Function(Map<String, String> nextLocalStorage) replaceStorage,
});

/// Instagram・TikTok の複数ログインアカウント切り替えと、最近開いた閲覧先アカウントの高速切り替えを管理するサービス。
///
/// パスワードは一切扱わず、各 SNS 公式ログイン画面でログインしたセッション（Cookie・localStorage）を
/// 端末内の `sns_accounts_v1.json` にスロット単位で保持し、ワンタップで即時入れ替えできるようにする。
class SnsAccountSwitcher extends ChangeNotifier {
  SnsAccountSwitcher({
    BrowserCookieStore? cookieStore,
    File? storageFile,
    bool inMemoryOnly = false,
  })  : _cookieStore = cookieStore,
        _storageFile = storageFile,
        _inMemoryOnly = inMemoryOnly,
        _loaded = inMemoryOnly {
    _ensureDefaultSlots();
  }

  static const supportedPlatforms = [SnsPlatform.instagram, SnsPlatform.tiktok];
  static const maxRecentTargetsPerPlatform = 30;
  static const _maxLocalStorageEntries = 60;
  static const _maxLocalStorageValueLen = 8192;

  BrowserCookieStore? _cookieStore;
  File? _storageFile;
  final bool _inMemoryOnly;
  bool _loaded;
  Future<void>? _loading;
  int _idSeq = 1;

  final Map<SnsPlatform, List<SnsAccountSlot>> _slots = {
    SnsPlatform.instagram: <SnsAccountSlot>[],
    SnsPlatform.tiktok: <SnsAccountSlot>[],
  };

  final Map<SnsPlatform, String> _activeSlotIds = {};

  final Map<SnsPlatform, List<RecentSnsTarget>> _recentTargets = {
    SnsPlatform.instagram: <RecentSnsTarget>[],
    SnsPlatform.tiktok: <RecentSnsTarget>[],
  };

  bool _switching = false;
  bool get switching => _switching;

  void attachCookieStore(BrowserCookieStore store) {
    _cookieStore ??= store;
  }

  static bool supportsLoginSlots(SnsPlatform? platform) =>
      platform == SnsPlatform.instagram || platform == SnsPlatform.tiktok;

  static String loginUrlOf(SnsPlatform platform) => switch (platform) {
        SnsPlatform.tiktok => 'https://www.tiktok.com/login',
        _ => 'https://www.instagram.com/accounts/login/',
      };

  static String homeUrlOf(SnsPlatform platform) => switch (platform) {
        SnsPlatform.tiktok => 'https://www.tiktok.com/',
        _ => 'https://www.instagram.com/',
      };

  void _ensureDefaultSlots() {
    for (final p in supportedPlatforms) {
      final list = _slots.putIfAbsent(p, () => <SnsAccountSlot>[]);
      if (list.isEmpty) {
        final slot = SnsAccountSlot(
          id: '${p.name}_1',
          platform: p,
          label: 'アカウント 1',
        );
        list.add(slot);
        _activeSlotIds[p] = slot.id;
      } else if (_activeSlotIds[p] == null || !list.any((s) => s.id == _activeSlotIds[p])) {
        _activeSlotIds[p] = list.first.id;
      }
    }
  }

  List<SnsAccountSlot> slotsOf(SnsPlatform platform) =>
      List.unmodifiable(_slots[platform] ?? const <SnsAccountSlot>[]);

  SnsAccountSlot activeSlotOf(SnsPlatform platform) {
    _ensureDefaultSlots();
    final list = _slots[platform]!;
    final activeId = _activeSlotIds[platform];
    return list.firstWhere((s) => s.id == activeId, orElse: () => list.first);
  }

  int activeSlotIndexOf(SnsPlatform platform) {
    final list = _slots[platform] ?? const <SnsAccountSlot>[];
    final activeId = _activeSlotIds[platform];
    final idx = list.indexWhere((s) => s.id == activeId);
    return idx >= 0 ? idx : 0;
  }

  List<RecentSnsTarget> recentTargetsOf(SnsPlatform platform) {
    final list = _recentTargets[platform] ?? const <RecentSnsTarget>[];
    return List.unmodifiable(list);
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      if (_storageFile == null) {
        final dir = await getApplicationSupportDirectory();
        _storageFile = File('${dir.path}${Platform.pathSeparator}sns_accounts_v1.json');
      }
      if (await _storageFile!.exists()) {
        final decoded = jsonDecode(await _storageFile!.readAsString());
        if (decoded is Map<String, dynamic>) {
          final rawSlots = decoded['slots'];
          if (rawSlots is Map) {
            for (final p in supportedPlatforms) {
              final items = rawSlots[p.name];
              if (items is List) {
                final parsed = [for (final x in items) ?SnsAccountSlot.fromJson(x)];
                if (parsed.isNotEmpty) {
                  _slots[p] = parsed;
                }
              }
            }
          }
          final rawActive = decoded['activeSlotIds'];
          if (rawActive is Map) {
            for (final p in supportedPlatforms) {
              final id = rawActive[p.name];
              if (id is String && (_slots[p]?.any((s) => s.id == id) ?? false)) {
                _activeSlotIds[p] = id;
              }
            }
          }
          final rawTargets = decoded['recentTargets'];
          if (rawTargets is Map) {
            for (final p in supportedPlatforms) {
              final items = rawTargets[p.name];
              if (items is List) {
                _recentTargets[p] = [for (final x in items) ?RecentSnsTarget.fromJson(x)];
              }
            }
          }
        }
      }
    } on MissingPluginException {
      // テスト環境ではメモリ内のみで動作
    } catch (e) {
      debugPrint('SNS アカウント切替データの読み込みに失敗: $e');
    } finally {
      _ensureDefaultSlots();
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    if (_inMemoryOnly) return;
    final file = _storageFile;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'slots': {
          for (final p in supportedPlatforms) p.name: [for (final s in _slots[p]!) s.toJson()],
        },
        'activeSlotIds': {
          for (final p in supportedPlatforms)
            if (_activeSlotIds[p] != null) p.name: _activeSlotIds[p],
        },
        'recentTargets': {
          for (final p in supportedPlatforms) p.name: [for (final t in _recentTargets[p]!) t.toJson()],
        },
      }));
    } catch (e) {
      debugPrint('SNS アカウント切替データの保存に失敗: $e');
    }
  }

  static Map<String, String> _sanitizeLocalStorage(Map<String, String> raw) {
    final out = <String, String>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      if (out.length >= _maxLocalStorageEntries) break;
      if (key.isEmpty || value.length > _maxLocalStorageValueLen) continue;
      out[key] = value;
    }
    return out;
  }

  /// 現在アクティブなスロットへ最新の Cookie・localStorage を保存する。
  Future<void> captureActiveSlot(
    SnsPlatform platform, {
    WebStorageCallbacks? storage,
  }) async {
    if (!supportsLoginSlots(platform)) return;
    await ensureLoaded();
    final store = _cookieStore;
    if (store == null) return;
    final slot = activeSlotOf(platform);
    final cookies = await store.getCookiesForPlatform(platform);
    if (cookies.isNotEmpty || slot.cookies.isEmpty) {
      slot.cookies = cookies;
    }
    if (storage != null) {
      try {
        final ls = await storage.readLocalStorage();
        if (ls.isNotEmpty || slot.localStorage.isEmpty) {
          slot.localStorage = _sanitizeLocalStorage(ls);
        }
      } catch (_) {}
    }
    slot.updatedAt = DateTime.now();
    await _save();
  }

  /// WebView 上で検出されたログイン中 `@username` を現在のスロットに記録する。
  Future<void> updateDetectedViewer(SnsPlatform platform, String rawUsername) async {
    if (!supportsLoginSlots(platform)) return;
    final clean = rawUsername.trim().replaceFirst(RegExp(r'^@+'), '');
    if (clean.isEmpty || clean.length > 32) return;
    await ensureLoaded();
    final slot = activeSlotOf(platform);
    if (slot.username == clean) return;
    slot.username = clean;
    slot.updatedAt = DateTime.now();
    notifyListeners();
    await _save();
  }

  /// 指定スロットへログインセッション（Cookie + localStorage）を即時切り替える。
  /// 切り替え後に開くべき推奨 URL（ログイン済みなら `null`＝現在ページ再読込、未ログインならログイン画面）を返す。
  Future<String?> switchToSlot(
    SnsPlatform platform,
    String targetSlotId, {
    WebStorageCallbacks? storage,
  }) async {
    if (!supportsLoginSlots(platform)) return null;
    await ensureLoaded();
    final list = _slots[platform]!;
    final targetIndex = list.indexWhere((s) => s.id == targetSlotId);
    if (targetIndex < 0) return null;
    final current = activeSlotOf(platform);
    if (current.id == targetSlotId) {
      return current.hasSavedSession ? null : loginUrlOf(platform);
    }

    _switching = true;
    notifyListeners();
    try {
      final store = _cookieStore;
      if (store != null) {
        await captureActiveSlot(platform, storage: storage);
        await store.clearCookiesForPlatform(platform);
      }
      final next = list[targetIndex];
      _activeSlotIds[platform] = next.id;
      if (store != null && next.cookies.isNotEmpty) {
        await store.applyCookiesForPlatform(platform, next.cookies);
      }
      if (storage != null) {
        try {
          await storage.replaceStorage(next.localStorage);
        } catch (_) {}
      }
      next.updatedAt = DateTime.now();
      await _save();
      return next.hasSavedSession ? null : loginUrlOf(platform);
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// 次のログインスロットへ順送り（ワンタップ高速ローテーション）する。
  Future<String?> cycleNextSlot(
    SnsPlatform platform, {
    WebStorageCallbacks? storage,
  }) async {
    await ensureLoaded();
    final list = slotsOf(platform);
    if (list.length <= 1) return null;
    final nextIdx = (activeSlotIndexOf(platform) + 1) % list.length;
    return switchToSlot(platform, list[nextIdx].id, storage: storage);
  }

  /// 新しいログインアカウント用スロットを追加して切り替え、ログインページの URL を返す。
  Future<({SnsAccountSlot slot, String loginUrl})> addNewAccountSlot(
    SnsPlatform platform, {
    String? customLabel,
    WebStorageCallbacks? storage,
  }) async {
    await ensureLoaded();
    final list = _slots[platform]!;
    final nextNumber = list.length + 1;
    final label = (customLabel != null && customLabel.trim().isNotEmpty)
        ? customLabel.trim()
        : 'アカウント $nextNumber';
    final newId = '${platform.name}_${DateTime.now().millisecondsSinceEpoch}_${_idSeq++}';

    _switching = true;
    notifyListeners();
    try {
      final store = _cookieStore;
      if (store != null) {
        await captureActiveSlot(platform, storage: storage);
        await store.clearCookiesForPlatform(platform);
      }
      if (storage != null) {
        try {
          await storage.replaceStorage(const {});
        } catch (_) {}
      }
      final newSlot = SnsAccountSlot(
        id: newId,
        platform: platform,
        label: label,
      );
      list.add(newSlot);
      _activeSlotIds[platform] = newSlot.id;
      await _save();
      return (slot: newSlot, loginUrl: loginUrlOf(platform));
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  Future<void> renameSlot(SnsPlatform platform, String slotId, String nextLabel) async {
    final trimmed = nextLabel.trim();
    if (trimmed.isEmpty) return;
    await ensureLoaded();
    final list = _slots[platform];
    if (list == null) return;
    for (final s in list) {
      if (s.id == slotId) {
        s.label = trimmed;
        notifyListeners();
        await _save();
        return;
      }
    }
  }

  /// スロットを削除する。最後の 1 件を削除した場合は空の「アカウント 1」に初期化する。
  Future<void> deleteSlot(
    SnsPlatform platform,
    String slotId, {
    WebStorageCallbacks? storage,
  }) async {
    if (!supportsLoginSlots(platform)) return;
    await ensureLoaded();
    final list = _slots[platform]!;
    final wasActive = _activeSlotIds[platform] == slotId;
    list.removeWhere((s) => s.id == slotId);
    if (list.isEmpty) {
      final fresh = SnsAccountSlot(
        id: '${platform.name}_1',
        platform: platform,
        label: 'アカウント 1',
      );
      list.add(fresh);
      _activeSlotIds[platform] = fresh.id;
      await _cookieStore?.clearCookiesForPlatform(platform);
      if (storage != null) {
        try {
          await storage.replaceStorage(const {});
        } catch (_) {}
      }
    } else if (wasActive) {
      final fallback = list.first;
      _activeSlotIds[platform] = fallback.id;
      final store = _cookieStore;
      if (store != null) {
        await store.clearCookiesForPlatform(platform);
        if (fallback.cookies.isNotEmpty) {
          await store.applyCookiesForPlatform(platform, fallback.cookies);
        }
      }
      if (storage != null) {
        try {
          await storage.replaceStorage(fallback.localStorage);
        } catch (_) {}
      }
    }
    notifyListeners();
    await _save();
  }

  /// 全てのログインスロットの保存済みセッションを消去する（「ログイン情報を消去」メニュー用）。
  Future<void> clearAllSavedSessions() async {
    await ensureLoaded();
    for (final p in supportedPlatforms) {
      _slots[p] = [
        SnsAccountSlot(id: '${p.name}_1', platform: p, label: 'アカウント 1'),
      ];
      _activeSlotIds[p] = '${p.name}_1';
    }
    notifyListeners();
    await _save();
  }

  /// 閲覧した相手アカウント（プロフィール）を履歴に記録する（ピン留めを先頭に保ち、新しい順へ並べる）。
  Future<void> recordVisitedTarget(
    SnsPlatform platform,
    String rawUsername, {
    String? label,
  }) async {
    if (!supportsLoginSlots(platform)) return;
    final clean = rawUsername.trim().replaceFirst(RegExp(r'^@+'), '');
    if (clean.isEmpty) return;
    final link = parseSnsTag(platform, clean).firstOrNull;
    final canonical = link?.username ?? clean;
    if (canonical.isEmpty) return;

    await ensureLoaded();
    final list = _recentTargets.putIfAbsent(platform, () => <RecentSnsTarget>[]);
    final existingIdx = list.indexWhere((t) => t.username.toLowerCase() == canonical.toLowerCase());
    final prev = existingIdx >= 0 ? list.removeAt(existingIdx) : null;
    final mergedLabel = (label != null && label.trim().isNotEmpty) ? label.trim() : prev?.label;
    final updated = RecentSnsTarget(
      platform: platform,
      username: canonical,
      label: mergedLabel,
      visitedAt: DateTime.now(),
      pinned: prev?.pinned ?? false,
    );

    if (updated.pinned) {
      list.insert(0, updated);
    } else {
      final firstUnpinned = list.indexWhere((t) => !t.pinned);
      if (firstUnpinned < 0) {
        list.add(updated);
      } else {
        list.insert(firstUnpinned, updated);
      }
    }

    if (list.length > maxRecentTargetsPerPlatform) {
      // ピン留めされていない古い項目から削る
      while (list.length > maxRecentTargetsPerPlatform) {
        final idx = list.lastIndexWhere((t) => !t.pinned);
        if (idx >= 0) {
          list.removeAt(idx);
        } else {
          list.removeLast();
        }
      }
    }
    notifyListeners();
    unawaited(_save());
  }

  Future<void> togglePinTarget(SnsPlatform platform, String username) async {
    await ensureLoaded();
    final list = _recentTargets[platform];
    if (list == null) return;
    final idx = list.indexWhere((t) => t.username.toLowerCase() == username.toLowerCase());
    if (idx < 0) return;
    final toggled = list[idx].copyWith(pinned: !list[idx].pinned);
    list.removeAt(idx);
    if (toggled.pinned) {
      list.insert(0, toggled);
    } else {
      final firstUnpinned = list.indexWhere((t) => !t.pinned);
      if (firstUnpinned < 0) {
        list.add(toggled);
      } else {
        list.insert(firstUnpinned, toggled);
      }
    }
    notifyListeners();
    await _save();
  }

  Future<void> clearRecentTargets(SnsPlatform platform, {bool keepPinned = true}) async {
    await ensureLoaded();
    final list = _recentTargets[platform];
    if (list == null) return;
    if (keepPinned) {
      list.removeWhere((t) => !t.pinned);
    } else {
      list.clear();
    }
    notifyListeners();
    await _save();
  }
}
