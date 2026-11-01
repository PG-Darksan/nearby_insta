import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/social.dart';
import '../widgets/place_widgets.dart';

/// Instagram のアカウント検索で、検索欄に自動で入力できたか。
enum InstagramSearchStatus { none, waitingForLogin, searching, failed }

/// アプリ内の SNS ブラウザの状態。地図や一覧からアカウントを開くときにも使う。
///
/// Instagram などへのログインは SNS 自身のログイン画面で行い、アプリはパスワードを扱わない。
/// ログイン状態（Cookie）は WebView のデータとして端末に残るので、次回起動時もログインしたまま使える。
class SnsBrowserController extends ChangeNotifier {
  static const homeUrl = 'https://www.instagram.com/';

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

  InAppWebViewController? _web;
  String? _pending;

  /// ページを読み込んだら Instagram の検索欄に入れる言葉。[_searchId] は検索し直すたびに増やす。
  String? _pendingSearch;
  int _searchId = 0;
  bool _searching = false;

  /// 最後に Instagram で検索した言葉と、検索欄に入力できたか（画面上部の案内に使う）。
  String? searchQuery;
  InstagramSearchStatus searchStatus = InstagramSearchStatus.none;

  String? url;
  String? title;
  double progress = 1;
  bool canGoBack = false;
  bool canGoForward = false;

  /// 一度でも開いたか（開くまでは WebView を作らない）。
  bool started = false;

  /// [target] を開く。まだ WebView がなければ作られたときに開く。
  void open(String target) {
    _pendingSearch = null; // ほかのページを開いたら、ログイン後などに検索するのはやめる
    _searchId++;
    searchStatus = InstagramSearchStatus.none;
    _load(target);
  }

  void _load(String target) {
    started = true;
    if (_web case final web?) {
      web.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } else {
      _pending = target;
    }
    notifyListeners();
  }

  /// Instagram のアカウント検索の画面。ログインしていなければ、ログインした後にこの画面に戻る。
  static const searchUrl = 'https://www.instagram.com/explore/search/';

  /// Instagram で [query] のアカウントを検索する。Web 版の Instagram には検索結果を開く URL がないので、
  /// 検索画面を開いてから検索欄に入力する。ログインしていなければ、ログインした後に入力する。
  void searchInstagram(String query) {
    _pendingSearch = query;
    _searchId++;
    searchQuery = query;
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
    if (query == null || web == null || _searching) return;
    final current = Uri.tryParse(url ?? '');
    if (current == null || !current.host.endsWith('instagram.com')) return;
    if (current.path.startsWith('/accounts/') || current.path.startsWith('/challenge/')) {
      // ログイン画面。ログインすると検索画面に戻るので、そのときに入力する
      _setSearchStatus(InstagramSearchStatus.waitingForLogin);
      return;
    }
    _searching = true;
    _setSearchStatus(InstagramSearchStatus.searching);
    String? result;
    try {
      final value = await web
          .callAsyncJavaScript(functionBody: _searchScript, arguments: {'query': query})
          .timeout(const Duration(seconds: 20));
      result = value?.value as String?;
    } catch (e) {
      debugPrint('Instagram の検索欄に入力できませんでした: $e');
    } finally {
      _searching = false;
    }
    if (id != _searchId) {
      // 入力している間に検索し直した。読み込み終わったときの呼び出しは入力中で飛ばしているので、ここで入力する
      await _runPendingSearch();
      return;
    }
    switch (result) {
      case 'done':
        _pendingSearch = null;
        _setSearchStatus(InstagramSearchStatus.none);
      case 'login':
        // トップページのログイン欄。ログインしてページが移ったら入力する
        _setSearchStatus(InstagramSearchStatus.waitingForLogin);
      case 'moved':
        break; // 検索画面に移るので、読み込み終わったら入力する
      case 'failed':
        _pendingSearch = null;
        _setSearchStatus(InstagramSearchStatus.failed);
      default:
        // 入力中にページが移ったときなど。次にページを読み込んだときにもう一度試す
        _setSearchStatus(InstagramSearchStatus.failed);
    }
  }

  /// 検索欄に [query] を入れる。検索欄がなければ、PC 向けの表示ではサイドバーの「検索」を押し、
  /// それでも出なければ検索画面に移る（'moved'）。ログインしていなければ 'login' を返す。
  /// Instagram の入力欄（React）はキー入力と同じイベントでないと値の変化に気づかないので、insertText で入力する。
  static const _searchScript = r'''
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const visible = (el) => el.getClientRects().length > 0;
const findInput = () => [...document.querySelectorAll('input')].find((input) =>
  (input.type === 'text' || input.type === 'search') && visible(input) &&
  /検索|search/i.test((input.getAttribute('aria-label') || '') + ' ' + (input.placeholder || '')));
let clicked = false;
for (let i = 0; i < 60; i++) {
  if ([...document.querySelectorAll('input[type="password"]')].some(visible)) return 'login';
  const input = findInput();
  if (input) {
    input.focus();
    input.select();
    if (!document.execCommand('insertText', false, query) || input.value !== query) {
      const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setValue.call(input, query);
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
    return input.value === query ? 'done' : 'failed';
  }
  if (!clicked && i >= 8) {
    const icon = [...document.querySelectorAll('svg[aria-label]')].find((svg) =>
      /^(検索|Search)$/.test(svg.getAttribute('aria-label')));
    const button = icon && icon.closest('a, [role="button"], [role="link"]');
    if (button) {
      button.click();
      clicked = true;
    }
  }
  if (i === 20 && !location.pathname.startsWith('/explore/search')) {
    setTimeout(() => location.assign('/explore/search/'), 300);
    return 'moved';
  }
  await sleep(250);
}
return 'failed';
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
      builder: (context, _) => Column(
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
                      } else if (v == 'external') {
                        openExternal(c.url ?? SnsBrowserController.homeUrl);
                      } else if (v == 'logout') {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('ログイン情報を消去'),
                            content: const Text('アプリ内ブラウザに保存されている全ての SNS のログイン状態を消去します。'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
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
          if (c.searchQuery case final query? when c.searchStatus != InstagramSearchStatus.none)
            _SearchBanner(query: query, status: c.searchStatus, onClose: c.dismissSearch),
          SizedBox(height: 2, child: c.progress < 1 ? LinearProgressIndicator(value: c.progress) : null),
          Expanded(
            child: c.started ? _WebView(controller: c) : _Intro(onStart: () => c.open(SnsBrowserController.homeUrl)),
          ),
        ],
      ),
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
      onProgressChanged: (web, progress) => c._update(progress: progress / 100),
      onTitleChanged: (web, title) => c._update(title: title),
      onUpdateVisitedHistory: (web, url, isReload) {
        c.url = url?.toString();
        c._updateHistory();
        // Instagram はログイン後にページを読み込み直さずに移ることがあるので、URL が変わったときにも検索する
        c._runPendingSearch();
      },
      onLoadStop: (web, url) {
        c.progress = 1;
        c._updateHistory();
        c._runPendingSearch();
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
