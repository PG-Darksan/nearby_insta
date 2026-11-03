import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/social.dart';
import '../services/jev_service.dart';
import '../services/sns_account_switcher.dart';
import '../widgets/place_widgets.dart';

/// アカウント検索で、検索欄に自動で入力できたか。
enum InstagramSearchStatus { none, waitingForLogin, searching, failed }

/// SNS ブラウザ内で保持する WebView ペインの種別。
/// Instagram と TikTok を別々の WebView として同時に保持し、再読み込みなし（0秒）で切り替えられるようにする。
enum SnsPaneKind { instagram, tiktok, other }

/// 地図上のスポットなどから渡される、高速切り替え対象の SNS アカウント候補。
typedef NearbySnsTarget = ({SocialLink link, String placeName});

class _PaneState {
  _PaneState(this.kind);

  final SnsPaneKind kind;
  InAppWebViewController? web;
  String? pendingUrl;
  bool started = false;

  String? url;
  String? title;
  double progress = 1;
  bool canGoBack = false;
  bool canGoForward = false;

  String? pendingSearch;
  int searchId = 0;
  int runningSearchId = 0;
  String? searchQuery;
  InstagramSearchStatus searchStatus = InstagramSearchStatus.none;

  bool inFollowList = false;
  int visibleFemaleCount = 0;
  int hiddenAccountCount = 0;
  bool autoFetchingMore = false;
}

/// アプリ内の SNS ブラウザの状態。地図や一覧からアカウントを開くときにも使う。
///
/// - Instagram と TikTok の WebView を並列保持し、ワンタップで再読み込みなしに高速切り替えできる。
/// - [SnsAccountSwitcher] により、自分の複数の Instagram / TikTok ログインアカウント（セッション）も
///   パスワードをアプリに保存せずワンタップで切り替えられる。
/// - Instagram と TikTok の両方で「フォロー中」「フォロワー」一覧を開いた際、Jev で女性個人アカウントのみを抽出できる。
class SnsBrowserController extends ChangeNotifier {
  SnsBrowserController({
    JevService? jev,
    SnsAccountSwitcher? accounts,
  })  : _ownsJev = jev == null,
        _ownsAccounts = accounts == null,
        jev = jev ?? JevService(),
        accounts = accounts ?? SnsAccountSwitcher() {
    this.jev.addListener(_onJevChanged);
    this.accounts.addListener(_onAccountsChanged);
    if (supported) {
      this.accounts.attachCookieStore(WebViewCookieStore(environment: _environment));
    }
    unawaited(this.jev.ensureLoaded());
    unawaited(this.accounts.ensureLoaded());
  }

  static const homeUrl = 'https://www.instagram.com/';

  /// Instagram のアカウント検索の画面。ログインしていなければ、ログインした後にこの画面に戻る。
  static const searchUrl = 'https://www.instagram.com/explore/search/';

  static const tiktokHomeUrl = 'https://www.tiktok.com/';

  /// TikTok のユーザー検索画面（自動再生動画フィードを避けて軽量にウォームアップ・検索できる）。
  static const tiktokSearchUrl = 'https://www.tiktok.com/search/user';

  /// Windows の WebView2 環境。ログイン状態の保存先をアプリのデータフォルダーにする。
  static WebViewEnvironment? _environment;
  static bool _prepared = false;

  /// アプリの起動時に一度だけ呼ぶ。
  static Future<void> prepare() async {
    if (_prepared) return;
    _prepared = true;
    if (!Platform.isWindows) return;
    try {
      if (await WebViewEnvironment.getAvailableVersion() == null) return; // WebView2 ランタイムがない
      final dir = await getApplicationSupportDirectory();
      _environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: '${dir.path}${Platform.pathSeparator}webview'),
      );
    } catch (e) {
      debugPrint('WebView2 を準備できませんでした: $e');
    }
  }

  /// この端末でアプリ内ブラウザを使えるか（使えなければ外部のブラウザで開く）。
  static bool get supported => Platform.isAndroid || (Platform.isWindows && _environment != null);

  final bool _ownsJev;
  final bool _ownsAccounts;
  final JevService jev;
  final SnsAccountSwitcher accounts;

  final Map<SnsPaneKind, _PaneState> _panes = {
    SnsPaneKind.instagram: _PaneState(SnsPaneKind.instagram),
    SnsPaneKind.tiktok: _PaneState(SnsPaneKind.tiktok),
    SnsPaneKind.other: _PaneState(SnsPaneKind.other),
  };

  SnsPaneKind _activePane = SnsPaneKind.instagram;
  SnsPaneKind get activePane => _activePane;

  _PaneState get _current => _panes[_activePane]!;
  _PaneState _pane(SnsPaneKind kind) => _panes[kind]!;

  bool isPaneStarted(SnsPaneKind kind) => _pane(kind).started;
  String? paneInitialUrl(SnsPaneKind kind) {
    final p = _pane(kind);
    return p.pendingUrl ??
        p.url ??
        switch (kind) {
          SnsPaneKind.instagram => homeUrl,
          SnsPaneKind.tiktok => tiktokHomeUrl,
          SnsPaneKind.other => homeUrl,
        };
  }

  int _activeJevRequests = 0;
  double _lastAppliedThreshold = JevService.defaultThreshold;

  bool get checkingAccounts => _activeJevRequests > 0;

  /// 最後にアクティブなペインで検索した言葉と、検索欄に入力できたか（画面上部の案内に使う）。
  String? get searchQuery => _current.searchQuery;
  InstagramSearchStatus get searchStatus => _current.searchStatus;

  /// 現在表示中の SNS（Instagram / TikTok）でフォロー中・フォロワー一覧を開いているかと件数。
  bool get inFollowList => _current.inFollowList;
  int get visibleFemaleCount => _current.visibleFemaleCount;
  int get hiddenAccountCount => _current.hiddenAccountCount;
  bool get autoFetchingMore => _current.autoFetchingMore;

  String? get url => _current.url;
  String? get title => _current.title;
  double get progress => _current.progress;
  bool get canGoBack => _current.canGoBack;
  bool get canGoForward => _current.canGoForward;

  /// いずれかのペインが一度でも起動したか。
  bool get started => _panes.values.any((p) => p.started);

  /// 現在アクティブなペインに対応する主要 SNS プラットフォーム。
  SnsPlatform get activePlatform => switch (_activePane) {
        SnsPaneKind.instagram => SnsPlatform.instagram,
        SnsPaneKind.tiktok => SnsPlatform.tiktok,
        SnsPaneKind.other => SnsBrowser.platformOf(_current.url) ?? SnsPlatform.x,
      };

  /// 現在開いているページがプロフィールページならその `@username`（`@` なし）。
  String? get currentTargetUsername {
    final raw = url;
    if (raw == null || raw.isEmpty) return null;
    final link = parseSnsUrl(raw);
    return link?.username;
  }

  @override
  void dispose() {
    jev.removeListener(_onJevChanged);
    accounts.removeListener(_onAccountsChanged);
    if (_ownsJev) jev.dispose();
    if (_ownsAccounts) accounts.dispose();
    super.dispose();
  }

  void _onAccountsChanged() {
    notifyListeners();
  }

  void _onJevChanged() {
    final thresholdChanged = (_lastAppliedThreshold - jev.threshold).abs() > 0.0001;
    _lastAppliedThreshold = jev.threshold;
    unawaited(_syncFemaleFilterToAllPanes(resetJudged: thresholdChanged));
    notifyListeners();
  }

  Future<void> setOnlyFemaleAccounts(bool enabled) async {
    await jev.updateSettings(onlyFemaleAccounts: enabled);
  }

  Future<void> _syncFemaleFilterToAllPanes({bool resetJudged = false}) async {
    await Future.wait([
      _syncFemaleFilterToPane(_pane(SnsPaneKind.instagram), resetJudged: resetJudged),
      _syncFemaleFilterToPane(_pane(SnsPaneKind.tiktok), resetJudged: resetJudged),
      _syncFemaleFilterToPane(_pane(SnsPaneKind.other), resetJudged: resetJudged),
    ]);
  }

  Future<void> _syncFemaleFilterToPane(_PaneState pane, {bool resetJudged = false}) async {
    final web = pane.web;
    if (web == null) return;
    final current = Uri.tryParse(pane.url ?? '');
    if (!_isJevSupportedHost(current)) return;
    try {
      await web.evaluateJavascript(
        source: '''
        $followerFilterScript
        if (window.__nearbySetFemaleFilter) {
          window.__nearbySetFemaleFilter(${jev.isActive}, $resetJudged);
        }
        ''',
      );
    } catch (_) {}
  }

  /// 初回の Instagram / TikTok アカウント検索や切り替えでも待たずに表示できるよう、裏で検索画面を読み込んでおく。
  void warmUp({bool includeTikTok = true}) {
    if (!supported) return;
    var changed = false;
    final ig = _pane(SnsPaneKind.instagram);
    if (!ig.started) {
      ig.started = true;
      ig.pendingUrl = searchUrl;
      changed = true;
    }
    if (includeTikTok) {
      final tt = _pane(SnsPaneKind.tiktok);
      if (!tt.started) {
        tt.started = true;
        tt.pendingUrl = tiktokSearchUrl;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  static SnsPaneKind _paneKindForUrl(String target) {
    final uri = Uri.tryParse(target);
    if (_isInstagramHost(uri)) return SnsPaneKind.instagram;
    if (_isTikTokHost(uri)) return SnsPaneKind.tiktok;
    return SnsPaneKind.other;
  }

  static SnsPaneKind _paneKindForPlatform(SnsPlatform platform) => switch (platform) {
        SnsPlatform.instagram => SnsPaneKind.instagram,
        SnsPlatform.tiktok => SnsPaneKind.tiktok,
        _ => SnsPaneKind.other,
      };

  void _setActivePane(SnsPaneKind next) {
    if (_activePane == next) return;
    final prevPane = _pane(_activePane);
    // TikTok など裏に回るペインの再生中動画・音声を即座に一時停止する
    final prevWeb = prevPane.web;
    if (prevWeb != null) {
      prevWeb
          .evaluateJavascript(
            source: "document.querySelectorAll('video,audio').forEach(function(m){try{m.pause();}catch(_){}});",
          )
          .ignore();
    }
    _activePane = next;
  }

  /// Instagram ⇄ TikTok（および他 SNS）をワンタップで高速切り替えする。
  /// すでに開いている Instagram / TikTok ペインがあれば再読み込みせず 0 秒で表示を切り替える。
  void switchPlatform(SnsPlatform platform) {
    final nextKind = _paneKindForPlatform(platform);
    final pane = _pane(nextKind);
    _setActivePane(nextKind);
    if (nextKind == SnsPaneKind.other) {
      final home = SnsBrowser.homeUrlOf(platform);
      final curPlatform = SnsBrowser.platformOf(pane.url);
      if (!pane.started || curPlatform != platform) {
        _loadInPane(pane, home);
        return;
      }
    } else if (!pane.started) {
      _loadInPane(pane, platform == SnsPlatform.tiktok ? tiktokHomeUrl : homeUrl);
      return;
    } else if (pane.url == null && pane.pendingUrl != null) {
      pane.url = pane.pendingUrl;
    }
    notifyListeners();
  }

  /// [target] を開く。Instagram / TikTok のプロフィール間移動なら可能な限り SPA 内部遷移で高速に切り替える。
  void open(String target, {String? label}) {
    final kind = _paneKindForUrl(target);
    final pane = _pane(kind);
    _setActivePane(kind);
    pane.pendingSearch = null;
    pane.searchId++;
    pane.searchStatus = InstagramSearchStatus.none;

    final parsedLink = parseSnsUrl(target);
    if (parsedLink != null && parsedLink.username != null) {
      unawaited(accounts.recordVisitedTarget(parsedLink.platform, parsedLink.username!, label: label));
    }

    _navigateFastOrLoad(pane, target);
  }

  /// すでに同じ SNS ドメインが開いている場合、SPA ルーターのリンク遷移で JS バンドル再読込を省いて高速移動する。
  void _navigateFastOrLoad(_PaneState pane, String target) {
    final targetUri = Uri.tryParse(target);
    final currentUri = Uri.tryParse(pane.url ?? '');
    final web = pane.web;
    final sameSpaOrigin = web != null &&
        targetUri != null &&
        currentUri != null &&
        ((_isInstagramHost(targetUri) && _isInstagramHost(currentUri) && !_isInstagramLoginPath(currentUri)) ||
            (_isTikTokHost(targetUri) && _isTikTokHost(currentUri) && !_isTikTokLoginPath(currentUri)));

    pane.started = true;
    pane.url = target;
    if (sameSpaOrigin) {
      final pathWithQuery = targetUri.hasQuery ? '${targetUri.path}?${targetUri.query}' : targetUri.path;
      notifyListeners();
      unawaited(
        web
            .callAsyncJavaScript(
              functionBody: _fastSpaNavigateScript,
              arguments: {'targetPath': pathWithQuery, 'fullUrl': target},
            )
            .catchError((_) {
          web.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
          return null;
        }),
      );
      return;
    }
    _loadInPane(pane, target);
  }

  void _loadInPane(_PaneState pane, String target) {
    pane.started = true;
    pane.url = target;
    if (pane.web case final web?) {
      web.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } else {
      pane.pendingUrl = target;
    }
    notifyListeners();
  }

  static bool _isInstagramHost(Uri? uri) =>
      uri != null && (uri.host == 'instagram.com' || uri.host.endsWith('.instagram.com'));

  static bool _isTikTokHost(Uri? uri) =>
      uri != null && (uri.host == 'tiktok.com' || uri.host.endsWith('.tiktok.com'));

  static bool _isJevSupportedHost(Uri? uri) => _isInstagramHost(uri) || _isTikTokHost(uri);

  static bool _isInstagramLoginPath(Uri uri) =>
      uri.path.startsWith('/accounts/') || uri.path.startsWith('/challenge/');

  static bool _isTikTokLoginPath(Uri uri) => uri.path.startsWith('/login');

  /// 指定した SNS（Instagram または TikTok）で [query] のアカウントを高速検索する。
  void searchSns(SnsPlatform platform, String query) {
    if (platform == SnsPlatform.tiktok) {
      searchTikTok(query);
    } else if (platform == SnsPlatform.instagram) {
      searchInstagram(query);
    } else {
      open(platform.searchUrl(query));
    }
  }

  /// Instagram で [query] のアカウントを検索する。
  /// すでに Instagram のページが開いていればページ全体の再読み込みは行わず、その場で検索欄を開いて即時入力する。
  void searchInstagram(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final pane = _pane(SnsPaneKind.instagram);
    _setActivePane(SnsPaneKind.instagram);
    pane.pendingSearch = trimmed;
    pane.searchId++;
    pane.searchQuery = trimmed;

    final current = Uri.tryParse(pane.url ?? '');
    if (pane.web != null && _isInstagramHost(current)) {
      if (_isInstagramLoginPath(current!)) {
        pane.searchStatus = InstagramSearchStatus.waitingForLogin;
        notifyListeners();
        return;
      }
      pane.searchStatus = InstagramSearchStatus.searching;
      notifyListeners();
      unawaited(_runPendingInstagramSearch(pane));
      return;
    }

    pane.searchStatus = InstagramSearchStatus.searching;
    _loadInPane(pane, searchUrl);
  }

  /// TikTok で [query] のユーザー（アカウント）一覧を高速検索する。
  /// すでに TikTok ペインが起動していれば SPA 内部遷移と検索欄書き換えで素早く切り替える。
  void searchTikTok(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final pane = _pane(SnsPaneKind.tiktok);
    _setActivePane(SnsPaneKind.tiktok);
    pane.pendingSearch = null;
    pane.searchId++;
    pane.searchQuery = trimmed;
    pane.searchStatus = InstagramSearchStatus.none;

    final target = 'https://www.tiktok.com/search/user?q=${Uri.encodeQueryComponent(trimmed)}';
    final current = Uri.tryParse(pane.url ?? '');
    if (pane.web != null && _isTikTokHost(current) && !_isTikTokLoginPath(current!)) {
      pane.url = target;
      notifyListeners();
      unawaited(
        pane.web!
            .callAsyncJavaScript(
              functionBody: _tiktokSearchScript,
              arguments: {'query': trimmed, 'targetUrl': target},
            )
            .catchError((_) {
          pane.web?.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
          return null;
        }),
      );
      return;
    }
    _loadInPane(pane, target);
  }

  /// `@username`（またはプロフィール URL）へ直接ジャンプする。
  void openUsername(SnsPlatform platform, String rawHandle, {String? label}) {
    final trimmed = rawHandle.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      open(trimmed, label: label);
      return;
    }
    final clean = trimmed.replaceFirst(RegExp(r'^@+'), '');
    final parsed = parseSnsTag(platform, clean).firstOrNull;
    final link = parsed ?? SocialLink(platform, clean);
    open(link.url, label: label);
  }

  /// 周辺スポットのアカウント一覧と最近開いたアカウント履歴を束ねて、前後のアカウントへワンタップで順送りする。
  List<({SocialLink link, String? label})> buildSwitchableTargets(
    SnsPlatform platform, {
    List<NearbySnsTarget> nearbyTargets = const [],
  }) {
    if (platform != SnsPlatform.instagram && platform != SnsPlatform.tiktok) return const [];
    final seen = <String>{};
    final out = <({SocialLink link, String? label})>[];
    for (final item in nearbyTargets) {
      if (item.link.platform != platform || item.link.username == null) continue;
      if (seen.add(item.link.key)) {
        out.add((link: item.link, label: item.placeName));
      }
    }
    for (final r in accounts.recentTargetsOf(platform)) {
      final link = SocialLink(platform, r.username);
      if (seen.add(link.key)) {
        out.add((link: link, label: r.label));
      }
    }
    return out;
  }

  /// [delta]（`-1` で前、`+1` で次）の閲覧先アカウントへ即座に切り替える。切り替えられたら `true`。
  bool stepTargetAccount(
    int delta, {
    List<NearbySnsTarget> nearbyTargets = const [],
  }) {
    final platform = (_activePane == SnsPaneKind.tiktok) ? SnsPlatform.tiktok : SnsPlatform.instagram;
    final candidates = buildSwitchableTargets(platform, nearbyTargets: nearbyTargets);
    if (candidates.isEmpty) return false;
    final curUser = currentTargetUsername?.toLowerCase();
    final curIdx = curUser == null
        ? -1
        : candidates.indexWhere((c) => c.link.username?.toLowerCase() == curUser);
    final int nextIdx;
    if (curIdx < 0) {
      nextIdx = delta >= 0 ? 0 : candidates.length - 1;
    } else {
      nextIdx = (curIdx + delta) % candidates.length;
    }
    final chosen = candidates[nextIdx < 0 ? nextIdx + candidates.length : nextIdx];
    open(chosen.link.url, label: chosen.label);
    return true;
  }

  WebStorageCallbacks? _storageCallbacksFor(SnsPlatform platform) {
    final pane = _pane(_paneKindForPlatform(platform));
    final web = pane.web;
    if (web == null) return null;
    final current = Uri.tryParse(pane.url ?? '');
    final onTargetHost =
        platform == SnsPlatform.tiktok ? _isTikTokHost(current) : _isInstagramHost(current);
    if (!onTargetHost) return null;
    return (
      readLocalStorage: () async {
        try {
          final raw = await web.evaluateJavascript(
            source: '''
            (function() {
              try {
                const out = {};
                for (let i = 0; i < localStorage.length && i < 60; i++) {
                  const k = localStorage.key(i);
                  if (!k) continue;
                  const v = localStorage.getItem(k);
                  if (typeof v === 'string' && v.length <= 8192) out[k] = v;
                }
                return JSON.stringify(out);
              } catch (_) { return '{}'; }
            })();
            ''',
          );
          if (raw is String && raw.isNotEmpty) {
            final map = jsonDecode(raw);
            if (map is Map) {
              return {
                for (final MapEntry(:key, :value) in map.entries)
                  if (key is String && value is String) key: value,
              };
            }
          }
        } catch (_) {}
        return const <String, String>{};
      },
      replaceStorage: (nextLs) async {
        final encoded = jsonEncode(nextLs);
        try {
          await web.evaluateJavascript(
            source: '''
            (function() {
              try { sessionStorage.clear(); } catch (_) {}
              try {
                localStorage.clear();
                const data = $encoded;
                for (const k of Object.keys(data)) {
                  localStorage.setItem(k, data[k]);
                }
              } catch (_) {}
            })();
            ''',
          );
        } catch (_) {}
      },
    );
  }

  /// 自分のログイン中アカウントを指定スロットへ高速切り替えする。
  Future<void> switchLoginSlot(SnsPlatform platform, String slotId) async {
    if (!SnsAccountSwitcher.supportsLoginSlots(platform)) return;
    final pane = _pane(_paneKindForPlatform(platform));
    _setActivePane(pane.kind);
    final recommendedUrl = await accounts.switchToSlot(
      platform,
      slotId,
      storage: _storageCallbacksFor(platform),
    );
    _reloadOrOpenAfterSlotChange(pane, platform, recommendedUrl);
  }

  /// 自分のログイン中アカウントを次のスロットへワンタップ順送りする。
  Future<void> cycleLoginSlot([SnsPlatform? platform]) async {
    final targetPlatform = platform ??
        (_activePane == SnsPaneKind.tiktok ? SnsPlatform.tiktok : SnsPlatform.instagram);
    if (accounts.slotsOf(targetPlatform).length <= 1) return;
    final pane = _pane(_paneKindForPlatform(targetPlatform));
    _setActivePane(pane.kind);
    final recommendedUrl = await accounts.cycleNextSlot(
      targetPlatform,
      storage: _storageCallbacksFor(targetPlatform),
    );
    _reloadOrOpenAfterSlotChange(pane, targetPlatform, recommendedUrl);
  }

  /// 新しいログインアカウントスロットを追加し、その SNS のログイン画面を即座に開く。
  Future<void> addLoginSlot(SnsPlatform platform, {String? label}) async {
    if (!SnsAccountSwitcher.supportsLoginSlots(platform)) return;
    final pane = _pane(_paneKindForPlatform(platform));
    _setActivePane(pane.kind);
    final res = await accounts.addNewAccountSlot(
      platform,
      customLabel: label,
      storage: _storageCallbacksFor(platform),
    );
    _loadInPane(pane, res.loginUrl);
  }

  /// ログインスロットを削除する（アクティブスロットを削除した場合は残りスロットへ自動で切り替わる）。
  Future<void> deleteLoginSlot(SnsPlatform platform, String slotId) async {
    if (!SnsAccountSwitcher.supportsLoginSlots(platform)) return;
    final wasActive = accounts.activeSlotOf(platform).id == slotId;
    await accounts.deleteSlot(
      platform,
      slotId,
      storage: _storageCallbacksFor(platform),
    );
    if (wasActive) {
      final pane = _pane(_paneKindForPlatform(platform));
      final active = accounts.activeSlotOf(platform);
      _reloadOrOpenAfterSlotChange(
        pane,
        platform,
        active.hasSavedSession ? null : SnsAccountSwitcher.loginUrlOf(platform),
      );
    }
  }

  void _reloadOrOpenAfterSlotChange(_PaneState pane, SnsPlatform platform, String? recommendedUrl) {
    if (recommendedUrl != null) {
      _loadInPane(pane, recommendedUrl);
      return;
    }
    final cur = Uri.tryParse(pane.url ?? '');
    final onLoginPage = cur == null ||
        (platform == SnsPlatform.instagram && _isInstagramLoginPath(cur)) ||
        (platform == SnsPlatform.tiktok && _isTikTokLoginPath(cur));
    if (onLoginPage || !pane.started) {
      _loadInPane(pane, SnsAccountSwitcher.homeUrlOf(platform));
    } else if (pane.web != null) {
      pane.web!.reload();
      notifyListeners();
    } else {
      _loadInPane(pane, pane.url ?? SnsAccountSwitcher.homeUrlOf(platform));
    }
  }

  void dismissSearch() {
    _current.searchStatus = InstagramSearchStatus.none;
    notifyListeners();
  }

  void _setPaneSearchStatus(_PaneState pane, InstagramSearchStatus status) {
    if (pane.searchStatus == status) return;
    pane.searchStatus = status;
    notifyListeners();
  }

  Future<void> _runPendingInstagramSearch(_PaneState pane) async {
    final query = pane.pendingSearch;
    final id = pane.searchId;
    final web = pane.web;
    if (query == null || web == null || pane.runningSearchId == id) return;
    final current = Uri.tryParse(pane.url ?? '');
    if (!_isInstagramHost(current)) return;
    if (_isInstagramLoginPath(current!)) {
      // ログイン画面。ログインすると検索画面に戻るので、そのときに入力する
      _setPaneSearchStatus(pane, InstagramSearchStatus.waitingForLogin);
      return;
    }
    pane.runningSearchId = id;
    _setPaneSearchStatus(pane, InstagramSearchStatus.searching);
    String? result;
    try {
      final value = await web
          .callAsyncJavaScript(functionBody: _searchScript, arguments: {'query': query, 'seq': id})
          .timeout(const Duration(seconds: 15));
      result = value?.value as String?;
    } catch (e) {
      debugPrint('Instagram の検索欄に入力できませんでした: $e');
    } finally {
      if (pane.runningSearchId == id) pane.runningSearchId = 0;
    }
    if (id != pane.searchId) {
      // より新しい検索に切り替え済み
      return;
    }
    switch (result) {
      case 'done':
        pane.pendingSearch = null;
        _setPaneSearchStatus(pane, InstagramSearchStatus.none);
      case 'login':
        // トップページのログイン欄。ログインしてページが移ったら入力する
        _setPaneSearchStatus(pane, InstagramSearchStatus.waitingForLogin);
      case 'moved' || 'superseded':
        break; // 検索画面に移るので、読み込み次第入力する
      case 'failed':
        pane.pendingSearch = null;
        _setPaneSearchStatus(pane, InstagramSearchStatus.failed);
      default:
        // 入力中にページが移ったときなど。次にページを読み込んだときにもう一度試す
        if (pane.progress >= 1) _setPaneSearchStatus(pane, InstagramSearchStatus.failed);
    }
  }

  /// 同一オリジン内で SPA ルーターのリンク遷移を発火させ、失敗時は即座に `location.assign` へフォールバックするスクリプト。
  static const _fastSpaNavigateScript = r'''
const before = location.href;
try {
  if (location.href === fullUrl || (location.pathname + location.search) === targetPath) {
    return 'same';
  }
  const cleanTarget = targetPath.replace(/\/$/, '');
  const existing = [...document.querySelectorAll('a[href]')].find((a) => {
    const h = (a.getAttribute('href') || '').trim();
    return h === targetPath || h.replace(/\/$/, '') === cleanTarget || h === fullUrl;
  });
  if (existing) {
    existing.click();
  } else if (document.body) {
    const a = document.createElement('a');
    a.href = targetPath;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { try { a.remove(); } catch (_) {} }, 0);
  } else {
    location.assign(fullUrl);
    return 'assigned';
  }
  setTimeout(() => {
    if (location.href === before) {
      location.assign(fullUrl);
    }
  }, 180);
  return 'spa';
} catch (_) {
  location.assign(fullUrl);
  return 'assigned';
}
''';

  /// TikTok Web 上でページ全体を再読込せずユーザー検索欄の更新と `/search/user?q=...` への SPA 遷移を行うスクリプト。
  static const _tiktokSearchScript = r'''
const before = location.href;
try {
  const input = document.querySelector('input[data-e2e="search-user-input"], form[action*="/search"] input, input[type="search"]');
  if (input) {
    const tracker = input._valueTracker;
    if (tracker) tracker.setValue(input.value || '');
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    if (setValue) setValue.call(input, query);
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: query }));
  }
  const rel = '/search/user?q=' + encodeURIComponent(query);
  if (document.body) {
    const a = document.createElement('a');
    a.href = rel;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { try { a.remove(); } catch (_) {} }, 0);
    setTimeout(() => {
      if (location.href === before) location.assign(targetUrl);
    }, 180);
    return 'done';
  }
} catch (_) {}
location.assign(targetUrl);
return 'done';
''';

  /// Instagram の検索欄に [query] を高速で入れる。
  /// - すでに検索欄が表示されていれば 0ms で書き換えて React の検索イベントを発火させる
  /// - PC 表示でドロワーが閉じていれば待ち時間なしでサイドバーの「検索」を押して開く
  /// - スマホ表示で別ページを見ていればすぐに検索画面へ遷移する
  static const _searchScript = r'''
window.__nearbySearchSeq = seq;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const visible = (el) => {
  if (!el) return false;
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
};
const findInput = () => [...document.querySelectorAll('input')].find((input) =>
  (input.type === 'text' || input.type === 'search' || !input.type) && visible(input) &&
  /検索|search/i.test(
    (input.getAttribute('aria-label') || '') + ' ' +
    (input.placeholder || '') + ' ' +
    (input.getAttribute('name') || '')
  ));
const fill = (input) => {
  input.focus();
  if (input.value === query) {
    input.dispatchEvent(new Event('focus', { bubbles: true }));
    return true;
  }
  const prev = input.value;
  try { input.setSelectionRange(0, prev.length); } catch (_) { input.select(); }
  let ok = false;
  try {
    ok = document.execCommand('insertText', false, query) && input.value === query;
  } catch (_) {}
  if (!ok) {
    const tracker = input._valueTracker;
    if (tracker) tracker.setValue(prev);
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setValue.call(input, query);
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: query }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  return input.value === query;
};

let clicked = false;
const onSearchPath = location.pathname.startsWith('/explore/search');
for (let i = 0; i < 160; i++) {
  if (window.__nearbySearchSeq !== seq) return 'superseded';
  if ([...document.querySelectorAll('input[type="password"]')].some(visible)) return 'login';
  const input = findInput();
  if (input) return fill(input) ? 'done' : 'failed';

  if (!clicked && (!onSearchPath || i >= 3)) {
    const icons = [...document.querySelectorAll('svg[aria-label]')].filter((svg) =>
      /^(検索|Search)$/.test(svg.getAttribute('aria-label') || ''));
    for (const icon of icons) {
      const button = icon.closest('a, [role="button"], [role="link"], button');
      if (!button || !visible(button)) continue;
      const href = button.getAttribute('href') || '';
      if (!onSearchPath || !href || href === '#' || href.startsWith('/explore/search')) {
        button.click();
        clicked = true;
        break;
      }
    }
  }
  if (!onSearchPath && !clicked && document.readyState !== 'loading' && i >= 2) {
    const searchLink = document.querySelector('a[href^="/explore/search"]');
    if (searchLink && visible(searchLink)) {
      searchLink.click();
      clicked = true;
    } else {
      setTimeout(() => location.assign('/explore/search/'), 10);
      return 'moved';
    }
  }
  if (i === 40 && !location.pathname.startsWith('/explore/search')) {
    setTimeout(() => location.assign('/explore/search/'), 10);
    return 'moved';
  }
  await sleep(50);
}
return 'failed';
''';

  /// Instagram および TikTok で「フォロー中」「フォロワー」一覧を開いたときにアカウント行（アイコン画像＋名前）を検出し、
  /// Jev で女性個人のアカウントと判定されたものだけを表示するスクリプト。
  ///
  /// - 初回取得分だけでなく、非表示によってリストが画面高より短くなった場合や下端付近までスクロールした場合に
  ///   自動で次ページの読み込みを発火させ、女性アカウントが十分に並ぶか末尾に達するまで取得を進める。
  /// - スクロールや再取得（`fetch` / `XMLHttpRequest` による追加ページ取得・仮想スクロール行再利用）で
  ///   後から差し込まれたアカウントも判定完了まで即座に隠し、女性と判定された行だけを表示する。
  static const followerFilterScript = r'''
(function() {
  const host = (location.hostname || '').toLowerCase();
  const IS_INSTAGRAM = host === 'instagram.com' || host.endsWith('.instagram.com');
  const IS_TIKTOK = host === 'tiktok.com' || host.endsWith('.tiktok.com');
  if (!IS_INSTAGRAM && !IS_TIKTOK) return;
  if (window.__nearbyJevInstalled) return;
  window.__nearbyJevInstalled = true;

  const PLATFORM = IS_TIKTOK ? 'tiktok' : 'instagram';
  const USER_LINK_SELECTOR = IS_TIKTOK ? 'a[href*="/@"]' : 'a[href^="/"]';
  const RESERVED = new Set([
    'explore', 'direct', 'reels', 'stories', 'accounts', 'p', 'reel', 'tv',
    'about', 'legal', 'privacy', 'terms', 'session', 'challenge', 'oauth',
    'graphql', 'api', 'nametag', 'directory', 'topics', 'web', 'threads',
    'foryou', 'following', 'friends', 'live', 'upload', 'messages', 'search', 'tag', 'music', 'tiktok'
  ]);
  const USERNAME_RE = IS_TIKTOK ? /^[A-Za-z0-9._]{1,32}$/ : /^[A-Za-z0-9._]{1,30}$/;
  const API_URL_RE = IS_TIKTOK
    ? /(\/api\/user\/list|\/user\/(follower|following)|\/aweme\/v\d+\/user\/(follower|following)|\/relations\/)/i
    : /(\/api\/v1\/friendships\/|\/graphql|followers|following)/i;
  const FRIENDSHIPS_LIST_RE = IS_TIKTOK
    ? /(\/api\/user\/list|\/user\/(follower|following)\/list|\/aweme\/v\d+\/user\/(follower|following)\/list)/i
    : /\/api\/v1\/friendships\/[^/?#]+\/(followers|following|mutual)/i;
  const FOLLOW_GRAPH_KEY_RE = /^(edge_followed_by|edge_follow|xdt_api__v1__friendships|mutual_followers|userList)/i;
  const IGNORE_TEXT = /^(フォロー|フォロー中|フォローバック|フォローする|友達|削除|メッセージ|リクエスト済み|ブロック|制限する|親しい友達|共通|認証済み|新しいフォロワー|すべて見る|おすすめ|購読|Follow|Following|Follow Back|Friends|Remove|Message|Requested|Verified|New|See All|Suggested|Subscriptions|•|・|\s*)$/i;
  const IGNORE_SUB = /(がフォロー中|Followed by|フォロワー\s*[\d,.万億kKmM]+|フォロー中\s*[\d,.万億kKmM]+|件の投稿|Followers\s*[\d,.kKmM]+)/i;
  const FOLLOW_HEADER = /^(?:[\d,.万億kKmM]+\s*(?:人|人の)?\s*)?(フォロワー|フォロー中|共通のフォロワー|友達|Followers|Following|Mutual|Mutual followers|Friends)(?:\s*[\d,.万億kKmM人件]+)?$/i;
  const NON_FOLLOW_TAB = /^(おすすめ|Suggested)$/i;
  const AVATAR_SIZE = 320;
  const MIN_VISIBLE_FEMALES = 12;
  const PULSE_COOLDOWN_MS = 850;
  const MAX_EMPTY_PULSES = 5;

  // uLower -> { isFemale: boolean, hasImg: boolean }
  const judged = new Map();
  // uLower -> { u, key, n, img }（SNS の通信レスポンスから補完するプロフィール情報）
  const apiUsers = new Map();
  // uLower -> { u, key, n, img, b64, fmt }
  const pendingQueue = new Map();
  const inflight = new Set();
  const failCounts = new Map();
  const hookedImages = new WeakSet();

  let avatarCanvas = null;
  let avatarCtx = null;
  let enabled = false;
  let timer = null;
  let cooldownTimer = null;
  let pumping = false;
  let observerStarted = false;
  let lastReportedKey = '';
  let lastReportedViewer = '';

  // 現在開いているフォロワー・フォロー中一覧ごとのページ送り状態
  let activeContextKey = '';
  const seenInContext = new Set();
  let apiBatchSeq = 0;
  let apiHasMore = null;
  let reachedEnd = false;
  let emptyPulseCount = 0;
  let pulseInProgress = false;
  let autoFetching = false;
  let lastPulseAt = 0;
  let lastUserScrollAt = 0;

  function resetPaginationState(nextKey) {
    activeContextKey = nextKey || '';
    seenInContext.clear();
    apiHasMore = null;
    reachedEnd = false;
    emptyPulseCount = 0;
    pulseInProgress = false;
    autoFetching = false;
    if (cooldownTimer) {
      clearTimeout(cooldownTimer);
      cooldownTimer = null;
    }
  }

  function ensureStyle() {
    const target = document.head || document.documentElement;
    if (!target || document.getElementById('nearby-jev-style')) return;
    const style = document.createElement('style');
    style.id = 'nearby-jev-style';
    style.textContent =
      'html.nearby-jev-female-only [data-nearby-jev-nonfemale="1"],\n' +
      'html.nearby-jev-female-only [data-nearby-jev-pending="1"] {\n' +
      '  display: none !important;\n' +
      '}\n' +
      'html.nearby-jev-female-only [data-nearby-jev-nonfemale="1"][data-nearby-jev-tail-probe="1"] {\n' +
      '  display: block !important;\n' +
      '  height: 1px !important;\n' +
      '  min-height: 1px !important;\n' +
      '  max-height: 1px !important;\n' +
      '  overflow: hidden !important;\n' +
      '  opacity: 0 !important;\n' +
      '  pointer-events: none !important;\n' +
      '  margin: 0 !important;\n' +
      '  padding: 0 !important;\n' +
      '  border: 0 !important;\n' +
      '}';
    target.appendChild(style);
  }

  function applyRootClass() {
    ensureStyle();
    if (document.documentElement) {
      document.documentElement.classList.toggle('nearby-jev-female-only', !!enabled);
    }
  }

  function detectViewerUsername() {
    try {
      let viewer = '';
      if (IS_TIKTOK) {
        const navProf = document.querySelector('[data-e2e="nav-profile"] a[href*="/@"], a[data-e2e="nav-profile"][href*="/@"]');
        if (navProf) {
          viewer = parseUsernameHref(navProf.getAttribute('href')) || '';
        }
        if (!viewer) {
          const uni = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
          if (uni && uni.textContent) {
            const m = /"webapp\.app-context"\s*:\s*\{[\s\S]{0,1200}?"uniqueId"\s*:\s*"([A-Za-z0-9._]{1,32})"/.exec(uni.textContent);
            if (m) viewer = m[1];
          }
        }
      } else {
        const navLinks = document.querySelectorAll('nav a[href^="/"], [role="navigation"] a[href^="/"]');
        for (const a of navLinks) {
          const hasProfHint =
            a.querySelector('img[alt*="プロフィール"], img[alt*="profile" i]') ||
            /^(プロフィール|Profile)$/i.test((a.textContent || '').trim());
          if (hasProfHint) {
            const u = parseUsernameHref(a.getAttribute('href'));
            if (u) {
              viewer = u;
              break;
            }
          }
        }
      }
      if (viewer && viewer !== lastReportedViewer && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        lastReportedViewer = viewer;
        window.flutter_inappwebview.callHandler('nearbyDetectedViewer', { p: PLATFORM, u: viewer }).catch(() => {});
      }
    } catch (_) {}
  }

  function enqueueCandidate(u, key, n, img, b64, fmt) {
    if (!u || !key) return;
    const apiEntry = apiUsers.get(key);
    const mergedName = n || (apiEntry ? apiEntry.n : '') || '';
    const mergedImg = img || (apiEntry ? apiEntry.img : '') || '';
    const hasImg = !!(mergedImg || b64);
    const cached = judged.get(key);
    if (cached !== undefined && (cached.hasImg || !hasImg)) return;
    if (inflight.has(key)) return;
    if ((failCounts.get(key) || 0) >= 3) return;

    const existing = pendingQueue.get(key);
    if (existing) {
      if (!existing.n && mergedName) existing.n = mergedName;
      if (!existing.img && mergedImg) existing.img = mergedImg;
      if (!existing.b64 && b64) {
        existing.b64 = b64;
        existing.fmt = fmt;
      }
      return;
    }
    pendingQueue.set(key, {
      u: u,
      key: key,
      n: mergedName,
      img: mergedImg,
      b64: b64 || '',
      fmt: fmt || ''
    });
  }

  function pickTikTokAvatarUrl(v) {
    if (typeof v === 'string') return v;
    if (v && typeof v === 'object') {
      if (Array.isArray(v.url_list) && typeof v.url_list[0] === 'string') return v.url_list[0];
      if (Array.isArray(v.urlList) && typeof v.urlList[0] === 'string') return v.urlList[0];
    }
    return '';
  }

  function rememberApiUser(u, fullName, picUrl, foundByKey) {
    const uLower = u.toLowerCase();
    const prev = apiUsers.get(uLower);
    const entry = {
      u: u,
      key: uLower,
      n: fullName || (prev ? prev.n : ''),
      img: picUrl || (prev ? prev.img : '')
    };
    apiUsers.set(uLower, entry);
    if (apiUsers.size > 6000) {
      const oldest = apiUsers.keys().next().value;
      apiUsers.delete(oldest);
    }
    foundByKey.set(uLower, entry);
  }

  function inspectApiObject(rootObj, reqUrl) {
    if (!rootObj || typeof rootObj !== 'object') return;
    const foundByKey = new Map();
    let hasFollowGraphKey = false;
    let detectedMore = null;
    let visited = 0;

    function walk(node, depth) {
      if (!node || typeof node !== 'object' || depth > 12 || visited > 3500) return;
      visited++;
      if (Array.isArray(node)) {
        for (let i = 0; i < node.length; i++) walk(node[i], depth + 1);
        return;
      }

      if (IS_INSTAGRAM) {
        if (Array.isArray(node.users) && ('next_max_id' in node || 'has_more' in node || 'big_list' in node)) {
          detectedMore = Boolean(node.next_max_id) || node.has_more === true;
        }
        if (node.page_info && typeof node.page_info === 'object' &&
            typeof node.page_info.has_next_page === 'boolean' && Array.isArray(node.edges)) {
          detectedMore = node.page_info.has_next_page;
        }
        if (typeof node.username === 'string') {
          const u = node.username.trim();
          const uLower = u.toLowerCase();
          if (USERNAME_RE.test(u) && !RESERVED.has(uLower) &&
              ('profile_pic_url' in node || 'full_name' in node || 'pk' in node || 'hd_profile_pic_url_info' in node)) {
            const fullName = typeof node.full_name === 'string' ? node.full_name.trim() : '';
            const picUrl = (typeof node.profile_pic_url === 'string' && node.profile_pic_url) ||
              (node.hd_profile_pic_url_info && typeof node.hd_profile_pic_url_info.url === 'string' && node.hd_profile_pic_url_info.url) || '';
            rememberApiUser(u, fullName, picUrl, foundByKey);
          }
        }
      } else if (IS_TIKTOK) {
        if (Array.isArray(node.userList) || Array.isArray(node.followers) || Array.isArray(node.followings)) {
          if (typeof node.hasMore === 'boolean') detectedMore = node.hasMore;
          else if (typeof node.has_more === 'boolean') detectedMore = node.has_more;
          else if (typeof node.minCursor === 'number') detectedMore = node.minCursor > 0;
        }
        const ttRawId = typeof node.uniqueId === 'string'
          ? node.uniqueId
          : (typeof node.unique_id === 'string' ? node.unique_id : '');
        if (ttRawId) {
          const u = ttRawId.trim().replace(/^@/, '');
          const uLower = u.toLowerCase();
          if (USERNAME_RE.test(u) && !RESERVED.has(uLower) &&
              ('nickname' in node || 'avatarThumb' in node || 'avatarMedium' in node || 'avatarLarger' in node || 'avatar_thumb' in node)) {
            const nick = typeof node.nickname === 'string' ? node.nickname.trim() : '';
            const picUrl =
              pickTikTokAvatarUrl(node.avatarMedium) ||
              pickTikTokAvatarUrl(node.avatarThumb) ||
              pickTikTokAvatarUrl(node.avatarLarger) ||
              pickTikTokAvatarUrl(node.avatar_medium) ||
              pickTikTokAvatarUrl(node.avatar_thumb);
            rememberApiUser(u, nick, picUrl, foundByKey);
          }
        }
      }

      for (const k of Object.keys(node)) {
        if (FOLLOW_GRAPH_KEY_RE.test(k)) hasFollowGraphKey = true;
        if (k === 'extensions') continue;
        walk(node[k], depth + 1);
      }
    }

    walk(rootObj, 0);
    const ctxNow = findFollowListContext();
    const isFollowApi = (FRIENDSHIPS_LIST_RE.test(reqUrl) && (!IS_TIKTOK || !!ctxNow || /scene=(21|67)\b/.test(reqUrl))) ||
      (hasFollowGraphKey && !!ctxNow);
    if (isFollowApi) {
      apiBatchSeq++;
      if (detectedMore !== null) {
        apiHasMore = detectedMore;
        if (!detectedMore) {
          reachedEnd = true;
          autoFetching = false;
        } else {
          reachedEnd = false;
          emptyPulseCount = 0;
        }
      } else if (foundByKey.size > 0) {
        reachedEnd = false;
        emptyPulseCount = 0;
      }

      if (enabled && foundByKey.size > 0 && ctxNow) {
        for (const usr of foundByKey.values()) {
          if (ctxNow.owner && usr.key === ctxNow.owner) continue;
          seenInContext.add(usr.key);
          enqueueCandidate(usr.u, usr.key, usr.n, usr.img, '', '');
        }
        pumpQueue();
      }
    }
    if (foundByKey.size > 0 || isFollowApi) {
      scheduleScan(16);
    }
  }

  function inspectRawJson(raw, reqUrl) {
    if (!raw || typeof raw !== 'string') return;
    const cleaned = raw.replace(/^\s*for\s*\(\s*;\s*;\s*\)\s*;?\s*/, '');
    if (!cleaned || (cleaned[0] !== '{' && cleaned[0] !== '[')) return;
    try {
      inspectApiObject(JSON.parse(cleaned), reqUrl);
    } catch (_) {}
  }

  function hookNetwork() {
    try {
      if (typeof window.fetch === 'function' && !window.fetch.__nearbyHooked) {
        const origFetch = window.fetch;
        const wrappedFetch = function(input) {
          let reqUrl = '';
          try {
            reqUrl = typeof input === 'string' ? input : ((input && input.url) || String(input || ''));
          } catch (_) {}
          const p = origFetch.apply(this, arguments);
          if (API_URL_RE.test(reqUrl) && p && typeof p.then === 'function') {
            p.then((res) => {
              try {
                if (!res || typeof res.clone !== 'function') return;
                const ct = (res.headers && res.headers.get && res.headers.get('content-type')) || '';
                if (ct && !/json|javascript|text/i.test(ct)) return;
                res.clone().text().then((txt) => inspectRawJson(txt, reqUrl)).catch(() => {});
              } catch (_) {}
            }).catch(() => {});
          }
          return p;
        };
        wrappedFetch.__nearbyHooked = true;
        window.fetch = wrappedFetch;
      }
    } catch (_) {}

    try {
      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype && !XMLHttpRequest.prototype.__nearbyHooked) {
        const origOpen = XMLHttpRequest.prototype.open;
        const origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          try { this.__nearbyReqUrl = typeof url === 'string' ? url : String(url || ''); } catch (_) {}
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          try {
            const reqUrl = this.__nearbyReqUrl || '';
            if (API_URL_RE.test(reqUrl)) {
              this.addEventListener('load', function() {
                try {
                  const rt = this.responseType;
                  if (!rt || rt === 'text') {
                    inspectRawJson(this.responseText, reqUrl);
                  } else if (rt === 'json' && this.response) {
                    inspectApiObject(this.response, reqUrl);
                  }
                } catch (_) {}
              });
            }
          } catch (_) {}
          return origSend.apply(this, arguments);
        };
        XMLHttpRequest.prototype.__nearbyHooked = true;
      }
    } catch (_) {}
  }

  function parseUsernameHref(href) {
    if (!href) return null;
    if (IS_TIKTOK) {
      let p = href.trim();
      if (/^https?:\/\//i.test(p)) {
        try {
          const uo = new URL(p);
          if (!uo.hostname.toLowerCase().endsWith('tiktok.com')) return null;
          p = uo.pathname + uo.search;
        } catch (_) {
          return null;
        }
      }
      const m = /^\/@([A-Za-z0-9._]{1,32})\/?(?:\?.*)?$/.exec(p);
      if (!m) return null;
      const u = m[1];
      if (RESERVED.has(u.toLowerCase())) return null;
      return u;
    }
    const m = /^\/([A-Za-z0-9._]{1,30})\/?(?:\?.*)?$/.exec(href.trim());
    if (!m) return null;
    const u = m[1];
    if (RESERVED.has(u.toLowerCase())) return null;
    return u;
  }

  function findFollowListContext() {
    if (!document.body) return null;
    const pathname = location.pathname || '';

    if (IS_TIKTOK) {
      const ttListPath = /^\/@([^/?#]+)\/(followers|following)(\/|$)/i.exec(pathname);
      const ttProfilePath = /^\/@([A-Za-z0-9._]{1,32})\/?$/i.exec(pathname);
      const profileOwner = ttListPath
        ? ttListPath[1].toLowerCase()
        : (ttProfilePath ? ttProfilePath[1].toLowerCase() : null);

      const modalCandidates = [
        ...document.querySelectorAll(
          '[data-e2e="follow-info-popup"], [role="dialog"], [aria-modal="true"], #tux-portal-container > div'
        )
      ].filter((d) => {
        if (d.closest('nav, header')) return false;
        const r = d.getBoundingClientRect();
        return r.width > 160 && r.height > 160;
      });

      for (let i = modalCandidates.length - 1; i >= 0; i--) {
        const d = modalCandidates[i];
        const dRect = d.getBoundingClientRect();
        const tabs = [...d.querySelectorAll('[role="tab"]')];
        const activeTab = tabs.find((t) => t.getAttribute('aria-selected') === 'true');
        if (activeTab && NON_FOLLOW_TAB.test((activeTab.textContent || '').trim())) {
          continue;
        }
        const headers = d.querySelectorAll('[role="tab"], h1, h2, h3, [role="heading"], header, div, span');
        let matchedHeader = '';
        for (const h of headers) {
          if (h.children.length > 2) continue;
          const hr = h.getBoundingClientRect();
          if (hr.top - dRect.top > 150) continue;
          const t = (h.textContent || '').replace(/\s+/g, ' ').trim();
          if (t && t.length <= 36 && FOLLOW_HEADER.test(t)) {
            matchedHeader = t;
            if (h.getAttribute('aria-selected') === 'true' || h.tagName === 'H1' || h.tagName === 'H2') {
              break;
            }
          }
        }
        const isExplicitPopup =
          d.getAttribute('data-e2e') === 'follow-info-popup' ||
          !!d.querySelector('[data-e2e="follow-info-popup"], [data-e2e*="follow-info-item"]');
        if (matchedHeader || isExplicitPopup) {
          return {
            root: d,
            owner: profileOwner,
            isDialog: true,
            key: 'ttdlg:' + pathname + ':' + (matchedHeader || 'popup')
          };
        }
      }

      if (ttListPath) {
        return {
          root: document.querySelector('main') || document.body,
          owner: profileOwner,
          isDialog: false,
          key: 'ttpage:' + pathname
        };
      }
      return null;
    }

    const pathMatch = /^\/([^/]+)\/(followers|following|mutual_followers)(\/|$)/i.exec(pathname);
    const pathOwner = pathMatch && !RESERVED.has(pathMatch[1].toLowerCase()) ? pathMatch[1].toLowerCase() : null;

    const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter((d) => {
      const r = d.getBoundingClientRect();
      return r.width > 140 && r.height > 140;
    });
    for (let i = dialogs.length - 1; i >= 0; i--) {
      const d = dialogs[i];
      const dRect = d.getBoundingClientRect();
      const headers = d.querySelectorAll('h1, h2, [role="heading"], [role="tab"], header, div, span');
      let matchedHeader = '';
      for (const h of headers) {
        if (h.children.length > 2) continue;
        const hr = h.getBoundingClientRect();
        if (hr.top - dRect.top > 130) continue;
        const t = (h.textContent || '').trim();
        if (t && t.length <= 30 && FOLLOW_HEADER.test(t)) {
          const isSelectedTab = h.getAttribute('aria-selected') === 'true';
          matchedHeader = t;
          if (isSelectedTab || h.tagName === 'H1' || h.tagName === 'H2' || h.getAttribute('role') === 'heading') {
            break;
          }
        }
      }
      if (matchedHeader || pathOwner) {
        return {
          root: d,
          owner: pathOwner,
          isDialog: true,
          key: 'dlg:' + pathname + ':' + matchedHeader
        };
      }
    }

    if (pathOwner) {
      return {
        root: document.querySelector('main') || document.body,
        owner: pathOwner,
        isDialog: false,
        key: 'page:' + pathname
      };
    }
    return null;
  }

  function isSubtitleLink(a) {
    if (a.querySelector('img, canvas, svg')) return false;
    const span = a.closest('span');
    if (!span || span.querySelector('div')) return false;
    const sr = span.getBoundingClientRect();
    if (sr.height > 32) return false;
    const txt = (span.textContent || '').replace(/\s+/g, ' ').trim();
    return txt.length <= 90 && /^(Followed by\s+|.+がフォロー中)/i.test(txt);
  }

  function isPrimaryUserLink(a, otherLower) {
    if (isSubtitleLink(a)) return false;
    if (IS_TIKTOK) return true;
    if (a.querySelector('img, canvas, svg')) return true;
    const t = (a.textContent || '').trim().toLowerCase().replace(/^@/, '');
    return t === otherLower || t.startsWith(otherLower + '\n') || t.startsWith(otherLower + ' ');
  }

  function isScrollableBox(el) {
    if (!el || el === document.body || el === document.documentElement) return true;
    try {
      const oy = getComputedStyle(el).overflowY;
      return oy === 'auto' || oy === 'scroll' || oy === 'overlay';
    } catch (_) {
      return false;
    }
  }

  function clearRowAttrs(el) {
    el.removeAttribute('data-nearby-jev-row');
    el.removeAttribute('data-nearby-jev-female');
    el.removeAttribute('data-nearby-jev-nonfemale');
    el.removeAttribute('data-nearby-jev-pending');
    el.removeAttribute('data-nearby-jev-tail-probe');
  }

  // 仮想スクロールで行 DOM が別アカウントに再利用された場合、古い判定属性を即座に剥がす
  function reconcileMarkedRows(ctx) {
    const markedList = ctx.root.querySelectorAll('[data-nearby-jev-row]');
    for (const el of markedList) {
      const prevUser = el.getAttribute('data-nearby-jev-row') || '';
      const rowLinks = el.querySelectorAll(USER_LINK_SELECTOR);
      const usersInRow = new Set();
      for (const a of rowLinks) {
        if (isSubtitleLink(a)) continue;
        const u = parseUsernameHref(a.getAttribute('href'));
        if (!u) continue;
        const ul = u.toLowerCase();
        if (ctx.owner && ul === ctx.owner) continue;
        if (isPrimaryUserLink(a, ul)) usersInRow.add(ul);
      }
      if (usersInRow.size !== 1 || !usersInRow.has(prevUser)) {
        clearRowAttrs(el);
      }
    }
  }

  function findRowElement(links, uLower, ctx) {
    for (const a of links) {
      const marked = a.closest('[data-nearby-jev-row]');
      if (marked && ctx.root.contains(marked) && marked.getAttribute('data-nearby-jev-row') === uLower) {
        return marked;
      }
    }
    const anchor = links.find((a) => !a.querySelector('img') && (a.textContent || '').toLowerCase().includes(uLower)) ||
      links.find((a) => (a.textContent || '').toLowerCase().includes(uLower)) ||
      links[0];
    if (!anchor) return null;
    if (!ctx.isDialog && anchor.closest('header, nav')) return null;

    const anchorRect = anchor.getBoundingClientRect();
    const anchorCenterY = anchorRect.top + anchorRect.height / 2;

    let cur = anchor;
    let depth = 0;
    while (cur.parentElement && cur.parentElement !== ctx.root && depth < 10) {
      const parent = cur.parentElement;
      if (!ctx.isDialog && (parent.tagName === 'HEADER' || parent.tagName === 'NAV' || parent.tagName === 'MAIN')) break;
      if (parent.tagName === 'UL' || parent.tagName === 'OL') break;
      if (isScrollableBox(parent)) break;
      if (parent.querySelector('input, h1, h2, [role="heading"], [role="tablist"]')) break;

      const curH = cur.getBoundingClientRect().height;
      const parH = parent.getBoundingClientRect().height;
      if (curH >= 40 && parH > Math.max(260, curH * 1.85)) break;

      let hasOtherUser = false;
      if (parent.querySelector('[data-nearby-jev-row]:not([data-nearby-jev-row="' + uLower + '"])')) {
        hasOtherUser = true;
      } else {
        const pLinks = parent.querySelectorAll(USER_LINK_SELECTOR);
        for (const pa of pLinks) {
          if (isSubtitleLink(pa)) continue;
          const ou = parseUsernameHref(pa.getAttribute('href'));
          if (!ou) continue;
          const oLower = ou.toLowerCase();
          if (ctx.owner && oLower === ctx.owner) continue;
          if (oLower === uLower) continue;
          if (isPrimaryUserLink(pa, oLower)) {
            const pr = pa.getBoundingClientRect();
            if (pr.height === 0 || anchorRect.height === 0 || Math.abs((pr.top + pr.height / 2) - anchorCenterY) >= 30) {
              hasOtherUser = true;
              break;
            }
          }
        }
      }
      if (hasOtherUser) break;
      cur = parent;
      depth++;
    }

    const r = cur.getBoundingClientRect();
    if (r.height > 0 && (r.height < 26 || r.height > 340)) return null;
    cur.setAttribute('data-nearby-jev-row', uLower);
    return cur;
  }

  function extractDisplayName(row, uLower) {
    const apiEntry = apiUsers.get(uLower);
    if (IS_TIKTOK && apiEntry && apiEntry.n) return apiEntry.n;
    const nodes = row.querySelectorAll('span, p, div');
    for (const el of nodes) {
      if (el.closest('button, [role="button"]')) continue;
      if (el.querySelector('span, p, div, button, a, ul')) continue;
      const t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (!t || t.length > 60) continue;
      const tl = t.toLowerCase();
      if (tl === uLower || tl === '@' + uLower) continue;
      if (IGNORE_TEXT.test(t) || IGNORE_SUB.test(t)) continue;
      return t;
    }
    return apiEntry ? apiEntry.n : '';
  }

  function findAvatarImg(row, uLower) {
    const imgs = row.querySelectorAll('img');
    let fallback = null;
    for (const img of imgs) {
      const src = img.currentSrc || img.getAttribute('src') || '';
      if (!src || src.startsWith('data:image/svg')) continue;
      const w = img.naturalWidth || img.width || img.clientWidth || 0;
      const h = img.naturalHeight || img.height || img.clientHeight || 0;
      if (w > 0 && w < 24 && h > 0 && h < 24) continue;
      const alt = (img.getAttribute('alt') || '').toLowerCase();
      if (alt.includes('プロフィール') || alt.includes('profile') || alt.includes('avatar') || alt.includes(uLower)) {
        return img;
      }
      if (!fallback) fallback = img;
    }
    return fallback;
  }

  function extractAvatar(row, uLower) {
    const apiEntry = apiUsers.get(uLower);
    const apiImgUrl = apiEntry ? apiEntry.img : '';
    const img = findAvatarImg(row, uLower);
    if (!img) return { url: apiImgUrl, b64: '', fmt: '' };
    const url = img.currentSrc || img.getAttribute('src') || apiImgUrl || '';
    if (!img.complete && !hookedImages.has(img)) {
      hookedImages.add(img);
      img.addEventListener('load', () => scheduleScan(60), { once: true });
    }
    if (img.complete && img.naturalWidth >= 24 && img.naturalHeight >= 24) {
      try {
        if (!avatarCanvas) {
          avatarCanvas = document.createElement('canvas');
          avatarCanvas.width = AVATAR_SIZE;
          avatarCanvas.height = AVATAR_SIZE;
          avatarCtx = avatarCanvas.getContext('2d', { willReadFrequently: false });
        }
        if (avatarCtx) {
          avatarCtx.fillStyle = '#ffffff';
          avatarCtx.fillRect(0, 0, AVATAR_SIZE, AVATAR_SIZE);
          const sw = img.naturalWidth;
          const sh = img.naturalHeight;
          const scale = Math.max(AVATAR_SIZE / sw, AVATAR_SIZE / sh);
          const dw = sw * scale;
          const dh = sh * scale;
          const dx = (AVATAR_SIZE - dw) / 2;
          const dy = (AVATAR_SIZE - dh) / 2;
          avatarCtx.drawImage(img, dx, dy, dw, dh);
          const dataUrl = avatarCanvas.toDataURL('image/jpeg', 0.82);
          const comma = dataUrl.indexOf(',');
          if (comma > 0) {
            return { url: url, b64: dataUrl.slice(comma + 1), fmt: 'jpg' };
          }
        }
      } catch (_) {
        // CORS 制約時は url を Flutter 側へ渡して直接取得・320x320 化する
      }
    }
    return { url: url, b64: '', fmt: '' };
  }

  function applyRowJudgment(row, isFemale) {
    row.removeAttribute('data-nearby-jev-pending');
    if (isFemale) {
      row.setAttribute('data-nearby-jev-female', '1');
      row.removeAttribute('data-nearby-jev-nonfemale');
      row.removeAttribute('data-nearby-jev-tail-probe');
    } else {
      row.setAttribute('data-nearby-jev-nonfemale', '1');
      row.removeAttribute('data-nearby-jev-female');
    }
  }

  function findScrollContainer(ctx) {
    const candidates = [ctx.root, ...ctx.root.querySelectorAll('div, ul')];
    let best = null;
    let bestHeight = 0;
    for (const el of candidates) {
      if (el === document.body || el === document.documentElement) continue;
      if (!isScrollableBox(el)) continue;
      const ch = el.clientHeight || 0;
      if (ch < 100) continue;
      const hasRow = !!el.querySelector('[data-nearby-jev-row], ' + USER_LINK_SELECTOR);
      const score = ch + (hasRow ? 10000 : 0);
      if (score > bestHeight) {
        bestHeight = score;
        best = el;
      }
    }
    if (best) return best;
    return ctx.isDialog ? ctx.root : (document.scrollingElement || document.documentElement);
  }

  function computeCounts(ctx) {
    if (!enabled || !ctx || !ctx.root) return { female: 0, hidden: 0, domFemale: 0 };
    const domFemale = ctx.root.querySelectorAll('[data-nearby-jev-female="1"]').length;
    const domHidden = ctx.root.querySelectorAll('[data-nearby-jev-nonfemale="1"]').length;
    let seenFemale = 0;
    let seenHidden = 0;
    for (const key of seenInContext) {
      const j = judged.get(key);
      if (!j) continue;
      if (j.isFemale) seenFemale++;
      else seenHidden++;
    }
    return {
      female: Math.max(domFemale, seenFemale),
      hidden: Math.max(domHidden, seenHidden),
      domFemale: domFemale
    };
  }

  function reportState(active, female, hidden, fetching) {
    const key = active + ':' + female + ':' + hidden + ':' + (fetching ? 1 : 0);
    if (key === lastReportedKey) return;
    lastReportedKey = key;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('nearbyFollowListState', {
        active: active,
        female: female,
        hidden: hidden,
        autoFetching: !!fetching
      }).catch(() => {});
    }
  }

  // 非表示によって画面内に余白ができた場合や下端付近までスクロールした場合、
  // IntersectionObserver と scroll リスナーの両方を確実に発火させて次ページを取得する
  function triggerPaginationPulse(ctx, scrollEl, femRows, allRows) {
    pulseInProgress = true;
    autoFetching = true;
    lastPulseAt = Date.now();
    const beforeSeen = seenInContext.size;
    const beforeSeq = apiBatchSeq;
    const counts = computeCounts(ctx);
    reportState(true, counts.female, counts.hidden, true);

    const anchorRow = femRows.length > 0 ? femRows[femRows.length - 1] : allRows[0];
    let spacer = document.getElementById('nearby-jev-spacer');
    if (!spacer) {
      spacer = document.createElement('div');
      spacer.id = 'nearby-jev-spacer';
      spacer.setAttribute('aria-hidden', 'true');
    }
    const pushPx = Math.max(1600, (window.innerHeight || 800) * 2);
    spacer.style.cssText =
      'display:block;width:1px;height:' + pushPx + 'px;flex-shrink:0;pointer-events:none;opacity:0;';

    try {
      if (anchorRow && anchorRow.parentNode) {
        anchorRow.after(spacer);
      } else {
        ctx.root.appendChild(spacer);
      }
    } catch (_) {}

    const raf = window.requestAnimationFrame || ((fn) => setTimeout(fn, 16));
    raf(() => {
      raf(() => {
        try {
          spacer.style.height = '0px';
          const tailRows = allRows.slice(-3);
          for (const r of tailRows) {
            if (r.getAttribute('data-nearby-jev-nonfemale') === '1') {
              r.setAttribute('data-nearby-jev-tail-probe', '1');
            }
          }

          const isDocScroll =
            scrollEl === document.scrollingElement ||
            scrollEl === document.documentElement ||
            scrollEl === document.body;
          if (!isDocScroll && scrollEl && femRows.length < MIN_VISIBLE_FEMALES) {
            const maxTop = Math.max(0, scrollEl.scrollHeight - scrollEl.clientHeight);
            if (maxTop > 0 && maxTop <= 240) {
              scrollEl.scrollTop = maxTop;
            }
          }

          if (scrollEl && scrollEl !== window) {
            scrollEl.dispatchEvent(new Event('scroll', { bubbles: true }));
          }
          ctx.root.dispatchEvent(new Event('scroll', { bubbles: true }));
          window.dispatchEvent(new Event('scroll'));

          setTimeout(() => {
            try {
              if (spacer.parentNode) spacer.parentNode.removeChild(spacer);
              for (const r of tailRows) r.removeAttribute('data-nearby-jev-tail-probe');
            } catch (_) {}
          }, 150);
        } catch (_) {}

        setTimeout(() => {
          pulseInProgress = false;
          const gotNewData = seenInContext.size > beforeSeen || apiBatchSeq > beforeSeq;
          if (gotNewData) {
            emptyPulseCount = 0;
          } else {
            emptyPulseCount++;
            if (emptyPulseCount >= MAX_EMPTY_PULSES) {
              reachedEnd = true;
              autoFetching = false;
            }
          }
          scheduleScan(20);
        }, 760);
      });
    });
  }

  function maybeAutoFetchNextPage(ctx) {
    if (!enabled || !ctx || !ctx.root) {
      autoFetching = false;
      return;
    }
    if (pulseInProgress) return;
    if (pendingQueue.size > 0 || inflight.size > 0) return;
    if (reachedEnd || apiHasMore === false) {
      autoFetching = false;
      return;
    }

    const allRows = [...ctx.root.querySelectorAll('[data-nearby-jev-row]')];
    if (allRows.length === 0 && seenInContext.size === 0) return;

    const femRows = allRows.filter((r) => r.getAttribute('data-nearby-jev-female') === '1');
    const scrollEl = findScrollContainer(ctx);
    const isDocScroll =
      scrollEl === document.scrollingElement ||
      scrollEl === document.documentElement ||
      scrollEl === document.body;

    const viewportBottom = isDocScroll
      ? (window.innerHeight || document.documentElement.clientHeight || 700)
      : scrollEl.getBoundingClientRect().bottom;

    let needsMore = false;
    if (femRows.length === 0) {
      needsMore = true;
    } else {
      const lastFemRect = femRows[femRows.length - 1].getBoundingClientRect();
      // 最後の女性行が画面内にあるか、画面下端から 180px 以内に迫っていれば次ページを先読みする
      if (viewportBottom - lastFemRect.bottom > -180) {
        needsMore = true;
      } else if (femRows.length < MIN_VISIBLE_FEMALES) {
        const viewH = isDocScroll ? viewportBottom : (scrollEl.clientHeight || 0);
        const scrollH = isDocScroll
          ? Math.max(scrollEl.scrollHeight || 0, document.body ? document.body.scrollHeight : 0)
          : (scrollEl.scrollHeight || 0);
        if (scrollH <= viewH + 100) needsMore = true;
      }
    }

    if (!needsMore) {
      autoFetching = false;
      return;
    }

    const elapsed = Date.now() - lastPulseAt;
    if (elapsed < PULSE_COOLDOWN_MS) {
      autoFetching = true;
      if (!cooldownTimer) {
        cooldownTimer = setTimeout(() => {
          cooldownTimer = null;
          scheduleScan(0);
        }, PULSE_COOLDOWN_MS - elapsed + 20);
      }
      return;
    }

    triggerPaginationPulse(ctx, scrollEl, femRows, allRows);
  }

  async function pumpQueue() {
    if (pumping || !enabled || pendingQueue.size === 0) return;
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
    pumping = true;
    try {
      while (enabled && pendingQueue.size > 0) {
        const batch = [];
        for (const item of pendingQueue.values()) {
          batch.push(item);
          if (batch.length >= 16) break;
        }
        for (const item of batch) {
          pendingQueue.delete(item.key);
          inflight.add(item.key);
        }

        let res = null;
        try {
          res = await window.flutter_inappwebview.callHandler(
            'nearbyCheckAccounts',
            batch.map((x) => ({ u: x.u, n: x.n, img: x.img, b64: x.b64, fmt: x.fmt, p: PLATFORM }))
          );
        } catch (_) {}

        const retryItems = [];
        for (const item of batch) {
          inflight.delete(item.key);
          if (res && typeof res === 'object' && Object.prototype.hasOwnProperty.call(res, item.u)) {
            const isFemale = !!res[item.u];
            const hasImg = !!(item.img || item.b64);
            judged.set(item.key, { isFemale: isFemale, hasImg: hasImg });
            failCounts.delete(item.key);
          } else if (enabled) {
            const fails = (failCounts.get(item.key) || 0) + 1;
            failCounts.set(item.key, fails);
            if (fails < 3) retryItems.push(item);
          }
        }

        syncDom();

        if (retryItems.length > 0 && enabled) {
          await new Promise((r) => setTimeout(r, 500));
          for (const item of retryItems) {
            if (!judged.has(item.key) && !pendingQueue.has(item.key)) {
              pendingQueue.set(item.key, item);
            }
          }
        }
      }
    } finally {
      pumping = false;
      syncDom();
    }
  }

  function syncDom() {
    applyRootClass();
    detectViewerUsername();
    const ctx = findFollowListContext();
    if (!ctx || !ctx.root) {
      if (activeContextKey !== '') resetPaginationState('');
      reportState(false, 0, 0, false);
      return;
    }
    if (ctx.key !== activeContextKey) {
      resetPaginationState(ctx.key);
    }

    reconcileMarkedRows(ctx);

    const byUser = new Map();
    const anchors = ctx.root.querySelectorAll(USER_LINK_SELECTOR);
    for (const a of anchors) {
      if (isSubtitleLink(a)) continue;
      const u = parseUsernameHref(a.getAttribute('href'));
      if (!u) continue;
      const uLower = u.toLowerCase();
      if (ctx.owner && uLower === ctx.owner) continue;
      let entry = byUser.get(uLower);
      if (!entry) {
        entry = { username: u, links: [] };
        byUser.set(uLower, entry);
      }
      entry.links.push(a);
    }

    for (const [uLower, entry] of byUser.entries()) {
      const row = findRowElement(entry.links, uLower, ctx);
      if (!row) continue;
      seenInContext.add(uLower);
      const cached = judged.get(uLower);
      if (cached !== undefined) {
        applyRowJudgment(row, cached.isFemale);
        if (enabled && !cached.hasImg) {
          const av = extractAvatar(row, uLower);
          if (av.url || av.b64) {
            const displayName = extractDisplayName(row, uLower);
            enqueueCandidate(entry.username, uLower, displayName, av.url, av.b64, av.fmt);
          }
        }
      } else if (enabled) {
        const displayName = extractDisplayName(row, uLower);
        const av = extractAvatar(row, uLower);
        row.setAttribute('data-nearby-jev-pending', '1');
        enqueueCandidate(entry.username, uLower, displayName, av.url, av.b64, av.fmt);
      } else {
        row.removeAttribute('data-nearby-jev-pending');
      }
    }

    if (enabled && pendingQueue.size > 0) {
      pumpQueue();
    } else {
      maybeAutoFetchNextPage(ctx);
    }

    const counts = computeCounts(ctx);
    reportState(true, counts.female, counts.hidden, autoFetching);
  }

  function scheduleScan(delay) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      syncDom();
    }, delay);
  }

  window.__nearbySetFemaleFilter = function(nextEnabled, resetJudged) {
    const prevEnabled = enabled;
    enabled = !!nextEnabled;
    failCounts.clear();
    if (resetJudged) {
      judged.clear();
      pendingQueue.clear();
      resetPaginationState('');
      document.querySelectorAll('[data-nearby-jev-female],[data-nearby-jev-nonfemale],[data-nearby-jev-pending],[data-nearby-jev-tail-probe]')
        .forEach((el) => {
          el.removeAttribute('data-nearby-jev-female');
          el.removeAttribute('data-nearby-jev-nonfemale');
          el.removeAttribute('data-nearby-jev-pending');
          el.removeAttribute('data-nearby-jev-tail-probe');
        });
    } else if (!enabled) {
      pendingQueue.clear();
      autoFetching = false;
      document.querySelectorAll('[data-nearby-jev-pending],[data-nearby-jev-tail-probe]')
        .forEach((el) => {
          el.removeAttribute('data-nearby-jev-pending');
          el.removeAttribute('data-nearby-jev-tail-probe');
        });
    } else if (!prevEnabled && enabled) {
      reachedEnd = false;
      emptyPulseCount = 0;
    }
    applyRootClass();
    scheduleScan(0);
  };

  function pullInitialConfig() {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('nearbyGetFilterConfig')
        .then((cfg) => {
          if (cfg && typeof cfg.enabled === 'boolean') {
            window.__nearbySetFemaleFilter(cfg.enabled, false);
          }
        })
        .catch(() => {});
    }
  }

  function startObservers() {
    if (observerStarted || !document.documentElement) return;
    observerStarted = true;
    const obs = new MutationObserver(() => scheduleScan(16));
    obs.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['href', 'src', 'aria-selected']
    });
    syncDom();
  }

  hookNetwork();
  startObservers();
  if (!observerStarted) {
    document.addEventListener('DOMContentLoaded', startObservers, { once: true });
    const waitRoot = setInterval(() => {
      if (document.documentElement) {
        clearInterval(waitRoot);
        startObservers();
      }
    }, 20);
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', pullInitialConfig);
  pullInitialConfig();
  window.addEventListener('popstate', () => scheduleScan(30));
  window.addEventListener('scroll', (ev) => {
    const now = Date.now();
    if (ev && ev.isTrusted && reachedEnd && apiHasMore !== false &&
        now - lastPulseAt > 1500 && now - lastUserScrollAt > 800) {
      reachedEnd = false;
      emptyPulseCount = Math.max(0, MAX_EMPTY_PULSES - 2);
    }
    if (!ev || ev.isTrusted) lastUserScrollAt = now;
    scheduleScan(16);
  }, { capture: true, passive: true });
  scheduleScan(50);
})();
''';

  void back() => _current.web?.goBack();
  void forward() => _current.web?.goForward();
  void reload() => _current.web?.reload();

  /// ログイン状態を含む Cookie を全て消す（保存済みの複数アカウントスロットも含めてログアウトする）。
  Future<void> clearLogin() async {
    await CookieManager.instance(webViewEnvironment: _environment).deleteAllCookies();
    await accounts.clearAllSavedSessions();
    for (final p in _panes.values) {
      await p.web?.webStorage.localStorage.clear();
      await p.web?.webStorage.sessionStorage.clear();
    }
    reload();
  }

  void _attachPane(SnsPaneKind kind, InAppWebViewController web) {
    final pane = _pane(kind);
    pane.web = web;
    pane.pendingUrl = null;
    accounts.attachCookieStore(WebViewCookieStore(environment: _environment));

    web.addJavaScriptHandler(
      handlerName: 'nearbyGetFilterConfig',
      callback: (_) => {'enabled': jev.isActive},
    );
    web.addJavaScriptHandler(
      handlerName: 'nearbyDetectedViewer',
      callback: (args) async {
        if (args.isEmpty || args.first is! Map) return null;
        final map = args.first as Map;
        final pStr = (map['p'] as String?) ?? '';
        final uStr = (map['u'] as String?) ?? '';
        final platform = pStr == 'tiktok' ? SnsPlatform.tiktok : SnsPlatform.instagram;
        if (uStr.isNotEmpty) {
          await accounts.updateDetectedViewer(platform, uStr);
          await accounts.captureActiveSlot(platform, storage: _storageCallbacksFor(platform));
        }
        return null;
      },
    );
    web.addJavaScriptHandler(
      handlerName: 'nearbyCheckAccounts',
      callback: (args) async {
        if (!jev.isActive || args.isEmpty || args.first is! List) return const <String, bool>{};
        final rawList = args.first as List;
        final defaultPlatform = kind == SnsPaneKind.tiktok ? 'tiktok' : 'instagram';
        final candidates = <InstagramAccountCandidate>[
          for (final item in rawList)
            if (item is Map && item['u'] is String)
              InstagramAccountCandidate(
                username: item['u'] as String,
                displayName: (item['n'] as String?) ?? '',
                avatarUrl: (item['img'] as String?) ?? '',
                avatarBase64: item['b64'] as String?,
                avatarFormat: item['fmt'] as String?,
                platform: (item['p'] as String?) ?? defaultPlatform,
              ),
        ];
        if (candidates.isEmpty) return const <String, bool>{};
        _activeJevRequests++;
        notifyListeners();
        try {
          return await jev.judgeFemaleAccounts(candidates);
        } finally {
          _activeJevRequests--;
          notifyListeners();
        }
      },
    );
    web.addJavaScriptHandler(
      handlerName: 'nearbyFollowListState',
      callback: (args) {
        if (args.isEmpty || args.first is! Map) return null;
        final map = args.first as Map;
        final nextActive = map['active'] == true;
        final nextFemale = (map['female'] as num?)?.toInt() ?? 0;
        final nextHidden = (map['hidden'] as num?)?.toInt() ?? 0;
        final nextAutoFetching = nextActive && map['autoFetching'] == true;
        if (pane.inFollowList != nextActive ||
            pane.visibleFemaleCount != nextFemale ||
            pane.hiddenAccountCount != nextHidden ||
            pane.autoFetchingMore != nextAutoFetching) {
          pane.inFollowList = nextActive;
          pane.visibleFemaleCount = nextFemale;
          pane.hiddenAccountCount = nextHidden;
          pane.autoFetchingMore = nextAutoFetching;
          notifyListeners();
        }
        return null;
      },
    );
  }

  void _updatePane(SnsPaneKind kind, {String? url, String? title, double? progress}) {
    final pane = _pane(kind);
    if (url != null) {
      pane.url = url;
      final link = parseSnsUrl(url);
      if (link != null && link.username != null) {
        unawaited(accounts.recordVisitedTarget(link.platform, link.username!));
      }
    }
    if (title != null) pane.title = title;
    if (progress != null) pane.progress = progress;
    notifyListeners();
  }

  Future<void> _updatePaneHistory(SnsPaneKind kind) async {
    final pane = _pane(kind);
    final web = pane.web;
    if (web == null) return;
    pane.canGoBack = await web.canGoBack();
    pane.canGoForward = await web.canGoForward();
    notifyListeners();
  }

  void _onPaneLoadCompleted(SnsPaneKind kind) {
    final pane = _pane(kind);
    if (kind == SnsPaneKind.instagram) {
      unawaited(_runPendingInstagramSearch(pane));
      if (!accounts.switching) {
        unawaited(accounts.captureActiveSlot(SnsPlatform.instagram, storage: _storageCallbacksFor(SnsPlatform.instagram)));
      }
    } else if (kind == SnsPaneKind.tiktok) {
      if (!accounts.switching) {
        unawaited(accounts.captureActiveSlot(SnsPlatform.tiktok, storage: _storageCallbacksFor(SnsPlatform.tiktok)));
      }
    }
    unawaited(_syncFemaleFilterToPane(pane));
  }
}

/// SNS を表示するアプリ内ブラウザ。
/// - Instagram と TikTok の画面を並列保持して 0 秒で切り替え
/// - ログイン中の複数アカウント（セッション）をワンタップで切り替え
/// - 周辺スポットや履歴の Instagram / TikTok アカウントを順送り・直接移動で高速切り替え
/// - Instagram・TikTok 両方のフォロー中・フォロワー一覧で Jev 女性アカウント抽出を利用可能
class SnsBrowser extends StatelessWidget {
  const SnsBrowser({
    super.key,
    required this.controller,
    this.expanded = false,
    this.onToggleExpanded,
    this.nearbyTargets = const [],
  });

  final SnsBrowserController controller;

  /// 地図などを隠して広げて表示しているか。
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  /// 現在の検索範囲内にあるスポットの Instagram / TikTok アカウント候補（順送り・クイック切替用）。
  final List<NearbySnsTarget> nearbyTargets;

  static const _homes = {
    SnsPlatform.instagram: 'https://www.instagram.com/',
    SnsPlatform.tiktok: 'https://www.tiktok.com/',
    SnsPlatform.x: 'https://x.com/home',
    SnsPlatform.facebook: 'https://www.facebook.com/',
    SnsPlatform.threads: 'https://www.threads.com/',
    SnsPlatform.youtube: 'https://www.youtube.com/',
  };

  static String homeUrlOf(SnsPlatform platform) => _homes[platform] ?? SnsBrowserController.homeUrl;

  /// いま開いているページの SNS（切り替えボタンのアイコンに使う）。
  static SnsPlatform? platformOf(String? url) {
    final host = Uri.tryParse(url ?? '')?.host;
    if (host == null || host.isEmpty) return null;
    for (final MapEntry(key: platform, value: home) in _homes.entries) {
      final domain = Uri.parse(home).host.replaceFirst('www.', '');
      if (host == domain || host.endsWith('.$domain')) return platform;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    if (!SnsBrowserController.supported) {
      return _Unsupported(onOpen: () => openExternal(c.url ?? SnsBrowserController.homeUrl));
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final curPlatform = c.activePlatform;
        final supportsJevAndSlots =
            curPlatform == SnsPlatform.instagram || curPlatform == SnsPlatform.tiktok;
        final switchableTargets = supportsJevAndSlots
            ? c.buildSwitchableTargets(curPlatform, nearbyTargets: nearbyTargets)
            : const <({SocialLink link, String? label})>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: scheme.surfaceContainer,
              child: LayoutBuilder(
                builder: (context, box) {
                  final wideBar = box.maxWidth >= 430;
                  final showReloadInBar = box.maxWidth >= 380;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '戻る',
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                          onPressed: c.canGoBack ? c.back : null,
                          icon: const Icon(Icons.arrow_back, size: 20),
                        ),
                        if (showReloadInBar)
                          IconButton(
                            tooltip: '再読み込み',
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                            onPressed: c.reload,
                            icon: const Icon(Icons.refresh, size: 20),
                          ),
                        _PlatformQuickSwitchPills(controller: c),
                        const SizedBox(width: 4),
                        if (wideBar && switchableTargets.length >= 2)
                          IconButton(
                            tooltip: '前の${curPlatform.label}アカウントへ切り替え',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
                            onPressed: () => c.stepTargetAccount(-1, nearbyTargets: nearbyTargets),
                            icon: const Icon(Icons.chevron_left, size: 20),
                          ),
                        Expanded(
                          child: _TargetAccountQuickButton(
                            controller: c,
                            onTap: () => showFastAccountSwitcherSheet(
                              context,
                              c,
                              nearbyTargets: nearbyTargets,
                            ),
                          ),
                        ),
                        if (wideBar && switchableTargets.length >= 2)
                          IconButton(
                            tooltip: '次の${curPlatform.label}アカウントへ切り替え',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
                            onPressed: () => c.stepTargetAccount(1, nearbyTargets: nearbyTargets),
                            icon: const Icon(Icons.chevron_right, size: 20),
                          ),
                        if (supportsJevAndSlots)
                          _LoginSlotSwitchButton(
                            controller: c,
                            platform: curPlatform,
                            onOpenManager: () => showFastAccountSwitcherSheet(
                              context,
                              c,
                              nearbyTargets: nearbyTargets,
                              initialSectionLogin: true,
                            ),
                          ),
                        if (supportsJevAndSlots)
                          _FemaleFilterToggleButton(
                            controller: c,
                            platform: curPlatform,
                            onOpenSettings: () => showJevSettingsDialog(context, c),
                          ),
                        if (onToggleExpanded case final toggle?)
                          IconButton(
                            tooltip: expanded ? '元の大きさに戻す' : '広げて表示',
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                            onPressed: toggle,
                            icon: Icon(expanded ? Icons.close_fullscreen : Icons.open_in_full, size: 20),
                          ),
                        PopupMenuButton<String>(
                          tooltip: 'メニュー・他SNS',
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                          onSelected: (v) async {
                            if (v.startsWith('sns:')) {
                              final name = v.substring(4);
                              final platform = SnsPlatform.values.asNameMap()[name];
                              if (platform != null) c.switchPlatform(platform);
                            } else if (v == 'reload') {
                              c.reload();
                            } else if (v == 'forward') {
                              c.forward();
                            } else if (v == 'accounts') {
                              await showFastAccountSwitcherSheet(
                                context,
                                c,
                                nearbyTargets: nearbyTargets,
                                initialSectionLogin: true,
                              );
                            } else if (v == 'jev') {
                              await showJevSettingsDialog(context, c);
                            } else if (v == 'external') {
                              openExternal(c.url ?? SnsBrowserController.homeUrl);
                            } else if (v == 'logout') {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('ログイン情報を消去'),
                                  content: const Text(
                                    'アプリ内ブラウザに保存されている全ての SNS のログイン状態・保存済みアカウントスロットを消去します。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('キャンセル'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('消去'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) await c.clearLogin();
                            }
                          },
                          itemBuilder: (context) => [
                            if (!showReloadInBar)
                              const PopupMenuItem(
                                value: 'reload',
                                child: ListTile(leading: Icon(Icons.refresh), title: Text('再読み込み')),
                              ),
                            PopupMenuItem(
                              value: 'forward',
                              enabled: c.canGoForward,
                              child: const ListTile(leading: Icon(Icons.arrow_forward), title: Text('進む')),
                            ),
                            const PopupMenuItem(
                              value: 'accounts',
                              child: ListTile(
                                leading: Icon(Icons.switch_account_outlined),
                                title: Text('Instagram / TikTok 高速アカウント切替'),
                                subtitle: Text('ログイン垢の切替・追加／閲覧先への即時移動'),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'jev',
                              child: ListTile(
                                leading: Icon(
                                  Icons.female,
                                  color: c.jev.isActive ? scheme.primary : null,
                                ),
                                title: const Text('Jev 女性アカウント表示・費用の確認'),
                                subtitle: Text(
                                  c.jev.hasApiKey
                                      ? '${c.jev.onlyFemaleAccounts ? 'ON' : 'OFF'} · 累計 ${JevService.formatCostCompact(c.jev.totalCostUsd)}'
                                      : 'API キー未設定（Instagram / TikTok 対応）',
                                ),
                              ),
                            ),
                            const PopupMenuDivider(),
                            for (final platform in _homes.keys)
                              PopupMenuItem(
                                value: 'sns:${platform.name}',
                                child: ListTile(
                                  leading: FaIcon(platform.icon, size: 18, color: platform.color),
                                  title: Text('${platform.label} を開く'),
                                ),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem(
                              value: 'external',
                              child: ListTile(leading: Icon(Icons.open_in_new), title: Text('外部のブラウザ・アプリで開く')),
                            ),
                            const PopupMenuItem(
                              value: 'logout',
                              child: ListTile(leading: Icon(Icons.logout), title: Text('ログイン情報を消去')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (supportsJevAndSlots && (c.jev.isActive || c.jev.totalApiCalls > 0))
              _JevUsageBar(
                controller: c,
                platform: curPlatform,
                onOpenSettings: () => showJevSettingsDialog(context, c),
              ),
            if (c.jev.onlyFemaleAccounts && c.jev.lastError != null)
              _JevErrorBanner(
                error: c.jev.lastError!,
                onOpenSettings: () => showJevSettingsDialog(context, c),
                onDismiss: () {
                  c.jev.lastError = null;
                  c.setOnlyFemaleAccounts(false);
                },
              ),
            if (c.searchQuery case final query? when c.searchStatus != InstagramSearchStatus.none)
              _SearchBanner(query: query, status: c.searchStatus, onClose: c.dismissSearch),
            SizedBox(height: 2, child: c.progress < 1 ? LinearProgressIndicator(value: c.progress) : null),
            Expanded(
              child: c.started
                  ? _MultiPaneWebViews(controller: c)
                  : _Intro(
                      onStartInstagram: () => c.switchPlatform(SnsPlatform.instagram),
                      onStartTikTok: () => c.switchPlatform(SnsPlatform.tiktok),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// ツールバー左側の「Instagram ⇄ TikTok」0秒ワンタップ切り替えピル。
class _PlatformQuickSwitchPills extends StatelessWidget {
  const _PlatformQuickSwitchPills({required this.controller});

  final SnsBrowserController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = controller.activePane;
    Widget pill({
      required SnsPlatform platform,
      required bool selected,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => controller.switchPlatform(platform),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? platform.color.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: FaIcon(
              platform.icon,
              size: 15,
              color: selected ? platform.color : scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill(
            platform: SnsPlatform.instagram,
            selected: active == SnsPaneKind.instagram,
            tooltip: 'Instagram へ即時切り替え（画面保持）',
          ),
          pill(
            platform: SnsPlatform.tiktok,
            selected: active == SnsPaneKind.tiktok,
            tooltip: 'TikTok へ即時切り替え（画面保持）',
          ),
        ],
      ),
    );
  }
}

/// ツールバー中央の現在ページ／閲覧中 `@username` 表示ボタン（タップで高速アカウント移動・検索シートを開く）。
class _TargetAccountQuickButton extends StatelessWidget {
  const _TargetAccountQuickButton({required this.controller, required this.onTap});

  final SnsBrowserController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final targetUser = controller.currentTargetUsername;
    final primaryText = targetUser != null
        ? '@$targetUser'
        : (controller.title?.trim().isNotEmpty == true ? controller.title! : controller.activePlatform.label);
    final secondaryText = controller.url != null ? (Uri.tryParse(controller.url!)?.host ?? controller.url!) : 'タップしてアカウント移動・検索';

    return Tooltip(
      message: 'タップしてアカウントを高速切り替え・@ID移動・検索',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      primaryText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(
                        fontWeight: targetUser != null ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.unfold_more, size: 14, color: scheme.onSurfaceVariant),
                ],
              ),
              Text(
                secondaryText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自分のログイン中 Instagram / TikTok アカウント（スロット）をワンタップで切り替えるボタン。
class _LoginSlotSwitchButton extends StatelessWidget {
  const _LoginSlotSwitchButton({
    required this.controller,
    required this.platform,
    required this.onOpenManager,
  });

  final SnsBrowserController controller;
  final SnsPlatform platform;
  final VoidCallback onOpenManager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final switcher = controller.accounts;
    final slots = switcher.slotsOf(platform);
    final activeSlot = switcher.activeSlotOf(platform);
    final activeIndex = switcher.activeSlotIndexOf(platform);
    final badgeText = activeSlot.username?.isNotEmpty == true
        ? '@${activeSlot.username}'
        : '垢${activeIndex + 1}';

    return PopupMenuButton<String>(
      tooltip: '${platform.label} のログインアカウントを切り替え（長押しで次の垢へ即切替）',
      onSelected: (value) async {
        if (value == '__add__') {
          await controller.addLoginSlot(platform);
        } else if (value == '__manage__') {
          onOpenManager();
        } else if (value.startsWith('slot:')) {
          await controller.switchLoginSlot(platform, value.substring(5));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text(
            '${platform.label} ログイン中の垢切替',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.primary),
          ),
        ),
        for (final slot in slots)
          PopupMenuItem<String>(
            value: 'slot:${slot.id}',
            child: Row(
              children: [
                Icon(
                  slot.id == activeSlot.id ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: slot.id == activeSlot.id ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    slot.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: slot.id == activeSlot.id ? FontWeight.w700 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__add__',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            title: Text('${platform.label} の別アカウントを追加'),
          ),
        ),
        const PopupMenuItem<String>(
          value: '__manage__',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.manage_accounts_outlined, size: 18),
            title: Text('アカウント切替・履歴パネルを開く'),
          ),
        ),
      ],
      child: GestureDetector(
        onLongPress: slots.length >= 2 ? () => controller.cycleLoginSlot(platform) : onOpenManager,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 88),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: slots.length >= 2 ? scheme.secondaryContainer.withValues(alpha: 0.7) : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (switcher.switching)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                  )
                else
                  Icon(Icons.switch_account_outlined, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    badgeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: slots.length >= 2 ? FontWeight.w600 : FontWeight.normal,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ツールバーの「女性のみ」ワンタップ切り替えボタン（Instagram・TikTok 両対応 / 長押しで Jev 設定・費用を開く）。
class _FemaleFilterToggleButton extends StatelessWidget {
  const _FemaleFilterToggleButton({
    required this.controller,
    required this.platform,
    required this.onOpenSettings,
  });

  final SnsBrowserController controller;
  final SnsPlatform platform;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final active = c.jev.isActive;
    final label = switch ((active, c.inFollowList, c.visibleFemaleCount)) {
      (true, true, final f) => '女性 $f件',
      _ => '女性のみ',
    };
    return Tooltip(
      message: c.jev.hasApiKey
          ? '${platform.label} のフォロー中・フォロワーで女性アカウントのみ表示（タップで切替 / 長押しで設定・費用確認）'
          : 'Jev API キーを設定して ${platform.label} で女性アカウントのみ表示する',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (!c.jev.hasApiKey) {
              onOpenSettings();
            } else {
              c.setOnlyFemaleAccounts(!c.jev.onlyFemaleAccounts);
            }
          },
          onLongPress: onOpenSettings,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: active ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: active ? scheme.primary : scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.checkingAccounts || c.autoFetchingMore)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                  )
                else
                  Icon(
                    Icons.female,
                    size: 16,
                    color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ブラウザ上部に常時表示する Jev の稼働状況・掛かった費用バー（Instagram / TikTok 共通）。
class _JevUsageBar extends StatelessWidget {
  const _JevUsageBar({
    required this.controller,
    required this.platform,
    required this.onOpenSettings,
  });

  final SnsBrowserController controller;
  final SnsPlatform platform;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final jev = c.jev;
    final costLabel = JevService.formatCostCompact(jev.totalCostUsd);
    final extraStatus = c.checkingAccounts
        ? '（判定中…）'
        : (c.autoFetchingMore ? '（次ページ取得中…）' : '');
    final statusText = c.inFollowList && jev.isActive
        ? '${platform.label} 女性表示 ${c.visibleFemaleCount}件 / 非表示 ${c.hiddenAccountCount}件$extraStatus · Jev費用 $costLabel'
        : 'Jev ${jev.isActive ? '女性のみ表示ON（Instagram・TikTok アイコン＋名前判定）' : 'OFF'} · 費用 $costLabel';
    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: onOpenSettings,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            children: [
              Icon(Icons.payments_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '設定',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JevErrorBanner extends StatelessWidget {
  const _JevErrorBanner({required this.error, required this.onOpenSettings, required this.onDismiss});

  final String error;
  final VoidCallback onOpenSettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onOpenSettings, child: const Text('設定')),
            IconButton(
              tooltip: 'オフにする',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

/// Instagram・TikTok の「ログイン垢切替」と「閲覧先アカウントの高速移動・検索」をまとめたシートを開く。
Future<void> showFastAccountSwitcherSheet(
  BuildContext context,
  SnsBrowserController controller, {
  List<NearbySnsTarget> nearbyTargets = const [],
  bool initialSectionLogin = false,
}) async {
  await controller.accounts.ensureLoaded();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FastAccountSwitcherSheet(
      controller: controller,
      nearbyTargets: nearbyTargets,
      initialSectionLogin: initialSectionLogin,
    ),
  );
}

class _FastAccountSwitcherSheet extends StatefulWidget {
  const _FastAccountSwitcherSheet({
    required this.controller,
    required this.nearbyTargets,
    required this.initialSectionLogin,
  });

  final SnsBrowserController controller;
  final List<NearbySnsTarget> nearbyTargets;
  final bool initialSectionLogin;

  @override
  State<_FastAccountSwitcherSheet> createState() => _FastAccountSwitcherSheetState();
}

class _FastAccountSwitcherSheetState extends State<_FastAccountSwitcherSheet> {
  late SnsPlatform _platform = widget.controller.activePlatform == SnsPlatform.tiktok
      ? SnsPlatform.tiktok
      : SnsPlatform.instagram;
  final TextEditingController _jumpInput = TextEditingController();

  @override
  void dispose() {
    _jumpInput.dispose();
    super.dispose();
  }

  void _openDirectHandle() {
    final q = _jumpInput.text.trim();
    if (q.isEmpty) return;
    Navigator.pop(context);
    widget.controller.openUsername(_platform, q);
  }

  void _searchKeyword() {
    final q = _jumpInput.text.trim();
    if (q.isEmpty) return;
    Navigator.pop(context);
    widget.controller.searchSns(_platform, q);
  }

  Future<void> _promptRenameSlot(SnsAccountSlot slot) async {
    final input = TextEditingController(text: slot.label);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウント表示名の変更'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '表示名（例: メイン垢、サブ垢）',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('保存')),
        ],
      ),
    );
    if (next != null && next.trim().isNotEmpty) {
      await widget.controller.accounts.renameSlot(_platform, slot.id, next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = widget.controller;
    final switcher = c.accounts;

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final slots = switcher.slotsOf(_platform);
        final activeSlot = switcher.activeSlotOf(_platform);
        final recents = switcher.recentTargetsOf(_platform);
        final spotTargets = [
          for (final item in widget.nearbyTargets)
            if (item.link.platform == _platform && item.link.username != null) item,
        ];

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.82),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('高速アカウント切り替え', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          SegmentedButton<SnsPlatform>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            segments: [
                              ButtonSegment(
                                value: SnsPlatform.instagram,
                                icon: FaIcon(SnsPlatform.instagram.icon, size: 14),
                                label: const Text('Instagram'),
                              ),
                              ButtonSegment(
                                value: SnsPlatform.tiktok,
                                icon: FaIcon(SnsPlatform.tiktok.icon, size: 14),
                                label: const Text('TikTok'),
                              ),
                            ],
                            selected: {_platform},
                            onSelectionChanged: (s) {
                              final next = s.first;
                              setState(() => _platform = next);
                              c.switchPlatform(next);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 1. 自分のログイン中アカウント切り替えセクション
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.switch_account, size: 18, color: scheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${_platform.label} のログインアカウント（自分用）',
                                  style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                onPressed: switcher.switching
                                    ? null
                                    : () async {
                                        Navigator.pop(context);
                                        await c.addLoginSlot(_platform);
                                      },
                                icon: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                                label: const Text('別垢を追加'),
                              ),
                            ],
                          ),
                          Text(
                            '複数のアカウントにログインしておくと、再ログイン不要・ワンタップで即座にセッションを切り替えられます。',
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          for (final slot in slots)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Material(
                                color: slot.id == activeSlot.id
                                    ? scheme.primaryContainer.withValues(alpha: 0.7)
                                    : scheme.surface,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: switcher.switching
                                      ? null
                                      : () async {
                                          Navigator.pop(context);
                                          await c.switchLoginSlot(_platform, slot.id);
                                        },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    child: Row(
                                      children: [
                                        Icon(
                                          slot.id == activeSlot.id
                                              ? Icons.check_circle
                                              : Icons.radio_button_unchecked,
                                          size: 18,
                                          color: slot.id == activeSlot.id ? scheme.primary : scheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                slot.displayTitle,
                                                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                              ),
                                              Text(
                                                slot.id == activeSlot.id
                                                    ? '現在使用中'
                                                    : (slot.hasSavedSession ? 'ログイン保存済み（タップで即時切替）' : '未ログイン（タップしてログイン）'),
                                                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '表示名を変更',
                                          visualDensity: VisualDensity.compact,
                                          iconSize: 18,
                                          onPressed: () => _promptRenameSlot(slot),
                                          icon: const Icon(Icons.edit_outlined),
                                        ),
                                        if (slots.length > 1)
                                          IconButton(
                                            tooltip: 'このスロットを削除',
                                            visualDensity: VisualDensity.compact,
                                            iconSize: 18,
                                            onPressed: () => c.deleteLoginSlot(_platform, slot.id),
                                            icon: Icon(Icons.delete_outline, color: scheme.error),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 2. 閲覧先アカウントへのダイレクト移動・高速検索
                    Text(
                      '${_platform.label} の閲覧先アカウントへ高速移動・検索',
                      style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _jumpInput,
                            textInputAction: TextInputAction.go,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '@ユーザー名 または 検索ワード',
                              prefixIcon: const Icon(Icons.alternate_email, size: 18),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onSubmitted: (v) {
                              if (v.trim().startsWith('@') || !v.trim().contains(' ')) {
                                _openDirectHandle();
                              } else {
                                _searchKeyword();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: _openDirectHandle,
                          child: const Text('@ID開く'),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: _searchKeyword,
                          child: const Text('検索'),
                        ),
                      ],
                    ),
                    if (spotTargets.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        '周辺の地図スポット（${spotTargets.length}件）',
                        style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final item in spotTargets.take(24))
                            ActionChip(
                              visualDensity: VisualDensity.compact,
                              avatar: FaIcon(_platform.icon, size: 13, color: _platform.color),
                              label: Text(
                                '${item.placeName} (${item.link.handle})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                c.open(item.link.url, label: item.placeName);
                              },
                            ),
                        ],
                      ),
                    ],
                    if (recents.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'ピン留め・最近開いた ${_platform.label} アカウント',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: () => switcher.clearRecentTargets(_platform),
                            child: const Text('履歴を整理'),
                          ),
                        ],
                      ),
                      for (final t in recents.take(15))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: FaIcon(_platform.icon, size: 16, color: _platform.color),
                          title: Text(
                            t.label != null ? '${t.label} (${t.handle})' : t.handle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: t.pinned ? 'ピン留めを解除' : '上部にピン留め',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              t.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                              size: 18,
                              color: t.pinned ? scheme.primary : scheme.onSurfaceVariant,
                            ),
                            onPressed: () => switcher.togglePinTarget(_platform, t.username),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            c.open(t.url, label: t.label);
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Jev（TypeSafe AI System One）の女性アカウントのみ表示設定と掛かった費用の確認ダイアログ。
Future<void> showJevSettingsDialog(BuildContext context, SnsBrowserController controller) async {
  await controller.jev.ensureLoaded();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _JevSettingsDialog(controller: controller),
  );
}

class _JevSettingsDialog extends StatefulWidget {
  const _JevSettingsDialog({required this.controller});

  final SnsBrowserController controller;

  @override
  State<_JevSettingsDialog> createState() => _JevSettingsDialogState();
}

class _JevSettingsDialogState extends State<_JevSettingsDialog> {
  late final TextEditingController _keyInput = TextEditingController(text: widget.controller.jev.apiKey);
  late bool _femaleOnlyEnabled =
      widget.controller.jev.hasApiKey ? widget.controller.jev.onlyFemaleAccounts : true;
  late double _threshold = widget.controller.jev.threshold;
  bool _obscure = true;
  bool _testing = false;
  ({bool ok, String message})? _testResult;

  @override
  void dispose() {
    _keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final jev = widget.controller.jev;
    return ListenableBuilder(
      listenable: jev,
      builder: (context, _) => AlertDialog(
        title: const Text('Jev 女性アカウントのみ表示'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Instagram や TikTok で「フォロー中」「フォロワー」一覧を開いたとき、アカウントのアイコン画像と'
                  'アカウント名・表示名を Jev（TypeSafe AI System One）に渡して判定し、'
                  '女性個人のアカウントのみを表示します（男性・店舗・企業・性別不明アカウントを非表示）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.payments_outlined, size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Text('Jev に掛かった費用', style: Theme.of(context).textTheme.labelLarge),
                          const Spacer(),
                          if (jev.totalApiCalls > 0)
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: const Size(0, 26),
                              ),
                              onPressed: () async {
                                await jev.resetUsageStats();
                              },
                              child: const Text('費用をリセット'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '累計: ${JevService.formatCostCompact(jev.totalCostUsd)}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '今回の起動中: ${JevService.formatCostCompact(jev.sessionCostUsd)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '通信 ${jev.totalApiCalls}回 · 判定 ${jev.totalJudgedAccounts}件 · '
                        '入力 ${jev.totalInputTokens} tok（単価 \$0.042 / 100万tok・出力無料・判定済みキャッシュは \$0）',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('女性アカウントのみを表示する'),
                  subtitle: const Text('Instagram・TikTok のアイコン画像＋名前から女性個人アカウントを抽出'),
                  value: _femaleOnlyEnabled,
                  onChanged: (v) => setState(() => _femaleOnlyEnabled = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _keyInput,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'TypeSafe API キー',
                    hintText: 'Bearer トークンを入力',
                    helperText: 'この端末内にのみ保存され、外部や GitHub には送信・公開されません',
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '表示' : '隠す',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('女性判定のしきい値: ${(_threshold * 100).round()}%',
                        style: Theme.of(context).textTheme.labelMedium),
                    const Spacer(),
                    Text(
                      _threshold <= 0.48 ? '広めに表示' : (_threshold >= 0.70 ? '確実な女性のみ' : '標準'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                Slider(
                  value: _threshold.clamp(0.40, 0.85),
                  min: 0.40,
                  max: 0.85,
                  divisions: 9,
                  label: '${(_threshold * 100).round()}%',
                  onChanged: (v) => setState(() => _threshold = v),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing
                          ? null
                          : () async {
                              setState(() {
                                _testing = true;
                                _testResult = null;
                              });
                              final res = await jev.testConnection(_keyInput.text);
                              if (mounted) {
                                setState(() {
                                  _testing = false;
                                  _testResult = res;
                                });
                              }
                            },
                      icon: _testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('接続テスト'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await jev.clearCache();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('判定キャッシュを消去しました')));
                        }
                      },
                      child: const Text('判定履歴を消去'),
                    ),
                  ],
                ),
                if (_testResult case final r?) ...[
                  const SizedBox(height: 8),
                  Text(
                    r.message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: r.ok ? scheme.primary : scheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(
            onPressed: () async {
              final trimmed = _keyInput.text.trim();
              await jev.updateSettings(
                apiKey: trimmed,
                onlyFemaleAccounts: _femaleOnlyEnabled && trimmed.isNotEmpty,
                threshold: _threshold,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// Instagram・TikTok・その他 SNS の各 WebView を `IndexedStack` で並列保持するウィジェット。
class _MultiPaneWebViews extends StatelessWidget {
  const _MultiPaneWebViews({required this.controller});

  final SnsBrowserController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final panes = SnsPaneKind.values;
    return IndexedStack(
      index: panes.indexOf(c.activePane),
      sizing: StackFit.expand,
      children: [
        for (final kind in panes)
          c.isPaneStarted(kind)
              ? _SinglePaneWebView(key: ValueKey('sns_pane_${kind.name}'), controller: c, kind: kind)
              : const SizedBox.shrink(),
      ],
    );
  }
}

class _SinglePaneWebView extends StatelessWidget {
  const _SinglePaneWebView({super.key, required this.controller, required this.kind});

  final SnsBrowserController controller;
  final SnsPaneKind kind;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return InAppWebView(
      webViewEnvironment: SnsBrowserController._environment,
      initialUrlRequest: URLRequest(url: WebUri(c.paneInitialUrl(kind)!)),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: SnsBrowserController.followerFilterScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: SnsBrowserController.followerFilterScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        thirdPartyCookiesEnabled: true,
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: true,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (web) => c._attachPane(kind, web),
      // instagram:// や snssdk1180:// や intent:// など外部アプリを呼び出すリンクはキャンセル・必要に応じ外部起動
      shouldOverrideUrlLoading: (web, action) async {
        final uri = action.request.url;
        if (uri == null || uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'about') {
          return NavigationActionPolicy.ALLOW;
        }
        // TikTok Web が自動で飛ばす snssdk* / tiktok:// ディープリンクは WebView 内閲覧を妨げないよう抑止する
        final schemeLower = uri.scheme.toLowerCase();
        final isTikTokAutoScheme = schemeLower.startsWith('snssdk') || schemeLower == 'tiktok' || schemeLower == 'musically';
        if (!isTikTokAutoScheme &&
            schemeLower != 'intent' &&
            schemeLower != 'javascript' &&
            schemeLower != 'data') {
          openExternal(uri.toString()).ignore();
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStart: (web, url) => c._updatePane(kind, url: url?.toString()),
      onProgressChanged: (web, progress) {
        c._updatePane(kind, progress: progress / 100);
        // 画像などの読み込み完了（onLoadStop）を待たず、DOM が出始めた段階で Instagram 検索入力を開始する
        final pane = c._pane(kind);
        if (kind == SnsPaneKind.instagram && progress >= 45 && pane.pendingSearch != null) {
          c._runPendingInstagramSearch(pane);
        }
      },
      onTitleChanged: (web, title) => c._updatePane(kind, title: title),
      onUpdateVisitedHistory: (web, url, isReload) {
        c._updatePane(kind, url: url?.toString());
        c._updatePaneHistory(kind);
        c._onPaneLoadCompleted(kind);
      },
      onLoadStop: (web, url) {
        c._updatePane(kind, url: url?.toString(), progress: 1);
        c._updatePaneHistory(kind);
        c._onPaneLoadCompleted(kind);
      },
    );
  }
}

/// アカウント検索の状況。検索欄に入力できなかったときは、検索する言葉をコピーできるようにする。
class _SearchBanner extends StatelessWidget {
  const _SearchBanner({required this.query, required this.status, required this.onClose});

  final String query;
  final InstagramSearchStatus status;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = status == InstagramSearchStatus.failed;
    final message = switch (status) {
      InstagramSearchStatus.waitingForLogin => 'ログインすると「$query」のアカウントを検索します',
      InstagramSearchStatus.failed => '検索欄に入力できませんでした。「$query」をコピーして検索欄に貼り付けてください',
      _ => '「$query」のアカウントを検索しています…',
    };
    return Material(
      color: failed ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: failed ? scheme.onErrorContainer : scheme.onSecondaryContainer),
              ),
            ),
            if (failed)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: query));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('「$query」をコピーしました')));
                  }
                },
                child: const Text('コピー'),
              ),
            IconButton(
              tooltip: '閉じる',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.onStartInstagram, required this.onStartTikTok});

  final VoidCallback onStartInstagram;
  final VoidCallback onStartTikTok;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const FaIcon(FontAwesomeIcons.instagram, size: 38, color: Color(0xFFDD2A7B)),
                const SizedBox(width: 16),
                FaIcon(FontAwesomeIcons.tiktok, size: 36, color: Theme.of(context).colorScheme.onSurface),
              ],
            ),
            const SizedBox(height: 12),
            Text('アプリ内で SNS を高速切り替え', style: text.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '地図上のスポットからアカウントを選ぶと、ここで開きます。\n'
              'Instagram と TikTok は画面を並列保持して 0 秒で切り替えでき、複数のログインアカウントもワンタップで切り替えられます。\n'
              'パスワードは各 SNS のログイン画面に直接入力され、このアプリには保存されません。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onStartInstagram,
                  icon: const FaIcon(FontAwesomeIcons.instagram, size: 18),
                  label: const Text('Instagram を開く'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onStartTikTok,
                  icon: const FaIcon(FontAwesomeIcons.tiktok, size: 16),
                  label: const Text('TikTok を開く'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off_outlined, size: 40),
            const SizedBox(height: 12),
            const Text(
              'この端末ではアプリ内ブラウザを使えません。\n'
              'Windows の場合は「Microsoft Edge WebView2 ランタイム」をインストールしてください。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onOpen, child: const Text('外部のブラウザで開く')),
          ],
        ),
      ),
    );
  }
}
