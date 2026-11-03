import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';
import 'matchmaking_timeline.dart';
import 'place_widgets.dart';

/// メートル単位の半径を余分な末尾ゼロなしの km 数値文字列（例: 1000 -> "1", 1500 -> "1.5", 300 -> "0.3"）にする。
String formatKmValue(int meters) {
  if (meters % 1000 == 0) return '${meters ~/ 1000}';
  return (meters / 1000).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
}

String radiusLabel(int r) => r < 1000 ? '${r}m' : '${formatKmValue(r)}km';

/// ユーザーの入力文字列（全角数字・小数点・末尾の km を許容）を正の km 数値として解釈する。
double? parseKmInput(String raw) {
  final normalized = raw
      .replaceAllMapped(RegExp(r'[０-９]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0))
      .replaceAll('．', '.')
      .replaceAll('。', '.')
      .replaceAll(RegExp(r'(?:km|ｋｍ|\s)+', caseSensitive: false), '')
      .trim();
  if (normalized.isEmpty) return null;
  final value = double.tryParse(normalized);
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}

/// 検索範囲と、表示する種類・SNS・対象のチェック切り替え。地図の「絞り込み」画面で使う。
class SearchFilters extends StatelessWidget {
  const SearchFilters({super.key, required this.controller, this.onSelectPlaceFromTimeline});

  final NearbyController controller;
  final ValueChanged<Place>? onSelectPlaceFromTimeline;

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
        Row(
          children: [
            Text('検索範囲', style: text.labelMedium),
            const Spacer(),
            _RadiusKmField(
              radius: c.radius,
              onApplyKm: c.setRadiusKm,
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final r in NearbyController.radiusOptions) ButtonSegment(value: r, label: Text(radiusLabel(r))),
            ],
            selected: {if (NearbyController.radiusOptions.contains(c.radius)) c.radius},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) c.setRadius(s.first);
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('地図に表示する種類', style: text.labelMedium),
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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: PlaceCategory.matchmaking.color,
                side: BorderSide(color: PlaceCategory.matchmaking.color.withValues(alpha: 0.55)),
              ),
              onPressed: () {
                final nav = Navigator.of(context);
                final rootContext = nav.context;
                nav.pop();
                showMatchmakingTimelineSheet(
                  rootContext,
                  c,
                  onSelectPlace: onSelectPlaceFromTimeline ?? (p) => c.select(p.id),
                );
              },
              icon: const Icon(Icons.timeline, size: 16),
              label: Text('婚活・合コンの日程タイムライン（${c.countOf(PlaceCategory.matchmaking)}件）'),
            ),
            if (c.hiddenPlaces.isNotEmpty)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => showHiddenPlacesSheet(context, c),
                icon: const Icon(Icons.visibility_off_outlined, size: 16),
                label: Text('チェックして非表示にした場所（${c.hiddenPlaces.length}件）'),
              ),
          ],
        ),
      ],
    );
  }
}

class _RadiusKmField extends StatefulWidget {
  const _RadiusKmField({required this.radius, required this.onApplyKm});

  final int radius;
  final ValueChanged<double> onApplyKm;

  @override
  State<_RadiusKmField> createState() => _RadiusKmFieldState();
}

class _RadiusKmFieldState extends State<_RadiusKmField> {
  late final TextEditingController _text = TextEditingController(text: formatKmValue(widget.radius));

  @override
  void didUpdateWidget(covariant _RadiusKmField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radius != widget.radius) {
      final formatted = formatKmValue(widget.radius);
      if (_text.text != formatted) {
        _text.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final km = parseKmInput(_text.text);
    if (km == null) {
      _text.text = formatKmValue(widget.radius);
      return;
    }
    FocusScope.of(context).unfocus();
    widget.onApplyKm(km);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 92,
          child: TextField(
            controller: _text,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              suffixText: ' km',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 30),
          ),
          onPressed: _submit,
          child: const Text('指定'),
        ),
      ],
    );
  }
}

/// 検索範囲（km 数値）を直接入力するダイアログ。
Future<void> showRadiusInputDialog(BuildContext context, NearbyController controller) async {
  final result = await showDialog<double>(
    context: context,
    builder: (_) => _RadiusInputDialog(initialRadius: controller.radius),
  );
  if (result != null) {
    await controller.setRadiusKm(result);
  }
}

class _RadiusInputDialog extends StatefulWidget {
  const _RadiusInputDialog({required this.initialRadius});

  final int initialRadius;

  @override
  State<_RadiusInputDialog> createState() => _RadiusInputDialogState();
}

class _RadiusInputDialogState extends State<_RadiusInputDialog> {
  late final TextEditingController _input = TextEditingController(text: formatKmValue(widget.initialRadius));
  String? _errorText;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final km = parseKmInput(_input.text);
    if (km == null) {
      setState(() => _errorText = '0.1〜50 の数値を入力してください');
      return;
    }
    Navigator.pop(context, km);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('検索範囲（km）を指定'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _input,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '半径（km）',
              suffixText: 'km',
              helperText: '0.1〜50 km の範囲で指定できます（例: 0.5, 2.5, 15）',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in NearbyController.radiusOptions)
                ActionChip(
                  label: Text(radiusLabel(r)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.pop(context, r / 1000),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(onPressed: _submit, child: const Text('適用')),
      ],
    );
  }
}

/// 絞り込みの全項目を下から出す画面で開く。
Future<void> showSearchFiltersSheet(
  BuildContext context,
  NearbyController controller, {
  ValueChanged<Place>? onSelectPlaceFromTimeline,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SearchFilters(
            controller: controller,
            onSelectPlaceFromTimeline: onSelectPlaceFromTimeline,
          ),
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
                            Text('チェックを外すと地図に再表示されます',
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
  const MapFilterBar({super.key, required this.controller, this.onSelectPlaceFromTimeline});

  final NearbyController controller;
  final ValueChanged<Place>? onSelectPlaceFromTimeline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final shadow = Colors.black.withValues(alpha: 0.3);
    final matchmakingCount = c.countOf(PlaceCategory.matchmaking);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          PopupMenuButton<int>(
            tooltip: '検索範囲',
            initialValue: NearbyController.radiusOptions.contains(c.radius) ? c.radius : null,
            onSelected: (v) {
              if (v < 0) {
                showRadiusInputDialog(context, c);
              } else {
                c.setRadius(v);
              }
            },
            itemBuilder: (context) => [
              for (final r in NearbyController.radiusOptions)
                PopupMenuItem(value: r, child: Text('半径 ${radiusLabel(r)}')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: -1, child: Text('数値を入力して指定 (km)…')),
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
            onPressed: () => showSearchFiltersSheet(
              context,
              c,
              onSelectPlaceFromTimeline: onSelectPlaceFromTimeline,
            ),
          ),
          const SizedBox(width: 6),
          ActionChip(
            tooltip: '周辺の婚活・合コンを開催日時順のタイムラインで見る',
            avatar: Icon(Icons.timeline, size: 17, color: PlaceCategory.matchmaking.color),
            label: Text(matchmakingCount > 0 ? '婚活日程 $matchmakingCount' : '婚活日程'),
            backgroundColor: scheme.surface,
            side: BorderSide(color: PlaceCategory.matchmaking.color.withValues(alpha: 0.55)),
            elevation: 2,
            shadowColor: shadow,
            visualDensity: VisualDensity.compact,
            onPressed: () => showMatchmakingTimelineSheet(
              context,
              c,
              onSelectPlace: onSelectPlaceFromTimeline ?? (p) => c.select(p.id),
            ),
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
