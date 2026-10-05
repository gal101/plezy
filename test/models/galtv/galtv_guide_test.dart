import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';

/// The guide grid only ever carries what the overlay needs to draw: a title, a
/// time range, and — for the cell's backdrop — the **Plex ratingKey**, which is
/// `program.externalId`. A `flex` break has no Plex identity and must not
/// pretend to.
///
/// The rows are also clamped to the window the tab fetched, so every channel
/// shares one time origin: the same `x` must be the same time on every row, or
/// the ruler above the grid cannot be honest.
void main() {
  TunarrLineupChannel channel(List<Map<String, Object?>> programs, {String id = 'ch-1'}) => TunarrLineupChannel(
    id: id,
    name: 'War Movies',
    number: '1',
    slots: programs.map(TunarrLineupSlot.fromJson).toList(),
  );

  Map<String, Object?> slot(
    int start,
    int stop, {
    String id = 'slot-a',
    String type = 'content',
    String title = 'Schindler’s List',
    String? externalId = '466',
  }) => {
    'id': id,
    'start': start,
    'stop': stop,
    'duration': stop - start,
    'type': type,
    'program': {'title': title, 'externalId': externalId},
  };

  final windowStart = DateTime.fromMillisecondsSinceEpoch(0);
  final windowEnd = DateTime.fromMillisecondsSinceEpoch(60000);

  test('a playable slot carries its Plex ratingKey through to the cell', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(0, 60000)]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries.single.ratingKey, '466');
  });

  test('a flex break has no ratingKey, even if the body carries one', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(0, 60000, type: 'flex', title: 'Commercial Break')]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries.single.ratingKey, isNull);
    expect(rows.single.entries.single.isPlayable, isFalse);
  });

  test('a slot that began before the window is cut to the window start', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(-120000, 60000, title: 'Schindler’s List')]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    // Still running when the window opens, so it owns the origin: no leading gap.
    expect(rows.single.entries.single.start, windowStart);
    expect(rows.single.leadingMs, 0);
  });

  test('a slot running past the window is cut to the window end', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(0, 900000)]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries.single.stop, windowEnd);
  });

  test('a slot entirely outside the window is dropped', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(-60000, -1, id: 'before'), slot(0, 60000, id: 'inside'), slot(60001, 120000, id: 'after')]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries, hasLength(1));
    expect(rows.single.entries.single.title, 'Schindler’s List');
  });

  test('a channel that starts later than the window records the gap it is short by', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(0, 30000, id: 'from-start')], id: 'a'),
        channel([slot(10000, 30000, id: 'gap')], id: 'b'),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    // Both rows are clamped to the same window; the second has to be pushed 10
    // minutes along its strip, or its cells would sit 10 minutes early.
    expect(rows[0].leadingMs, 0);
    expect(rows[1].leadingMs, 10000);
  });
}
