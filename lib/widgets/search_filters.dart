import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';
import 'place_widgets.dart';

String radiusLabel(int r) => r < 1000 ? '${r}m' : '${r ~/ 1000}km';

/// 検索範囲と、表示する種類・SNS・対象のチェック切り替え。一覧の上と、地図の「絞り込み／表示切替」画面で使う。
class SearchFilters extends StatelessWidget {
  const SearchFilters({super.key, required this.controller});

  final NearbyController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final allEnabled = c.enabled.length == PlaceCategory.values.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('検索範囲', style: text.labelMedium),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final r in NearbyController.radiusOptions) ButtonSegment(value: r, label: Text(radiusLabel(r))),
            ],
            selected: {c.radius},
            onSelectionChanged: (s) => c.setRadius(s.first),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('地図・一覧に表示する種類', style: text.labelMedium),
            const Spacer(),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: allEnabled ? null : () => c.setAllCategories(true),
              child: const Text('すべて選択'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: c.enabled.isEmpty ? null : () => c.setAllCategories(false),
              child: const Text('すべて解除'),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final cat in PlaceCategory.values)
              FilterChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(cat.icon, size: 16, color: cat.color),
                    const SizedBox(width: 4),
                    Text('${cat.label} ${c.countOf(cat)}'),
                  ],
                ),
                selected: c.enabled.contains(cat),
                showCheckmark: true,
                checkmarkColor: cat.color,
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
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FaIcon(p.icon, size: 12, color: p.color),
                        const SizedBox(width: 4),
                        Text('${p.label} ${c.countOfPlatform(p)}', style: text.labelSmall),
                      ],
                    ),
                    selected: c.platforms.contains(p),
                    showCheckmark: true,
                    checkmarkColor: p.color,
                    selectedColor: p.color.withValues(alpha: 0.12),
                    side: BorderSide(color: c.platforms.contains(p) ? p.color : scheme.outlineVariant),
                    visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) => c.togglePlatform(p),
                  ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Row(
          children: [
            Text('対象', style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final a in Audience.values)
                    FilterChip(
                      tooltip: a == Audience.none ? 'OSM のタグや名前から判定できないもの' : null,
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(a.icon, size: 13, color: a.color),
                          const SizedBox(width: 3),
                          Text('${a.label} ${c.countOfAudience(a)}', style: text.labelSmall),
                        ],
                      ),
                      selected: c.audiences.contains(a),
                      showCheckmark: true,
                      checkmarkColor: a.color,
                      selectedColor: a.color.withValues(alpha: 0.12),
                      side: BorderSide(color: c.audiences.contains(a) ? a.color : scheme.outlineVariant),
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (_) => c.toggleAudience(a),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (c.hiddenPlaces.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => showHiddenPlacesSheet(context, c),
            icon: const Icon(Icons.visibility_off_outlined, size: 16),
            label: Text('チェックして非表示にした場所（${c.hiddenPlaces.length}件）'),
          ),
        ],
      ],
    );
  }
}

/// 絞り込みの全項目を下から出す画面で開く。
Future<void> showSearchFiltersSheet(BuildContext context, NearbyController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SearchFilters(controller: controller),
        ),
      ),
    ),
  );
}

/// チェックを付けて非表示にした個別の場所の一覧シート。チェックを外すと地図・一覧に再表示する。
Future<void> showHiddenPlacesSheet(BuildContext context, NearbyController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final scheme = Theme.of(context).colorScheme;
        final inRangeById = {for (final p in controller.placesInRange) p.id: p};
        // 現在の検索範囲内にあるものを先に並べる
        final entries = controller.hiddenPlaces.entries.toList()
          ..sort((a, b) {
            final pa = inRangeById[a.key];
            final pb = inRangeById[b.key];
            if (pa != null && pb != null) return pa.distanceMeters.compareTo(pb.distanceMeters);
            if (pa != null) return -1;
            if (pb != null) return 1;
            return a.value.compareTo(b.value);
          });
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('チェックして非表示にした場所（${entries.length}件）', style: text.titleMedium),
                            Text('チェックを外すと地図と一覧に再表示されます',
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      if (entries.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            controller.unhideAll();
                            Navigator.pop(context);
                          },
                          child: const Text('すべて再表示'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('非表示にしている場所はありません')),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        final place = inRangeById[entry.key];
                        return CheckboxListTile(
                          value: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(place?.name ?? entry.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: place == null
                              ? const Text('現在の検索範囲外')
                              : Text([?place.kind, formatDistance(place.distanceMeters)].join(' · ')),
                          onChanged: (_) {
                            controller.unhideById(entry.key);
                            if (controller.hiddenPlaces.isEmpty && context.mounted) {
                              Navigator.pop(context);
                            }
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// スマホの地図の上に出す、検索範囲と表示する種類のボタン。一覧のタブに移らずに、地図を見ながら変えられる。
/// 種類は横にスクロールしてチェックを切り替え、SNS の種類や対象は「絞り込み」から変える。
class MapFilterBar extends StatelessWidget {
  const MapFilterBar({super.key, required this.controller});

  final NearbyController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final shadow = Colors.black.withValues(alpha: 0.3);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          PopupMenuButton<int>(
            tooltip: '検索範囲',
            initialValue: c.radius,
            onSelected: c.setRadius,
            itemBuilder: (context) => [
              for (final r in NearbyController.radiusOptions)
                PopupMenuItem(value: r, child: Text('半径 ${radiusLabel(r)}')),
            ],
            child: Chip(
              avatar: Icon(Icons.radar, size: 18, color: scheme.primary),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [Text('範囲 ${radiusLabel(c.radius)}'), const Icon(Icons.arrow_drop_down, size: 18)],
              ),
              backgroundColor: scheme.surface,
              elevation: 2,
              shadowColor: shadow,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 6),
          ActionChip(
            avatar: Icon(Icons.tune, size: 18, color: scheme.primary),
            label: const Text('絞り込み'),
            backgroundColor: scheme.surface,
            elevation: 2,
            shadowColor: shadow,
            visualDensity: VisualDensity.compact,
            onPressed: () => showSearchFiltersSheet(context, c),
          ),
          if (c.hiddenPlaces.isNotEmpty) ...[
            const SizedBox(width: 6),
            ActionChip(
              avatar: Icon(Icons.visibility_off_outlined, size: 16, color: scheme.primary),
              label: Text('非表示 ${c.hiddenPlaces.length}'),
              backgroundColor: scheme.surface,
              elevation: 2,
              shadowColor: shadow,
              visualDensity: VisualDensity.compact,
              onPressed: () => showHiddenPlacesSheet(context, c),
            ),
          ],
          for (final cat in PlaceCategory.values) ...[
            const SizedBox(width: 6),
            FilterChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(cat.icon, size: 16, color: cat.color),
                  const SizedBox(width: 4),
                  Text('${cat.label} ${c.countOf(cat)}'),
                ],
              ),
              selected: c.enabled.contains(cat),
              showCheckmark: true,
              checkmarkColor: cat.color,
              backgroundColor: scheme.surface,
              selectedColor: Color.alphaBlend(cat.color.withValues(alpha: 0.2), scheme.surface),
              side: BorderSide(color: c.enabled.contains(cat) ? cat.color : scheme.outlineVariant),
              elevation: 2,
              shadowColor: shadow,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => c.toggleCategory(cat),
            ),
          ],
        ],
      ),
    );
  }
}
