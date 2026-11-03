import 'package:flutter/material.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';
import 'place_widgets.dart';

/// 婚活・合コンイベント 1 件分の日時解析結果（タイムライン表示・並び替え用）。
class MatchmakingScheduleEntry {
  const MatchmakingScheduleEntry({
    required this.place,
    this.startAt,
    this.endAt,
    this.rawSchedule,
    this.hasExplicitTime = false,
  });

  final Place place;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? rawSchedule;
  final bool hasExplicitTime;

  /// 日付単位のグループ化キー（時刻を切り捨てたローカル日付）。日時不明なら `null`。
  DateTime? get dayKey => startAt == null ? null : DateTime(startAt!.year, startAt!.month, startAt!.day);

  String get startTimeText {
    if (startAt == null || !hasExplicitTime) return '時間未定';
    return _hm(startAt!);
  }

  String? get endTimeText {
    if (endAt == null || !hasExplicitTime) return null;
    if (startAt != null &&
        endAt!.year == startAt!.year &&
        endAt!.month == startAt!.month &&
        endAt!.day == startAt!.day) {
      return '〜${_hm(endAt!)}';
    }
    return '〜${endAt!.month}/${endAt!.day}';
  }

  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static final _ymdTimePattern = RegExp(
    r'(\d{4})\s*[年/\-\.]\s*(\d{1,2})\s*[月/\-\.]\s*(\d{1,2})\s*日?(?:[^\d:]{0,8}(\d{1,2}):(\d{2}))?(?:\s*[〜~～\-ー]\s*(\d{1,2}):(\d{2}))?',
  );
  static final _mdTimePattern = RegExp(
    r'(?<!\d)(\d{1,2})\s*[月/]\s*(\d{1,2})\s*日?(?:\s*[（(][^）)]*[）)])?(?:\s*(\d{1,2}):(\d{2}))?(?:\s*[〜~～\-ー]\s*(\d{1,2}):(\d{2}))?',
  );
  static final _clockPattern = RegExp(r'\b\d{1,2}:\d{2}\b');

  factory MatchmakingScheduleEntry.fromPlace(Place place, {DateTime? referenceNow}) {
    final now = referenceNow ?? DateTime.now();
    final raw = (place.listing?.schedule ?? place.event?.schedule)?.trim();
    final evStart = place.event?.startAt?.toLocal();
    final evEnd = place.event?.endAt?.toLocal();

    if (evStart != null) {
      final hasTime = (raw != null && _clockPattern.hasMatch(raw)) ||
          evStart.hour != 0 ||
          evStart.minute != 0 ||
          evEnd != null;
      return MatchmakingScheduleEntry(
        place: place,
        startAt: evStart,
        endAt: evEnd,
        rawSchedule: raw,
        hasExplicitTime: hasTime,
      );
    }

    if (raw != null && raw.isNotEmpty) {
      final ymd = _ymdTimePattern.firstMatch(raw);
      if (ymd != null) {
        final y = int.parse(ymd.group(1)!);
        final m = int.parse(ymd.group(2)!);
        final d = int.parse(ymd.group(3)!);
        final sh = ymd.group(4) != null ? int.parse(ymd.group(4)!) : 0;
        final sm = ymd.group(5) != null ? int.parse(ymd.group(5)!) : 0;
        final hasTime = ymd.group(4) != null;
        final start = DateTime(y, m, d, sh, sm);
        final end = ymd.group(6) != null
            ? DateTime(y, m, d, int.parse(ymd.group(6)!), int.parse(ymd.group(7)!))
            : null;
        return MatchmakingScheduleEntry(
          place: place,
          startAt: start,
          endAt: end,
          rawSchedule: raw,
          hasExplicitTime: hasTime,
        );
      }

      final md = _mdTimePattern.firstMatch(raw);
      if (md != null) {
        final m = int.parse(md.group(1)!);
        final d = int.parse(md.group(2)!);
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
          var y = now.year;
          final tentative = DateTime(y, m, d);
          if (tentative.isBefore(DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30)))) {
            y += 1;
          }
          final sh = md.group(3) != null ? int.parse(md.group(3)!) : 0;
          final sm = md.group(4) != null ? int.parse(md.group(4)!) : 0;
          final hasTime = md.group(3) != null;
          final start = DateTime(y, m, d, sh, sm);
          final end = md.group(5) != null
              ? DateTime(y, m, d, int.parse(md.group(5)!), int.parse(md.group(6)!))
              : null;
          return MatchmakingScheduleEntry(
            place: place,
            startAt: start,
            endAt: end,
            rawSchedule: raw,
            hasExplicitTime: hasTime,
          );
        }
      }
    }

    return MatchmakingScheduleEntry(
      place: place,
      rawSchedule: raw,
    );
  }
}

/// 周辺の婚活・合コンイベントを日程・開始時刻順のタイムライン形式で表示するボトムシートを開く。
Future<void> showMatchmakingTimelineSheet(
  BuildContext context,
  NearbyController controller, {
  required ValueChanged<Place> onSelectPlace,
  String? initialHighlightPlaceId,
  DateTime? referenceNow,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.86,
        ),
        child: MatchmakingTimelineView(
          controller: controller,
          initialHighlightPlaceId: initialHighlightPlaceId,
          referenceNow: referenceNow,
          onSelectPlace: (place) {
            Navigator.pop(sheetContext);
            onSelectPlace(place);
          },
        ),
      ),
    ),
  );
}

/// 婚活・合コンの日程タイムライン表示ウィジェット。
class MatchmakingTimelineView extends StatefulWidget {
  const MatchmakingTimelineView({
    super.key,
    required this.controller,
    required this.onSelectPlace,
    this.initialHighlightPlaceId,
    this.referenceNow,
  });

  final NearbyController controller;
  final ValueChanged<Place> onSelectPlace;
  final String? initialHighlightPlaceId;
  final DateTime? referenceNow;

  @override
  State<MatchmakingTimelineView> createState() => _MatchmakingTimelineViewState();
}

class _MatchmakingTimelineViewState extends State<MatchmakingTimelineView> {
  static const _accent = Color(0xFFE91E63);
  static const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  static final _undatedSentinel = DateTime(9999, 12, 31);

  /// `null` なら全日程、`_undatedSentinel` なら日時未定のみ、それ以外は指定日のみ表示する。
  DateTime? _selectedDay;

  List<MatchmakingScheduleEntry> _collectEntries(DateTime now) {
    final c = widget.controller;
    final entries = <MatchmakingScheduleEntry>[
      for (final p in c.placesInRange)
        if (!c.isHidden(p.id) &&
            p.baseCategories.contains(PlaceCategory.matchmaking) &&
            c.audiences.contains(p.audience) &&
            p.matches(c.filter))
          MatchmakingScheduleEntry.fromPlace(p, referenceNow: now),
    ];
    entries.sort((a, b) {
      final sa = a.startAt;
      final sb = b.startAt;
      if (sa != null && sb != null) {
        final cmp = sa.compareTo(sb);
        if (cmp != 0) return cmp;
      } else if (sa != null) {
        return -1;
      } else if (sb != null) {
        return 1;
      }
      return a.place.distanceMeters.compareTo(b.place.distanceMeters);
    });
    return entries;
  }

  static String _shortDayChipLabel(DateTime day, DateTime today) {
    final wd = _weekdays[day.weekday - 1];
    final diff = day.difference(today).inDays;
    final prefix = switch (diff) {
      0 => '今日 ',
      1 => '明日 ',
      _ => '',
    };
    return '$prefix${day.month}/${day.day}($wd)';
  }

  static String _sectionHeaderLabel(DateTime? day, DateTime today) {
    if (day == null) return '日時指定なし・常時募集';
    final wd = _weekdays[day.weekday - 1];
    final diff = day.difference(today).inDays;
    final badge = switch (diff) {
      0 => '（今日）',
      1 => '（明日）',
      _ => '',
    };
    return '${day.month}月${day.day}日（$wd）$badge';
  }

  static Color? _weekdayAccent(DateTime day, ColorScheme scheme) {
    if (day.weekday == DateTime.sunday) return const Color(0xFFD81B60);
    if (day.weekday == DateTime.saturday) return const Color(0xFF1E88E5);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final now = widget.referenceNow ?? DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final allEntries = _collectEntries(now);

        final dayCounts = <DateTime, int>{};
        var undatedCount = 0;
        for (final e in allEntries) {
          if (e.dayKey case final day?) {
            dayCounts[day] = (dayCounts[day] ?? 0) + 1;
          } else {
            undatedCount++;
          }
        }
        final sortedDays = dayCounts.keys.toList()..sort();

        // 選択中の日付が結果変更で消えた場合は「すべて」に戻す
        final activeFilter = (_selectedDay != null &&
                ((_selectedDay == _undatedSentinel && undatedCount == 0) ||
                    (_selectedDay != _undatedSentinel && !dayCounts.containsKey(_selectedDay))))
            ? null
            : _selectedDay;

        final filtered = [
          for (final e in allEntries)
            if (activeFilter == null ||
                (activeFilter == _undatedSentinel ? e.dayKey == null : e.dayKey == activeFilter))
              e,
        ];

        // 日付見出し付きのフラット行リストを作る
        final rows = <Object>[];
        DateTime? lastDay = DateTime(0);
        for (final e in filtered) {
          final key = e.dayKey;
          if (rows.isEmpty || key != lastDay) {
            final sectionCount = key == null ? undatedCount : (dayCounts[key] ?? 0);
            rows.add((day: key, count: sectionCount));
            lastDay = key;
          }
          rows.add(e);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.timeline, color: _accent, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '婚活・合コン 日程タイムライン',
                          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '開催日時順 · 周辺 ${allEntries.length}件',
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            if (c.eventStatus != null) ...[
                              const SizedBox(width: 8),
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 4),
                              Text('取得中', style: text.labelSmall?.copyWith(color: _accent)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '閉じる',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (sortedDays.isNotEmpty || undatedCount > 0)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    ChoiceChip(
                      label: Text('すべて (${allEntries.length})'),
                      selected: activeFilter == null,
                      selectedColor: _accent.withValues(alpha: 0.18),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _selectedDay = null),
                    ),
                    for (final day in sortedDays) ...[
                      const SizedBox(width: 6),
                      Builder(
                        builder: (context) {
                          final wdColor = _weekdayAccent(day, scheme);
                          final isSel = activeFilter == day;
                          return ChoiceChip(
                            label: Text(
                              '${_shortDayChipLabel(day, today)} ${dayCounts[day]}',
                              style: TextStyle(
                                color: isSel ? _accent : wdColor,
                                fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            selected: isSel,
                            selectedColor: _accent.withValues(alpha: 0.18),
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() => _selectedDay = isSel ? null : day),
                          );
                        },
                      ),
                    ],
                    if (undatedCount > 0) ...[
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text('日時指定なし $undatedCount'),
                        selected: activeFilter == _undatedSentinel,
                        selectedColor: _accent.withValues(alpha: 0.18),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(
                          () => _selectedDay = activeFilter == _undatedSentinel ? null : _undatedSentinel,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c.eventStatus != null) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text('周辺の婚活・合コンイベントを取得しています…', style: text.bodyMedium),
                    ] else ...[
                      Icon(Icons.event_busy_outlined, size: 40, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(
                        '現在の検索範囲内に婚活・合コンの予定が見つかりませんでした',
                        textAlign: TextAlign.center,
                        style: text.bodyMedium,
                      ),
                      if (c.radius < 5000) ...[
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: () => c.setRadius(5000),
                          icon: const Icon(Icons.radar, size: 18),
                          label: const Text('検索範囲を 5km に広げて探す'),
                        ),
                      ],
                    ],
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    if (row is ({DateTime? day, int count})) {
                      final dayColor = row.day != null ? _weekdayAccent(row.day!, scheme) : null;
                      return Padding(
                        padding: EdgeInsets.only(top: index == 0 ? 2 : 12, bottom: 6),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: (dayColor ?? _accent).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                _sectionHeaderLabel(row.day, today),
                                style: text.labelLarge?.copyWith(
                                  color: dayColor ?? _accent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${row.count}件',
                              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      );
                    }

                    final entry = row as MatchmakingScheduleEntry;
                    final isLastInSection =
                        index + 1 >= rows.length || rows[index + 1] is ({DateTime? day, int count});
                    final highlighted = entry.place.id == (widget.initialHighlightPlaceId ?? c.selectedId);
                    return _TimelineEventTile(
                      entry: entry,
                      isLastInSection: isLastInSection,
                      highlighted: highlighted,
                      onSelectOnMap: () {
                        if (!c.enabled.contains(PlaceCategory.matchmaking)) {
                          c.toggleCategory(PlaceCategory.matchmaking);
                        }
                        if (!c.audiences.contains(entry.place.audience)) {
                          c.toggleAudience(entry.place.audience);
                        }
                        widget.onSelectPlace(entry.place);
                      },
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TimelineEventTile extends StatelessWidget {
  const _TimelineEventTile({
    required this.entry,
    required this.isLastInSection,
    required this.highlighted,
    required this.onSelectOnMap,
  });

  static const _accent = Color(0xFFE91E63);

  final MatchmakingScheduleEntry entry;
  final bool isLastInSection;
  final bool highlighted;
  final VoidCallback onSelectOnMap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final place = entry.place;
    final ev = place.event;
    final listing = place.listing;
    final fee = listing?.fee ?? ev?.fee;
    final venue = ev?.venue ?? place.address;
    final organizer = listing?.organizer ?? ev?.organizer;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左: 開始・終了時刻カラム
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 10, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    entry.startTimeText,
                    style: text.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: entry.hasExplicitTime ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (entry.endTimeText case final endLabel?)
                    Text(
                      endLabel,
                      style: text.labelSmall?.copyWith(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  else if (!entry.hasExplicitTime && entry.rawSchedule != null)
                    Text(
                      entry.rawSchedule!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: text.labelSmall?.copyWith(fontSize: 10, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ),
          // 中央: タイムライン縦軸とノード
          SizedBox(
            width: 22,
            child: Column(
              children: [
                const SizedBox(height: 14),
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: highlighted ? _accent : scheme.surface,
                    border: Border.all(color: _accent, width: 2.5),
                  ),
                ),
                if (!isLastInSection)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: _accent.withValues(alpha: 0.28),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 右: イベント情報カード
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: highlighted
                    ? _accent.withValues(alpha: 0.08)
                    : scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: highlighted ? _accent : scheme.outlineVariant,
                    width: highlighted ? 1.5 : 1,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onSelectOnMap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (place.kind case final k?)
                              _SmallTag(label: k, color: _accent),
                            if (ev != null)
                              _SmallTag(label: ev.source, color: const Color(0xFF455A64))
                            else if (place.isListing)
                              const _SmallTag(label: '登録した募集', color: Color(0xFF616161)),
                            if (place.audience != Audience.none)
                              _SmallTag(label: place.audience.label, color: place.audience.color),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.location_on_outlined, size: 14, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                [?venue, formatDistance(place.distanceMeters)].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                        if (fee != null && fee.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(Icons.payments_outlined, size: 14, color: scheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  fee,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (organizer != null && organizer.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(Icons.groups_outlined, size: 14, color: scheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  organizer,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              onPressed: onSelectOnMap,
                              icon: const Icon(Icons.place_outlined, size: 16),
                              label: const Text('地図で見る'),
                            ),
                            if (place.website case final url?)
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: _accent,
                                  foregroundColor: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                                onPressed: () => openExternal(url),
                                icon: const Icon(Icons.open_in_new, size: 15),
                                label: const Text('詳細・申込'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
