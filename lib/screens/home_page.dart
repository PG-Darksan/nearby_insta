import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/nearby_controller.dart';
import '../models/listing.dart';
import '../models/place.dart';
import '../services/location_service.dart';
import '../widgets/listing_dialog.dart';
import '../widgets/place_widgets.dart';
import '../widgets/side_panel.dart';

enum _MapAction { search, addListing }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// これより狭い画面（スマホ）では地図と一覧をタブで切り替える。
  static const _wideBreakpoint = 840.0;

  final _controller = NearbyController();
  final _map = MapController();
  final _list = ScrollController();
  bool _mapReady = false;
  LatLng? _fittedCenter;
  int? _fittedRadius;
  int _tab = 0;

  bool get _wide => MediaQuery.sizeOf(context).width >= _wideBreakpoint;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    _list.dispose();
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

  void _selectFromList(Place place) {
    _controller.select(place.id);
    if (!_wide) setState(() => _tab = 0);
    _map.move(place.position, math.max(_map.camera.zoom, 16));
  }

  void _selectFromMap(Place place) {
    _controller.select(place.id);
    final index = _controller.visiblePlaces.indexWhere((p) => p.id == place.id);
    if (index >= 0 && _list.hasClients) {
      final target = (index - 1) * PlaceTile.height;
      _list.animateTo(
        target.clamp(0, _list.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
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
        _controller.setCenter(point);
      case _MapAction.addListing:
        await _addListing(point);
      case null:
        break;
    }
  }

  Future<void> _addListing(LatLng position) async {
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
    final panel = ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => SidePanel(
        controller: _controller,
        scrollController: _list,
        onSelect: _selectFromList,
        onAddListing: () {
          if (!wide) setState(() => _tab = 0);
          _addListing(_mapReady ? _map.camera.center : (_controller.center ?? const LatLng(35.681, 139.767)));
        },
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ShaderMask(
              shaderCallback: instagramGradient.createShader,
              child: const Icon(Icons.travel_explore, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Text('近くのスポット'),
          ],
        ),
        actions: [
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => IconButton(
              tooltip: '再検索',
              onPressed: _controller.busy ? null : () => _controller.search(force: true),
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: wide
          ? Row(
              children: [
                Expanded(child: _buildMap(context)),
                const VerticalDivider(width: 1),
                SizedBox(width: 400, child: panel),
              ],
            )
          : IndexedStack(index: _tab, children: [_buildMap(context), panel]),
      bottomNavigationBar: wide
          ? null
          : ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  const NavigationDestination(icon: Icon(Icons.map_outlined), label: '地図'),
                  NavigationDestination(
                    icon: Badge(
                      label: Text('${_controller.visiblePlaces.length}'),
                      child: const Icon(Icons.list),
                    ),
                    label: '一覧',
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildMap(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = _wide;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        final center = c.center;
        final selected = c.selected;
        final places = c.visiblePlaces;
        final selectedVisible = selected != null && places.any((p) => p.id == selected.id);
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
                onTap: (_, _) => c.select(null),
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
                  for (final p in places.reversed)
                    if (p.id != selected?.id) _placeMarker(p, false),
                  if (center != null)
                    Marker(point: center, width: 22, height: 22, child: const _CurrentLocationDot()),
                  if (selectedVisible) _placeMarker(selected, true),
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
              left: 12,
              right: 12,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: c.busy ? null : _relocate,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('現在地で検索'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: c.searching || !_mapReady ? null : () => c.setCenter(_map.camera.center),
                    icon: const Icon(Icons.travel_explore, size: 18),
                    label: const Text('地図の中心で検索'),
                  ),
                  Chip(
                    avatar: Icon(wide ? Icons.mouse_outlined : Icons.touch_app_outlined, size: 16),
                    label: Text(wide ? '右クリックで検索・募集登録' : '長押しで検索・募集登録'),
                    backgroundColor: scheme.surface.withValues(alpha: 0.9),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            if (selected != null)
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
      point: place.position,
      width: size,
      height: size,
      child: Tooltip(
        message: [place.name, ?place.instagram?.handle, ?place.kind].join('\n'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _selectFromMap(place),
            child: PlaceMarker(
              place: place,
              category: place.primaryCategory(_controller.enabled),
              selected: selected,
            ),
          ),
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
