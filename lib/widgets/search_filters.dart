import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';

String radiusLabel(int r) => r < 1000 ? '${r}m' : '${r ~/ 1000}km';

/// 検索範囲と、表示する種類・SNS・対象の絞り込み。一覧の上と、スマホの地図の「絞り込み」から開く画面で使う。
class SearchFilters extends StatelessWidget {
  const SearchFilters({super.key, required this.controller});

  final NearbyController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
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
                      avatar: Icon(a.icon, size: 14, color: a.color),
                      label: Text('${a.label} ${c.countOfAudience(a)}', style: text.labelSmall),
                      selected: c.audiences.contains(a),
                      showCheckmark: false,
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

/// スマホの地図の上に出す、検索範囲と表示する種類のボタン。一覧のタブに移らずに、地図を見ながら変えられる。
/// 種類は横にスクロールして選び、SNS の種類や対象は「絞り込み」から変える。
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
          for (final cat in PlaceCategory.values) ...[
            const SizedBox(width: 6),
            FilterChip(
              avatar: Icon(cat.icon, size: 18, color: cat.color),
              label: Text('${cat.label} ${c.countOf(cat)}'),
              selected: c.enabled.contains(cat),
              showCheckmark: false,
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
