import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/social.dart';
import '../widgets/place_widgets.dart';

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

  String? url;
  String? title;
  double progress = 1;
  bool canGoBack = false;
  bool canGoForward = false;

  /// 一度でも開いたか（開くまでは WebView を作らない）。
  bool started = false;

  /// [target] を開く。まだ WebView がなければ作られたときに開く。
  void open(String target) {
    started = true;
    if (_web case final web?) {
      web.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } else {
      _pending = target;
    }
    notifyListeners();
  }

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

/// SNS を表示するアプリ内ブラウザ。上部のボタンで各 SNS のトップページを開ける。
class SnsBrowser extends StatelessWidget {
  const SnsBrowser({super.key, required this.controller});

  final SnsBrowserController controller;

  static const _homes = {
    SnsPlatform.instagram: 'https://www.instagram.com/',
    SnsPlatform.x: 'https://x.com/home',
    SnsPlatform.facebook: 'https://www.facebook.com/',
    SnsPlatform.tiktok: 'https://www.tiktok.com/',
    SnsPlatform.threads: 'https://www.threads.com/',
    SnsPlatform.youtube: 'https://www.youtube.com/',
  };

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
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '戻る',
                    onPressed: c.canGoBack ? c.back : null,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: '進む',
                    onPressed: c.canGoForward ? c.forward : null,
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  IconButton(tooltip: '再読み込み', onPressed: c.reload, icon: const Icon(Icons.refresh)),
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
                  PopupMenuButton<String>(
                    tooltip: 'メニュー',
                    onSelected: (v) async {
                      if (v == 'external') {
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
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'external',
                        child: ListTile(leading: Icon(Icons.open_in_new), title: Text('外部のブラウザ・アプリで開く')),
                      ),
                      PopupMenuItem(
                        value: 'logout',
                        child: ListTile(leading: Icon(Icons.logout), title: Text('ログイン情報を消去')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                for (final MapEntry(key: platform, value: url) in _homes.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: FaIcon(platform.icon, size: 14, color: platform.color),
                      label: Text(platform.label),
                      onPressed: () => c.open(url),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 2,
            child: c.progress < 1 ? LinearProgressIndicator(value: c.progress) : null,
          ),
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
      initialUrlRequest: URLRequest(url: WebUri(c._pending ?? SnsBrowserController.homeUrl)),
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
      },
      onLoadStop: (web, url) {
        c.progress = 1;
        c._updateHistory();
      },
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
