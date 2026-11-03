import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/social.dart';
import '../services/jev_service.dart';
import '../widgets/place_widgets.dart';

/// Instagram のアカウント検索で、検索欄に自動で入力できたか。
enum InstagramSearchStatus { none, waitingForLogin, searching, failed }

/// アプリ内の SNS ブラウザの状態。地図や一覧からアカウントを開くときにも使う。
///
/// Instagram などへのログインは SNS 自身のログイン画面で行い、アプリはパスワードを扱わない。
/// ログイン状態（Cookie）は WebView のデータとして端末に残るので、次回起動時もログインしたまま使える。
class SnsBrowserController extends ChangeNotifier {
  SnsBrowserController({JevService? jev})
      : _ownsJev = jev == null,
        jev = jev ?? JevService() {
    this.jev.addListener(_onJevChanged);
    unawaited(this.jev.ensureLoaded());
  }

  static const homeUrl = 'https://www.instagram.com/';

  /// Instagram のアカウント検索の画面。ログインしていなければ、ログインした後にこの画面に戻る。
  static const searchUrl = 'https://www.instagram.com/explore/search/';

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
  final JevService jev;

  InAppWebViewController? _web;
  String? _pending;

  /// ページを読み込んだら Instagram の検索欄に入れる言葉。[_searchId] は検索し直すたびに増やす。
  String? _pendingSearch;
  int _searchId = 0;
  int _runningSearchId = 0;

  /// 最後に Instagram で検索した言葉と、検索欄に入力できたか（画面上部の案内に使う）。
  String? searchQuery;
  InstagramSearchStatus searchStatus = InstagramSearchStatus.none;

  /// Instagram のフォロー中・フォロワー一覧を開いているかと、非表示にした男性アカウント件数。
  bool inFollowList = false;
  int hiddenMaleCount = 0;
  int _activeJevRequests = 0;
  double _lastAppliedThreshold = JevService.defaultThreshold;

  bool get checkingMaleAccounts => _activeJevRequests > 0;

  String? url;
  String? title;
  double progress = 1;
  bool canGoBack = false;
  bool canGoForward = false;

  /// 一度でも開いたか（[warmUp] または [open] / [searchInstagram] で WebView を起動する）。
  bool started = false;

  @override
  void dispose() {
    jev.removeListener(_onJevChanged);
    if (_ownsJev) jev.dispose();
    super.dispose();
  }

  void _onJevChanged() {
    final thresholdChanged = (_lastAppliedThreshold - jev.threshold).abs() > 0.0001;
    _lastAppliedThreshold = jev.threshold;
    unawaited(_syncMaleFilterToWebView(resetJudged: thresholdChanged));
    notifyListeners();
  }

  Future<void> setHideMaleAccounts(bool enabled) async {
    await jev.updateSettings(hideMaleAccounts: enabled);
  }

  Future<void> _syncMaleFilterToWebView({bool resetJudged = false}) async {
    final web = _web;
    if (web == null) return;
    final current = Uri.tryParse(url ?? '');
    if (!_isInstagramHost(current)) return;
    try {
      await web.evaluateJavascript(
        source: '''
        $followerFilterScript
        if (window.__nearbySetMaleFilter) {
          window.__nearbySetMaleFilter(${jev.isActive}, $resetJudged);
        }
        ''',
      );
    } catch (_) {}
  }

  /// 初回の Instagram アカウント検索でも待たずに切り替えられるよう、裏で検索画面を読み込んでおく。
  void warmUp() {
    if (started || !supported) return;
    started = true;
    _pending = searchUrl;
    notifyListeners();
  }

  /// [target] を開く。まだ WebView がなければ作られたときに開く。
  void open(String target) {
    _pendingSearch = null; // ほかのページを開いたら、ログイン後などに検索するのはやめる
    _searchId++;
    searchStatus = InstagramSearchStatus.none;
    _load(target);
  }

  void _load(String target) {
    started = true;
    url = target;
    if (_web case final web?) {
      web.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } else {
      _pending = target;
    }
    notifyListeners();
  }

  static bool _isInstagramHost(Uri? uri) =>
      uri != null && (uri.host == 'instagram.com' || uri.host.endsWith('.instagram.com'));

  static bool _isInstagramLoginPath(Uri uri) =>
      uri.path.startsWith('/accounts/') || uri.path.startsWith('/challenge/');

  /// Instagram で [query] のアカウントを検索する。
  /// すでに Instagram のページが開いていればページ全体の再読み込みは行わず、その場で検索欄を開いて即時入力する。
  void searchInstagram(String query) {
    _pendingSearch = query;
    _searchId++;
    searchQuery = query;

    final current = Uri.tryParse(url ?? '');
    if (_web != null && _isInstagramHost(current)) {
      if (_isInstagramLoginPath(current!)) {
        searchStatus = InstagramSearchStatus.waitingForLogin;
        notifyListeners();
        return;
      }
      searchStatus = InstagramSearchStatus.searching;
      notifyListeners();
      unawaited(_runPendingSearch());
      return;
    }

    searchStatus = InstagramSearchStatus.searching;
    _load(searchUrl);
  }

  void dismissSearch() {
    searchStatus = InstagramSearchStatus.none;
    notifyListeners();
  }

  void _setSearchStatus(InstagramSearchStatus status) {
    if (searchStatus == status) return;
    searchStatus = status;
    notifyListeners();
  }

  Future<void> _runPendingSearch() async {
    final query = _pendingSearch;
    final id = _searchId;
    final web = _web;
    if (query == null || web == null || _runningSearchId == id) return;
    final current = Uri.tryParse(url ?? '');
    if (!_isInstagramHost(current)) return;
    if (_isInstagramLoginPath(current!)) {
      // ログイン画面。ログインすると検索画面に戻るので、そのときに入力する
      _setSearchStatus(InstagramSearchStatus.waitingForLogin);
      return;
    }
    _runningSearchId = id;
    _setSearchStatus(InstagramSearchStatus.searching);
    String? result;
    try {
      final value = await web
          .callAsyncJavaScript(functionBody: _searchScript, arguments: {'query': query, 'seq': id})
          .timeout(const Duration(seconds: 15));
      result = value?.value as String?;
    } catch (e) {
      debugPrint('Instagram の検索欄に入力できませんでした: $e');
    } finally {
      if (_runningSearchId == id) _runningSearchId = 0;
    }
    if (id != _searchId) {
      // より新しい検索に切り替え済み
      return;
    }
    switch (result) {
      case 'done':
        _pendingSearch = null;
        _setSearchStatus(InstagramSearchStatus.none);
      case 'login':
        // トップページのログイン欄。ログインしてページが移ったら入力する
        _setSearchStatus(InstagramSearchStatus.waitingForLogin);
      case 'moved' || 'superseded':
        break; // 検索画面に移るので、読み込み次第入力する
      case 'failed':
        _pendingSearch = null;
        _setSearchStatus(InstagramSearchStatus.failed);
      default:
        // 入力中にページが移ったときなど。次にページを読み込んだときにもう一度試す
        if (progress >= 1) _setSearchStatus(InstagramSearchStatus.failed);
    }
  }

  /// 検索欄に [query] を高速で入れる。
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

  /// Instagram で「フォロー中」「フォロワー」を開いたときにアカウント行を検出し、
  /// Jev で男性名と判定されたアカウントを非表示にするスクリプト。
  static const followerFilterScript = r'''
(function() {
  if (!location.hostname || !location.hostname.endsWith('instagram.com')) return;
  if (window.__nearbyJevInstalled) return;
  window.__nearbyJevInstalled = true;

  const RESERVED = new Set([
    'explore', 'direct', 'reels', 'stories', 'accounts', 'p', 'reel', 'tv',
    'about', 'legal', 'privacy', 'terms', 'session', 'challenge', 'oauth',
    'graphql', 'api', 'nametag', 'directory', 'topics', 'web'
  ]);
  const IGNORE_TEXT = /^(フォロー|フォロー中|フォローバック|フォローする|削除|メッセージ|リクエスト済み|ブロック|制限する|親しい友達|共通|認証済み|新しいフォロワー|すべて見る|おすすめ|Follow|Following|Follow Back|Remove|Message|Requested|Verified|New|See All|Suggested|•|・|\s*)$/i;
  const IGNORE_SUB = /(がフォロー中|Followed by|フォロワー\s*[\d,.万kKmM]+|フォロー中\s*[\d,.万kKmM]+|件の投稿)/i;
  const FOLLOW_HEADER = /^(フォロワー|フォロー中|共通のフォロワー|Followers|Following|Mutual)(\s*[\d,.万kKmM人]+)?$/i;

  const judged = new Map();
  const inflight = new Set();
  let enabled = false;
  let timer = null;
  let lastReportedKey = '';

  function ensureStyle() {
    if (document.getElementById('nearby-jev-style')) return;
    const style = document.createElement('style');
    style.id = 'nearby-jev-style';
    style.textContent = 'html.nearby-jev-hide-male [data-nearby-jev-male="1"] { display: none !important; }';
    (document.head || document.documentElement).appendChild(style);
  }

  function applyRootClass() {
    ensureStyle();
    if (document.documentElement) {
      document.documentElement.classList.toggle('nearby-jev-hide-male', !!enabled);
    }
  }

  function parseUsernameHref(href) {
    if (!href) return null;
    const m = /^\/([A-Za-z0-9._]{1,30})\/?(?:\?.*)?$/.exec(href.trim());
    if (!m) return null;
    const u = m[1];
    if (RESERVED.has(u.toLowerCase())) return null;
    return u;
  }

  function findFollowListContext() {
    const pathMatch = /^\/([^/]+)\/(followers|following)(\/|$)/i.exec(location.pathname || '');
    const pathOwner = pathMatch && !RESERVED.has(pathMatch[1].toLowerCase()) ? pathMatch[1].toLowerCase() : null;

    const dialogs = [...document.querySelectorAll('[role="dialog"]')].filter((d) => {
      const r = d.getBoundingClientRect();
      return r.width > 140 && r.height > 140;
    });
    for (let i = dialogs.length - 1; i >= 0; i--) {
      const d = dialogs[i];
      const dRect = d.getBoundingClientRect();
      const headers = d.querySelectorAll('h1, h2, [role="heading"], header, div, span');
      let matchedHeader = false;
      for (const h of headers) {
        if (h.children.length > 2) continue;
        const hr = h.getBoundingClientRect();
        if (hr.top - dRect.top > 110) continue;
        const t = (h.textContent || '').trim();
        if (t && t.length <= 24 && FOLLOW_HEADER.test(t)) {
          matchedHeader = true;
          break;
        }
      }
      if (matchedHeader || pathOwner) {
        return { root: d, owner: pathOwner, isDialog: true };
      }
    }

    if (pathOwner) {
      return { root: document.querySelector('main') || document.body, owner: pathOwner, isDialog: false };
    }
    return null;
  }

  function isPrimaryUserLink(a, otherLower) {
    if (a.querySelector('img, canvas, svg')) return true;
    const t = (a.textContent || '').trim().toLowerCase().replace(/^@/, '');
    return t === otherLower || t.startsWith(otherLower + '\n') || t.startsWith(otherLower + ' ');
  }

  function findRowElement(links, uLower, ctx) {
    for (const a of links) {
      const marked = a.closest('[data-nearby-jev-row]');
      if (marked && ctx.root.contains(marked)) return marked;
    }
    const anchor = links.find((a) => (a.textContent || '').toLowerCase().includes(uLower)) || links[0];
    if (!anchor) return null;
    if (!ctx.isDialog && anchor.closest('header, nav')) return null;

    let cur = anchor;
    while (cur.parentElement && cur.parentElement !== ctx.root) {
      const parent = cur.parentElement;
      if (!ctx.isDialog && (parent.tagName === 'HEADER' || parent.tagName === 'NAV')) break;
      const curH = cur.getBoundingClientRect().height;
      const parH = parent.getBoundingClientRect().height;
      if (parH > 145 && curH >= 36) break;

      let hasOtherUser = false;
      const pLinks = parent.querySelectorAll('a[href^="/"]');
      for (const pa of pLinks) {
        const ou = parseUsernameHref(pa.getAttribute('href'));
        if (!ou) continue;
        const oLower = ou.toLowerCase();
        if (oLower !== uLower && isPrimaryUserLink(pa, oLower)) {
          hasOtherUser = true;
          break;
        }
      }
      if (hasOtherUser) break;
      cur = parent;
    }

    const r = cur.getBoundingClientRect();
    if (r.height > 0 && (r.height < 32 || r.height > 160)) return null;
    cur.setAttribute('data-nearby-jev-row', uLower);
    return cur;
  }

  function extractDisplayName(row, uLower) {
    const nodes = row.querySelectorAll('span, div');
    for (const el of nodes) {
      if (el.closest('button, [role="button"]')) continue;
      if (el.querySelector('span, div, button, a, ul')) continue;
      const t = (el.textContent || '').replace(/\s+/g, ' ').trim();
      if (!t || t.length > 60) continue;
      const tl = t.toLowerCase();
      if (tl === uLower || tl === '@' + uLower) continue;
      if (IGNORE_TEXT.test(t) || IGNORE_SUB.test(t)) continue;
      return t;
    }
    return '';
  }

  function reportState(active, hidden) {
    const key = active + ':' + hidden;
    if (key === lastReportedKey) return;
    lastReportedKey = key;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('nearbyFollowListState', { active: active, hidden: hidden }).catch(() => {});
    }
  }

  async function scan() {
    applyRootClass();
    const ctx = findFollowListContext();
    if (!ctx || !ctx.root) {
      reportState(false, 0);
      return;
    }

    const byUser = new Map();
    const anchors = ctx.root.querySelectorAll('a[href^="/"]');
    for (const a of anchors) {
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

    const toCheck = [];
    const rowsByUser = new Map();

    for (const [uLower, entry] of byUser.entries()) {
      const row = findRowElement(entry.links, uLower, ctx);
      if (!row) continue;
      rowsByUser.set(uLower, row);
      if (judged.has(uLower)) {
        if (judged.get(uLower)) {
          row.setAttribute('data-nearby-jev-male', '1');
        } else {
          row.removeAttribute('data-nearby-jev-male');
        }
      } else if (enabled && !inflight.has(uLower)) {
        const displayName = extractDisplayName(row, uLower);
        toCheck.push({ u: entry.username, key: uLower, n: displayName });
      }
    }

    const countHidden = () => enabled ? ctx.root.querySelectorAll('[data-nearby-jev-male="1"]').length : 0;
    reportState(true, countHidden());

    if (!enabled || toCheck.length === 0) return;
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;

    const batch = toCheck.slice(0, 30);
    for (const item of batch) inflight.add(item.key);
    try {
      const res = await window.flutter_inappwebview.callHandler(
        'nearbyCheckAccounts',
        batch.map((x) => ({ u: x.u, n: x.n }))
      );
      if (res && typeof res === 'object') {
        for (const item of batch) {
          if (Object.prototype.hasOwnProperty.call(res, item.u)) {
            const isMale = !!res[item.u];
            judged.set(item.key, isMale);
            const row = rowsByUser.get(item.key) || ctx.root.querySelector('[data-nearby-jev-row="' + item.key + '"]');
            if (row) {
              if (isMale) row.setAttribute('data-nearby-jev-male', '1');
              else row.removeAttribute('data-nearby-jev-male');
            }
          }
        }
      }
    } catch (_) {
    } finally {
      for (const item of batch) inflight.delete(item.key);
    }
    reportState(true, countHidden());
    if (toCheck.length > batch.length) scheduleScan(80);
  }

  function scheduleScan(delay) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      scan();
    }, delay);
  }

  window.__nearbySetMaleFilter = function(nextEnabled, resetJudged) {
    enabled = !!nextEnabled;
    if (resetJudged) {
      judged.clear();
      document.querySelectorAll('[data-nearby-jev-male]').forEach((el) => el.removeAttribute('data-nearby-jev-male'));
    }
    applyRootClass();
    scheduleScan(20);
  };

  const obs = new MutationObserver(() => scheduleScan(160));
  obs.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('popstate', () => scheduleScan(100));
  scheduleScan(100);
})();
''';

  void back() => _web?.goBack();
  void forward() => _web?.goForward();
  void reload() => _web?.reload();

  /// ログイン状態を含む Cookie を消す（全ての SNS からログアウトする）。
  Future<void> clearLogin() async {
    await CookieManager.instance(webViewEnvironment: _environment).deleteAllCookies();
    await _web?.webStorage.localStorage.clear();
    await _web?.webStorage.sessionStorage.clear();
    reload();
  }

  void _attach(InAppWebViewController web) {
    _web = web;
    _pending = null; // initialUrlRequest で開いている
    web.addJavaScriptHandler(
      handlerName: 'nearbyCheckAccounts',
      callback: (args) async {
        if (!jev.isActive || args.isEmpty || args.first is! List) return const <String, bool>{};
        final rawList = args.first as List;
        final candidates = <InstagramAccountCandidate>[
          for (final item in rawList)
            if (item is Map && item['u'] is String)
              InstagramAccountCandidate(
                username: item['u'] as String,
                displayName: (item['n'] as String?) ?? '',
              ),
        ];
        if (candidates.isEmpty) return const <String, bool>{};
        _activeJevRequests++;
        notifyListeners();
        try {
          return await jev.judgeMaleAccounts(candidates);
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
        final nextHidden = (map['hidden'] as num?)?.toInt() ?? 0;
        if (inFollowList != nextActive || hiddenMaleCount != nextHidden) {
          inFollowList = nextActive;
          hiddenMaleCount = nextHidden;
          notifyListeners();
        }
        return null;
      },
    );
  }

  void _update({String? url, String? title, double? progress}) {
    if (url != null) this.url = url;
    if (title != null) this.title = title;
    if (progress != null) this.progress = progress;
    notifyListeners();
  }

  Future<void> _updateHistory() async {
    final web = _web;
    if (web == null) return;
    canGoBack = await web.canGoBack();
    canGoForward = await web.canGoForward();
    notifyListeners();
  }
}

/// SNS を表示するアプリ内ブラウザ。上部のメニューで各 SNS のトップページを開ける。
/// ページを広く表示できるように、操作ボタンは 1 行にまとめる。
class SnsBrowser extends StatelessWidget {
  const SnsBrowser({super.key, required this.controller, this.expanded = false, this.onToggleExpanded});

  final SnsBrowserController controller;

  /// 地図などを隠して広げて表示しているか。
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  static const _homes = {
    SnsPlatform.instagram: 'https://www.instagram.com/',
    SnsPlatform.x: 'https://x.com/home',
    SnsPlatform.facebook: 'https://www.facebook.com/',
    SnsPlatform.tiktok: 'https://www.tiktok.com/',
    SnsPlatform.threads: 'https://www.threads.com/',
    SnsPlatform.youtube: 'https://www.youtube.com/',
  };

  /// いま開いているページの SNS（切り替えボタンのアイコンに使う）。
  static SnsPlatform? _platformOf(String? url) {
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
    final text = Theme.of(context).textTheme;
    final c = controller;
    if (!SnsBrowserController.supported) {
      return _Unsupported(onOpen: () => openExternal(c.url ?? SnsBrowserController.homeUrl));
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final onInstagram = _platformOf(c.url) == SnsPlatform.instagram || c.url == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: scheme.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '戻る',
                      visualDensity: VisualDensity.compact,
                      onPressed: c.canGoBack ? c.back : null,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    IconButton(
                      tooltip: '再読み込み',
                      visualDensity: VisualDensity.compact,
                      onPressed: c.reload,
                      icon: const Icon(Icons.refresh),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(c.title ?? 'SNS', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelLarge),
                          if (c.url case final url?)
                            Text(Uri.tryParse(url)?.host ?? url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (onInstagram)
                      _MaleFilterToggleButton(
                        controller: c,
                        onOpenSettings: () => showJevSettingsDialog(context, c),
                      ),
                    PopupMenuButton<SnsPlatform>(
                      tooltip: 'SNS を切り替え',
                      icon: FaIcon(_platformOf(c.url)?.icon ?? FontAwesomeIcons.globe, size: 18),
                      onSelected: (platform) => c.open(_homes[platform]!),
                      itemBuilder: (context) => [
                        for (final platform in _homes.keys)
                          PopupMenuItem(
                            value: platform,
                            child: ListTile(
                              leading: FaIcon(platform.icon, size: 18, color: platform.color),
                              title: Text(platform.label),
                            ),
                          ),
                      ],
                    ),
                    if (onToggleExpanded case final toggle?)
                      IconButton(
                        tooltip: expanded ? '元の大きさに戻す' : '広げて表示',
                        visualDensity: VisualDensity.compact,
                        onPressed: toggle,
                        icon: Icon(expanded ? Icons.close_fullscreen : Icons.open_in_full),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'メニュー',
                      onSelected: (v) async {
                        if (v == 'forward') {
                          c.forward();
                        } else if (v == 'jev') {
                          await showJevSettingsDialog(context, c);
                        } else if (v == 'external') {
                          openExternal(c.url ?? SnsBrowserController.homeUrl);
                        } else if (v == 'logout') {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('ログイン情報を消去'),
                              content: const Text('アプリ内ブラウザに保存されている全ての SNS のログイン状態を消去します。'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('消去')),
                              ],
                            ),
                          );
                          if (ok == true) await c.clearLogin();
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'forward',
                          enabled: c.canGoForward,
                          child: const ListTile(leading: Icon(Icons.arrow_forward), title: Text('進む')),
                        ),
                        PopupMenuItem(
                          value: 'jev',
                          child: ListTile(
                            leading: Icon(
                              Icons.person_off_outlined,
                              color: c.jev.isActive ? scheme.primary : null,
                            ),
                            title: const Text('Jev 男性アカウント非表示の設定'),
                            subtitle: Text(c.jev.hasApiKey ? (c.jev.hideMaleAccounts ? 'ON' : 'OFF') : 'API キー未設定'),
                          ),
                        ),
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
              ),
            ),
            if (c.jev.hideMaleAccounts && c.jev.lastError != null)
              _JevErrorBanner(
                error: c.jev.lastError!,
                onOpenSettings: () => showJevSettingsDialog(context, c),
                onDismiss: () {
                  c.jev.lastError = null;
                  c.setHideMaleAccounts(false);
                },
              ),
            if (c.searchQuery case final query? when c.searchStatus != InstagramSearchStatus.none)
              _SearchBanner(query: query, status: c.searchStatus, onClose: c.dismissSearch),
            SizedBox(height: 2, child: c.progress < 1 ? LinearProgressIndicator(value: c.progress) : null),
            Expanded(
              child: c.started ? _WebView(controller: c) : _Intro(onStart: () => c.open(SnsBrowserController.homeUrl)),
            ),
          ],
        );
      },
    );
  }
}

/// ツールバーの「男性非表示」ワンタップ切り替えボタン（長押しで Jev 設定を開く）。
class _MaleFilterToggleButton extends StatelessWidget {
  const _MaleFilterToggleButton({required this.controller, required this.onOpenSettings});

  final SnsBrowserController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final active = c.jev.isActive;
    final label = switch ((active, c.inFollowList, c.hiddenMaleCount)) {
      (true, true, final n) when n > 0 => '男性 -$n',
      (true, _, _) => '男性非表示',
      _ => '男性非表示',
    };
    return Tooltip(
      message: c.jev.hasApiKey
          ? 'フォロー中・フォロワーの男性アカウント非表示（タップで切替 / 長押しで設定）'
          : 'Jev API キーを設定して男性アカウントを非表示にする',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (!c.jev.hasApiKey) {
              onOpenSettings();
            } else {
              c.setHideMaleAccounts(!c.jev.hideMaleAccounts);
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
                if (c.checkingMaleAccounts)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                  )
                else
                  Icon(
                    active ? Icons.person_off : Icons.person_off_outlined,
                    size: 15,
                    color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 4),
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

/// Jev（TypeSafe AI System One）の API キーと男性アカウント非表示の設定ダイアログ。
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
  late bool _hideEnabled = widget.controller.jev.hasApiKey ? widget.controller.jev.hideMaleAccounts : true;
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
    return AlertDialog(
      title: const Text('Jev 男性アカウント非表示'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Instagram で「フォロー中」「フォロワー」を開いたとき、Jev（TypeSafe AI System One）で'
                'アカウント名・表示名が男性と判定された個人アカウントを自動で非表示にします。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('男性アカウントを非表示にする'),
                value: _hideEnabled,
                onChanged: (v) => setState(() => _hideEnabled = v),
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
                  Text('判定のしきい値: ${(_threshold * 100).round()}%',
                      style: Theme.of(context).textTheme.labelMedium),
                  const Spacer(),
                  Text(
                    _threshold <= 0.58 ? '広めに非表示' : (_threshold >= 0.74 ? '確実なもののみ' : '標準'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              Slider(
                value: _threshold.clamp(0.50, 0.85),
                min: 0.50,
                max: 0.85,
                divisions: 7,
                label: '${(_threshold * 100).round()}%',
                onChanged: (v) => setState(() => _threshold = v),
              ),
              Row(
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
                  const SizedBox(width: 8),
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
              hideMaleAccounts: _hideEnabled && trimmed.isNotEmpty,
              threshold: _threshold,
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _WebView extends StatelessWidget {
  const _WebView({required this.controller});

  final SnsBrowserController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return InAppWebView(
      webViewEnvironment: SnsBrowserController._environment,
      // 画面の幅が変わって作り直したときは、開いていたページを開き直す
      initialUrlRequest: URLRequest(url: WebUri(c._pending ?? c.url ?? SnsBrowserController.homeUrl)),
      initialUserScripts: UnmodifiableListView([
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
      onWebViewCreated: c._attach,
      // instagram:// や intent:// などアプリを呼び出すリンクは外部で開く
      shouldOverrideUrlLoading: (web, action) async {
        final uri = action.request.url;
        if (uri == null || uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'about') {
          return NavigationActionPolicy.ALLOW;
        }
        if (uri.scheme != 'intent' && uri.scheme != 'javascript' && uri.scheme != 'data') {
          openExternal(uri.toString()).ignore();
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStart: (web, url) => c._update(url: url?.toString()),
      onProgressChanged: (web, progress) {
        c._update(progress: progress / 100);
        // 画像などの読み込み完了（onLoadStop）を待たず、DOM が出始めた段階で検索入力を開始する
        if (progress >= 45 && c._pendingSearch != null) {
          c._runPendingSearch();
        }
      },
      onTitleChanged: (web, title) => c._update(title: title),
      onUpdateVisitedHistory: (web, url, isReload) {
        c.url = url?.toString();
        c._updateHistory();
        // Instagram はログイン後にページを読み込み直さずに移ることがあるので、URL が変わったときにも検索・非表示判定を同期する
        c._runPendingSearch();
        c._syncMaleFilterToWebView();
      },
      onLoadStop: (web, url) {
        c.progress = 1;
        c._updateHistory();
        c._runPendingSearch();
        c._syncMaleFilterToWebView();
      },
    );
  }
}

/// Instagram のアカウント検索の状況。検索欄に入力できなかったときは、検索する言葉をコピーできるようにする。
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
  const _Intro({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaIcon(FontAwesomeIcons.instagram, size: 40, color: Color(0xFFDD2A7B)),
            const SizedBox(height: 12),
            Text('アプリ内で SNS を使う', style: text.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '一覧や地図のアカウントを選ぶと、ここで開きます。\n'
              'Instagram などに一度ログインすると、次回からもログインしたまま使えます。\n'
              'パスワードは各 SNS のログイン画面に直接入力され、このアプリには保存されません。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onStart,
              icon: const FaIcon(FontAwesomeIcons.instagram, size: 18),
              label: const Text('Instagram を開く'),
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
