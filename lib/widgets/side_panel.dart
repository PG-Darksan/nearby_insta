import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';
import '../services/location_service.dart';
import 'place_widgets.dart';

/// 検索条件と結果一覧。PC では地図の右、スマホでは「一覧」タブに表示する。
class SidePanel extends StatelessWidget {
  const SidePanel({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.onSelect,
    required this.onAddListing,
    required this.onOpenLink,
  });

  final NearbyController controller;
  final ScrollController scrollController;
  final ValueChanged<Place> onSelect;
  final VoidCallback onAddListing;
  final OpenLink onOpenLink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final places = c.visiblePlaces;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_sourceIcon(c.source), size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.locating
                          ? '現在地を取得中…'
                          : c.centerName != null
                              ? '${c.centerName} 付近'
                              : (c.locationLabel ?? '現在地 未取得'),
                      style: text.titleSmall,
                    ),
                  ),
                ],
              ),
              if (!c.locating && c.centerName != null && c.locationLabel != null)
                Text(c.locationLabel!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (c.locationNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(c.locationNote!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              if (c.center != null && !c.locating) _NearbyPostsButton(controller: c, onOpenLink: onOpenLink),
              const SizedBox(height: 12),
              Text('検索範囲', style: text.labelMedium),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: [
                    for (final r in NearbyController.radiusOptions)
                      ButtonSegment(value: r, label: Text(r < 1000 ? '${r}m' : '${r ~/ 1000}km')),
                  ],
                  selected: {c.radius},
                  onSelectionChanged: (s) => c.setRadius(s.first),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final cat in PlaceCategory.values)
                    FilterChip(
                      avatar: Icon(cat.icon, size: 18, color: cat.color),
                      label: Text('${cat.label} ${c.countOf(cat)}'),
                      selected: c.enabled.contains(cat),
                      showCheckmark: false,
                      selectedColor: cat.color.withValues(alpha: 0.16),
                      side: BorderSide(color: c.enabled.contains(cat) ? cat.color : scheme.outlineVariant),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => c.toggleCategory(cat),
                    ),
                ],
              ),
              if (c.enabled.contains(PlaceCategory.sns)) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final p in SnsPlatform.values)
                      if (c.countOfPlatform(p) > 0 || !c.platforms.contains(p))
                        FilterChip(
                          avatar: FaIcon(p.icon, size: 13, color: p.color),
                          label: Text('${p.label} ${c.countOfPlatform(p)}', style: text.labelSmall),
                          selected: c.platforms.contains(p),
                          showCheckmark: false,
                          selectedColor: p.color.withValues(alpha: 0.12),
                          side: BorderSide(color: c.platforms.contains(p) ? p.color : scheme.outlineVariant),
                          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onSelected: (_) => c.togglePlatform(p),
                        ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: '名前・ユーザー名・種別で絞り込み',
                  border: OutlineInputBorder(),
                ),
                onChanged: c.setFilter,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${places.length} 件', style: text.labelLarge),
                    for (final s in [if (c.searching) c.status ?? '検索中…', ?c.snsStatus])
                      Text(s, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant), maxLines: 2),
                  ],
                ),
              ),
              if (c.busy || c.snsStatus != null)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              TextButton.icon(
                onPressed: onAddListing,
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('募集を登録'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildList(context, places)),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            'データ: © OpenStreetMap contributors・Wikidata・各施設の公式サイト ／ 「登録した募集」はこの端末に保存',
            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<Place> places) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    if (c.error != null) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        color: scheme.error,
        text: c.error!,
        action: TextButton(onPressed: c.search, child: const Text('再試行')),
      );
    }
    if (places.isEmpty && !c.busy) {
      return _Message(
        icon: Icons.search_off,
        color: scheme.onSurfaceVariant,
        text: c.placesInRange.isEmpty
            ? 'この範囲には該当する場所が見つかりませんでした。\n検索範囲を広げるか、地図の別の地点で検索してください。'
            : '絞り込み条件に一致する場所はありません。',
      );
    }
    return ListView.builder(
      controller: scrollController,
      itemExtent: PlaceTile.height,
      itemCount: places.length,
      itemBuilder: (context, i) => PlaceTile(
        place: places[i],
        category: places[i].primaryCategory(c.enabled),
        selected: places[i].id == c.selectedId,
        platforms: c.platforms,
        onTap: () => onSelect(places[i]),
        onOpenLink: onOpenLink,
      ),
    );
  }

  IconData _sourceIcon(LocationSource? source) => switch (source) {
        LocationSource.device => Icons.gps_fixed,
        LocationSource.ip => Icons.wifi_tethering,
        LocationSource.manual => Icons.push_pin_outlined,
        null => Icons.location_searching,
      };
}

/// 検索地点の付近の投稿を、各 SNS の検索で探すメニュー。
/// 個人のアカウントは公開データに位置がないので、SNS 自身の検索（ログイン中のアカウントで）を使う。
class _NearbyPostsButton extends StatelessWidget {
  const _NearbyPostsButton({required this.controller, required this.onOpenLink});

  final NearbyController controller;
  final OpenLink onOpenLink;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final center = c.center!;
    final km = (c.radius / 1000).clamp(0.3, 20.0);
    final area = c.centerName?.replaceFirst(RegExp(r'[一二三四五六七八九十〇]+丁目$'), '');
    final geocode = 'geocode:${center.latitude.toStringAsFixed(4)},${center.longitude.toStringAsFixed(4)},'
        '${km < 1 ? '${(km * 1000).round()}m' : '${km.round()}km'}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: MenuAnchor(
        menuChildren: [
          MenuItemButton(
            leadingIcon: FaIcon(SnsPlatform.x.icon, size: 16),
            onPressed: () => onOpenLink(SnsPlatform.x.searchUrl(geocode)),
            child: Text('X: この範囲（半径 ${km < 1 ? '${(km * 1000).round()}m' : '${km.round()}km'}）の位置情報つきの投稿'),
          ),
          if (area != null && area.isNotEmpty)
            for (final p in [SnsPlatform.instagram, SnsPlatform.x, SnsPlatform.tiktok, SnsPlatform.threads])
              MenuItemButton(
                leadingIcon: SizedBox(width: 18, child: Center(child: FaIcon(p.icon, size: 16, color: p.color))),
                onPressed: () => onOpenLink(p.searchUrl(area)),
                child: Text('${p.label}: 「$area」で検索'),
              ),
        ],
        builder: (context, menu, _) => OutlinedButton.icon(
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: const Text('この付近の投稿を SNS で見る（個人のアカウントなど）'),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.color, required this.text, this.action});

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            ?action,
          ],
        ),
      ),
    );
  }
}
