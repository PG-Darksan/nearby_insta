import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/nearby_controller.dart';
import '../models/listing.dart';
import '../models/place.dart';
import '../services/location_service.dart';
import '../services/search_history.dart';
import '../widgets/listing_dialog.dart';
import '../widgets/place_widgets.dart';
import '../widgets/search_filters.dart';
import 'sns_browser.dart';

enum _MapAction { search, addListing }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// これより狭い画面（スマホ）では地図と SNS をタブで切り替える。
  static const _wideBreakpoint = 840.0;

  /// 地図に描くマーカーの上限（多すぎると地図の操作が重くなる）。
  static const _maxMarkers = 600;

  final _controller = NearbyController();
  final _browser = SnsBrowserController();
  final _map = MapController();
  final _placeQuery = TextEditingController();
  Timer? _warmUpTimer;
  bool _mapReady = false;
  LatLng? _fittedCenter;
  int? _fittedRadius;

  /// スマホ: 0 地図 / 1 SNS。
  int _tab = 0;

  /// SNS を広げて表示しているか（PC は地図を、スマホは下のタブを隠す）。
  bool _browserExpanded = false;

  /// 地図をタップして指定した、まだ検索していない地点。
  LatLng? _pickedPoint;

  bool get _wide => MediaQuery.sizeOf(context).width >= _wideBreakpoint;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _controller.init();
    // 最初の Instagram アカウント検索でも待たずに切り替えられるよう、初期描画のあとに裏で検索画面を準備する
    if (SnsBrowserController.supported) {
      _warmUpTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) _browser.warmUp();
      });
    }
  }

  @override
  void dispose() {
    _warmUpTimer?.cancel();
    _controller.dispose();
    _browser.dispose();
    _placeQuery.dispose();
    super.dispose();
  }

  /// 現在地が変わったときと検索範囲が変わったときに地図を追従させる。
  /// 地図上で指定した地点はユーザーが見ている場所なので動かさない。
  void _onControllerChanged() {
    final c = _controller;
    if (c.center == null) return;
    final located = c.center != _fittedCenter && c.source != LocationSource.manual;
    if (located || c.radius != _fittedRadius) _fitToSearchArea();
  }

  /// SNS のページをアプリ内ブラウザで開く（使えない端末では外部のブラウザで）。
  void _openLink(String url, {String? label}) {
    if (!SnsBrowserController.supported) {
      openExternal(url);
      return;
    }
    _browser.open(url, label: label);
    if (!_wide) setState(() => _tab = 1);
  }

  /// Instagram で [query] のアカウントを検索する（アプリ内ブラウザが使えなければ Google で探す）。
  void _searchInstagram(String query) {
    if (!SnsBrowserController.supported) {
      openExternal('https://www.google.com/search?q=${Uri.encodeQueryComponent('site:instagram.com $query')}');
      return;
    }
    _browser.searchInstagram(query);
    if (!_wide) setState(() => _tab = 1);
  }

  /// TikTok で [query] のアカウントを検索する（アプリ内ブラウザが使えなければ外部ブラウザで開く）。
  void _searchTikTok(String query) {
    if (!SnsBrowserController.supported) {
      openExternal('https://www.tiktok.com/search/user?q=${Uri.encodeQueryComponent(query)}');
      return;
    }
    _browser.searchTikTok(query);
    if (!_wide) setState(() => _tab = 1);
  }

  List<NearbySnsTarget> _collectNearbySnsTargets() {
    final out = <NearbySnsTarget>[];
    for (final p in _controller.visiblePlaces) {
      for (final l in p.sortedLinks) {
        if ((l.platform == SnsPlatform.instagram || l.platform == SnsPlatform.tiktok) && l.username != null) {
          out.add((link: l, placeName: p.name));
        }
      }
    }
    return out;
  }

  void _stepSelectedPlace(int delta) {
    final places = _controller.visiblePlaces;
    if (places.length < 2) return;
    final curIdx = places.indexWhere((p) => p.id == _controller.selectedId);
    final nextIdx = curIdx < 0 ? 0 : (curIdx + delta) % places.length;
    final chosen = places[nextIdx < 0 ? nextIdx + places.length : nextIdx];
    _controller.select(chosen.id);
    if (_mapReady) {
      _map.move(chosen.position, math.max(_map.camera.zoom, 15));
    }
  }

  void _toggleHidden(Place place, bool hidden) {
    _controller.setHidden(place, hidden);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    if (hidden) {
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text('「${place.name}」を地図から非表示にしました'),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () => _controller.setHidden(place, false),
          ),
        ),
      );
    }
  }

  void _relocate() {
    _fittedCenter = null;
    _controller.locate();
  }

  /// 検索範囲の円がちょうど収まるように地図を合わせる。
  void _fitToSearchArea() {
    final center = _controller.center;
    if (!_mapReady || center == null) return;
    _fittedCenter = center;
    _fittedRadius = _controller.radius;
    final dLat = _controller.radius / 111320;
    final dLon = _controller.radius / (111320 * math.cos(center.latitude * math.pi / 180));
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(
        LatLng(center.latitude - dLat, center.longitude - dLon),
        LatLng(center.latitude + dLat, center.longitude + dLon),
      ),
      padding: const EdgeInsets.all(24),
    ));
  }

  /// 指定した地点を検索し、地図をその範囲に合わせる。
  void _searchAt(LatLng point, {String? name, int? radius}) {
    setState(() {
      _pickedPoint = null;
      if (!_wide) _tab = 0;
    });
    _controller.setCenter(point, name: name, radius: radius);
    _fitToSearchArea();
  }

  void _selectFromMap(Place place) {
    setState(() => _pickedPoint = null);
    _controller.select(place.id);
  }

  void _onMapTap(TapPosition tap, LatLng point) {
    // 場所を選んでいるときのタップは選択の解除だけにする
    if (_controller.selectedId != null) {
      _controller.select(null);
      return;
    }
    setState(() => _pickedPoint = _pickedPoint == null ? point : null);
  }

  Future<void> _showMapMenu(TapPosition tap, LatLng point) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_MapAction>(
      context: context,
      position: RelativeRect.fromRect(tap.global & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          value: _MapAction.search,
          child: ListTile(leading: Icon(Icons.travel_explore), title: Text('この地点で検索')),
        ),
        PopupMenuItem(
          value: _MapAction.addListing,
          child: ListTile(leading: Icon(Icons.add_location_alt_outlined), title: Text('ここに募集情報を登録')),
        ),
      ],
    );
    switch (action) {
      case _MapAction.search:
        _searchAt(point);
      case _MapAction.addListing:
        await _addListing(point);
      case null:
        break;
    }
  }

  Future<void> _searchPlaceName(String query) async {
    if (query.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final results = await _controller.geocoding.search(query);
    if (!mounted) return;
    if (results.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('「$query」は見つかりませんでした')));
      return;
    }
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('「$query」の検索結果'),
        children: [
          for (final (i, r) in results.indexed)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: Text(r.title),
                subtitle: r.subtitle == null
                    ? null
                    : Text(r.subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) _searchAt(results[chosen].position, name: results[chosen].title);
  }

  Future<void> _openPlaceSearchDialog() async {
    final query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('地名・住所で探す'),
        content: TextField(
          controller: _placeQuery,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例: 横浜駅、渋谷区神南1丁目'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, _placeQuery.text), child: const Text('検索')),
        ],
      ),
    );
    if (query != null) await _searchPlaceName(query);
  }

  Future<void> _showHistory(BuildContext anchor) async {
    final history = _controller.history;
    if (history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('検索履歴はまだありません')));
      return;
    }
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset(0, box.size.height), ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );
    final chosen = await showMenu<Object>(
      context: context,
      position: position,
      items: [
        for (final h in history)
          PopupMenuItem(
            value: h,
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text(h.label),
              subtitle: Text('${radiusLabel(h.radius)} · ${_ago(h.at)}'),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'clear', child: Text('履歴を消去')),
      ],
    );
    if (chosen is SearchPoint) {
      _searchAt(chosen.position, name: chosen.label, radius: chosen.radius);
    } else if (chosen == 'clear') {
      _controller.clearHistory();
    }
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'たった今';
    if (d.inHours < 1) return '${d.inMinutes}分前';
    if (d.inDays < 1) return '${d.inHours}時間前';
    return '${d.inDays}日前';
  }

  Future<void> _addListing(LatLng position) async {
    setState(() => _pickedPoint = null);
    final listing = await showListingDialog(context, position: position);
    if (listing != null) await _controller.saveListing(listing);
  }

  Future<void> _editListing(UserListing listing) async {
    final edited = await showListingDialog(context, position: listing.position, initial: listing);
    if (edited != null) await _controller.saveListing(edited);
  }

  Future<void> _deleteListing(UserListing listing) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('募集情報を削除'),
        content: Text('「${listing.title}」を削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除')),
        ],
      ),
    );
    if (ok == true) await _controller.deleteListing(listing.id);
  }

  @override
  Widget build(BuildContext context) {
    final wide = _wide;
    final browser = ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => SnsBrowser(
        controller: _browser,
        expanded: _browserExpanded,
        onToggleExpanded: () => setState(() => _browserExpanded = !_browserExpanded),
        nearbyTargets: _collectNearbySnsTargets(),
      ),
    );
    // スマホの戻るボタン: SNS ではページを戻り、それ以外は地図に戻る
    return PopScope(
      canPop: wide || _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab == 1 && _browser.canGoBack) {
          _browser.back();
        } else if (_tab == 1 && _browserExpanded) {
          setState(() => _browserExpanded = false);
        } else {
          setState(() => _tab = 0);
        }
      },
      child: _buildScaffold(context, wide, browser),
    );
  }

  Widget _buildScaffold(BuildContext context, bool wide, Widget browser) {
    // スマホの SNS タブでは上のバーを隠して、SNS のページを広く表示する（広げたときは下のタブも隠す）
    final snsTab = !wide && _tab == 1;
    return Scaffold(
      appBar: snsTab
          ? null
          : AppBar(
              title: Row(
                children: [
                  ShaderMask(
                    shaderCallback: instagramGradient.createShader,
                    child: const Icon(Icons.travel_explore, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Text('近くのスポット'),
                  if (wide) ...[
                    const SizedBox(width: 24),
                    SizedBox(
                      width: 320,
                      child: TextField(
                        controller: _placeQuery,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          hintText: '地名・住所で場所を探す',
                          prefixIcon: const Icon(Icons.place_outlined),
                          suffixIcon: IconButton(
                            tooltip: '検索',
                            icon: const Icon(Icons.search),
                            onPressed: () => _searchPlaceName(_placeQuery.text),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: _searchPlaceName,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                if (!wide)
                  IconButton(
                    tooltip: '地名・住所で探す',
                    onPressed: _openPlaceSearchDialog,
                    icon: const Icon(Icons.search),
                  ),
                Builder(
                  builder: (anchor) => IconButton(
                    tooltip: '検索履歴',
                    onPressed: () => _showHistory(anchor),
                    icon: const Icon(Icons.history),
                  ),
                ),
                if (!wide)
                  IconButton(
                    tooltip: 'アプリ内で SNS を開く（Instagram にログインできます）',
                    onPressed: () => _openLink(_browser.url ?? SnsBrowserController.homeUrl),
                    icon: const FaIcon(FontAwesomeIcons.instagram, size: 20),
                  ),
                ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) => IconButton(
                    tooltip: '最新のデータに更新',
                    onPressed: _controller.busy ? null : () => _controller.search(refresh: true),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: wide
          ? _buildWideBody(context, browser)
          : IndexedStack(
              index: _tab,
              sizing: StackFit.expand,
              children: [_buildMap(context), SafeArea(child: browser)],
            ),
      bottomNavigationBar: wide || (snsTab && _browserExpanded)
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.map_outlined), label: '地図'),
                NavigationDestination(icon: FaIcon(FontAwesomeIcons.instagram, size: 20), label: 'SNS'),
              ],
            ),
    );
  }

  /// PC・横画面: 左に地図、右に SNS。SNS は画面の半分ほどの幅で表示し、広げると地図を隠して全体に表示する。
  Widget _buildWideBody(BuildContext context, Widget browser) {
    return LayoutBuilder(builder: (context, box) {
      final total = box.maxWidth;
      final snsWidth = math.min(math.max(560.0, total * 0.5), total - 280);
      final full = _browserExpanded;
      return Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: math.max(0, total - snsWidth - 1),
            child: Offstage(offstage: full, child: _buildMap(context)),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: full ? total : snsWidth + 1,
            child: Row(
              children: [
                if (!full) const VerticalDivider(width: 1),
                Expanded(child: browser),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildMap(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final center = c.center;
        final selected = c.selected;
        final places = c.visiblePlaces;
        final selectedVisible = selected != null && places.any((p) => p.id == selected.id);
        final markers = places.length > _maxMarkers ? places.sublist(0, _maxMarkers) : places;
        final picked = _pickedPoint;
        final loadingStatus = c.searching
            ? (c.status ?? '検索中…')
            : (c.eventStatus ?? c.snsStatus);
        return Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: const LatLng(35.681, 139.767),
                initialZoom: 14,
                onMapReady: () {
                  _mapReady = true;
                  _fitToSearchArea();
                },
                onTap: _onMapTap,
                onSecondaryTap: _showMapMenu,
                onLongPress: _showMapMenu,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'io.github.pgdarksan.nearby_insta',
                ),
                if (center != null)
                  CircleLayer(circles: [
                    CircleMarker(
                      point: center,
                      radius: c.radius.toDouble(),
                      useRadiusInMeter: true,
                      color: scheme.primary.withValues(alpha: 0.07),
                      borderColor: scheme.primary.withValues(alpha: 0.45),
                      borderStrokeWidth: 2,
                    ),
                  ]),
                MarkerLayer(markers: [
                  // 遠い順に描いて、近い場所のマーカーを手前にする。
                  for (final p in markers.reversed)
                    if (p.id != selected?.id) _placeMarker(p, false),
                  if (center != null)
                    Marker(point: center, width: 22, height: 22, child: const _CurrentLocationDot()),
                  if (selectedVisible) _placeMarker(selected, true),
                  if (picked != null)
                    Marker(
                      point: picked,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: Icon(Icons.location_on, size: 40, color: scheme.error),
                    ),
                ]),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors',
                        onTap: () => openExternal('https://www.openstreetmap.org/copyright')),
                  ],
                ),
              ],
            ),
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: c.busy ? null : _relocate,
                          icon: const Icon(Icons.my_location, size: 18),
                          label: const Text('現在地で検索'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: !_mapReady ? null : () => _searchAt(_map.camera.center),
                          icon: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('地図の中心で検索'),
                        ),
                        if (loadingStatus != null)
                          Chip(
                            avatar: const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            label: Text(loadingStatus),
                            backgroundColor: scheme.surface.withValues(alpha: 0.92),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (places.length > _maxMarkers)
                          Chip(
                            avatar: const Icon(Icons.info_outline, size: 16),
                            label: Text('近い $_maxMarkers / ${places.length} 件を表示中'),
                            backgroundColor: scheme.surface.withValues(alpha: 0.9),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  MapFilterBar(controller: c),
                ],
              ),
            ),
            if (picked != null && selected == null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 28,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: _PickedPointCard(
                    point: picked,
                    radiusLabel: radiusLabel(c.radius),
                    onSearch: () => _searchAt(picked),
                    onAddListing: () => _addListing(picked),
                    onClose: () => setState(() => _pickedPoint = null),
                  ),
                ),
              ),
            if (selected != null && selectedVisible)
              Positioned(
                left: 12,
                right: 12,
                bottom: 28,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 560,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                    ),
                    child: SingleChildScrollView(
                      child: PlaceDetailCard(
                        place: selected,
                        category: selected.primaryCategory(c.enabled),
                        platforms: c.platforms,
                        isHidden: c.isHidden(selected.id),
                        onToggleHidden: (hidden) => _toggleHidden(selected, hidden),
                        onOpenLink: (url) => _openLink(url, label: selected.name),
                        onSearchInstagram: _searchInstagram,
                        onSearchTikTok: _searchTikTok,
                        onPrevPlace: places.length >= 2 ? () => _stepSelectedPlace(-1) : null,
                        onNextPlace: places.length >= 2 ? () => _stepSelectedPlace(1) : null,
                        onClose: () => c.select(null),
                        onEdit: selected.listing == null ? null : () => _editListing(selected.listing!),
                        onDelete: selected.listing == null ? null : () => _deleteListing(selected.listing!),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Marker _placeMarker(Place place, bool selected) {
    final size = selected ? 46.0 : 32.0;
    return Marker(
      // 地図を動かして表示するマーカーが変わっても、同じ場所には同じウィジェットを使う
      key: ValueKey('${selected ? 'selected' : 'marker'}:${place.id}'),
      point: place.position,
      width: size,
      height: size,
      child: Tooltip(
        message: [place.name, ?place.primaryLink(_controller.platforms)?.handle, ?place.kind].join('\n'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _selectFromMap(place),
            child: PlaceMarker(
              place: place,
              category: place.primaryCategory(_controller.enabled),
              selected: selected,
              platforms: _controller.platforms,
            ),
          ),
        ),
      ),
    );
  }
}

/// 地図をタップして指定した地点で何をするか選ぶカード。
class _PickedPointCard extends StatelessWidget {
  const _PickedPointCard({
    required this.point,
    required this.radiusLabel,
    required this.onSearch,
    required this.onAddListing,
    required this.onClose,
  });

  final LatLng point;
  final String radiusLabel;
  final VoidCallback onSearch;
  final VoidCallback onAddListing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('指定した地点', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                Text('${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                    style: Theme.of(context).textTheme.bodySmall),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: '閉じる'),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onSearch,
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text('ここから $radiusLabel を検索'),
                ),
                OutlinedButton.icon(
                  onPressed: onAddListing,
                  icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                  label: const Text('ここに募集を登録'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentLocationDot extends StatelessWidget {
  const _CurrentLocationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1A73E8),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
      ),
    );
  }
}
