import 'package:flutter/material.dart';

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
  });

  final NearbyController controller;
  final ScrollController scrollController;
  final ValueChanged<Place> onSelect;
  final VoidCallback onAddListing;

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
                      c.locating ? '現在地を取得中…' : (c.locationLabel ?? '現在地 未取得'),
                      style: text.titleSmall,
                    ),
                  ),
                ],
              ),
              if (c.locationNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(c.locationNote!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
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
                child: Text(
                  c.searching ? (c.status ?? '検索中…') : '${places.length} 件',
                  style: text.labelLarge,
                  maxLines: 2,
                ),
              ),
              if (c.busy)
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
            'データ: © OpenStreetMap contributors ／ 「登録した募集」はこの端末に保存',
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
        action: TextButton(onPressed: () => c.search(force: true), child: const Text('再試行')),
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
        onTap: () => onSelect(places[i]),
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
