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
    String? programType,
  }) => {
    'id': id,
    'start': start,
    'stop': stop,
    'duration': stop - start,
    'type': type,
    'program': {'title': title, 'externalId': externalId, 'type': ?programType},
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

  test('a filler slot is playable but is never "what is next"', () {
    // The owner's rule, 2026-10-09: *"if next up is an ad break slot, i dont want
    // it displayed"*. A filler is ordinary playable content with a ratingKey, so
    // nothing but this flag keeps it out of the slate's and the hint's answer.
    Map<String, Object?> program(
      String id,
      int start,
      int stop, {
      required String title,
      required String externalId,
      String? programType,
    }) => {
      'id': id,
      'start': start,
      'stop': stop,
      'duration': stop - start,
      'type': 'content',
      'program': {'title': title, 'externalId': externalId, 'type': programType},
    };

    final now = DateTime.fromMillisecondsSinceEpoch(1800000);
    final rows = galTvGuideRows(
      channels: [
        channel([
          program('p1', 900000, 1800000, title: 'Dunkirk', externalId: '182', programType: 'movie'),
          program('p2', 1800000, 1830000, title: 'Nemo danseaza', externalId: '5177', programType: 'other_video'),
          program('p3', 1830000, 3600000, title: 'The Head', externalId: '3769', programType: 'episode'),
        ]),
      ],
      windowStart: DateTime.fromMillisecondsSinceEpoch(0),
      windowEnd: DateTime.fromMillisecondsSinceEpoch(3600000),
    );

    final upNext = galTvUpNext(rows, 'ch-1', now);

    expect(upNext?.title, 'The Head', reason: 'the ad in between is skipped, not named');
    expect(upNext?.ratingKey, '3769');
  });

  test('a channel with nothing but ads and breaks ahead has no "next"', () {
    Map<String, Object?> entry(String id, int start, int stop, String type, {String? title, String? externalId}) => {
      'id': id,
      'start': start,
      'stop': stop,
      'duration': stop - start,
      'type': type,
      if (title != null) 'program': {'title': title, 'externalId': externalId, 'type': 'other_video'},
    };

    final rows = galTvGuideRows(
      channels: [
        channel([
          entry('flex-1', 0, 600000, 'flex'),
          entry('ad-1', 600000, 1800000, 'content', title: 'full', externalId: '5179'),
        ]),
      ],
      windowStart: DateTime.fromMillisecondsSinceEpoch(0),
      windowEnd: DateTime.fromMillisecondsSinceEpoch(1800000),
    );

    expect(galTvUpNext(rows, 'ch-1', DateTime.fromMillisecondsSinceEpoch(0)), isNull);
  });

  test('a flex slot is a break, a redirect is not', () {
    // Only `flex` is scheduled break time. A `redirect` is unplayable too, but it
    // points at another channel — labelling it "Ad Break" would be a lie.
    Map<String, Object?> bare(String id, int start, int stop, String type) => {
      'id': id,
      'start': start,
      'stop': stop,
      'duration': stop - start,
      'type': type,
    };

    final rows = galTvGuideRows(
      channels: [
        channel([
          bare('flex-1', 0, 1800000, 'flex'),
          bare('redir-1', 1800000, 3600000, 'redirect'),
          slot(3600000, 4200000, id: 'content-1'),
        ]),
      ],
      windowStart: windowStart,
      windowEnd: DateTime.fromMillisecondsSinceEpoch(4200000),
    );

    final entries = rows.single.entries;
    expect(entries[0].isBreak, isTrue);
    expect(entries[1].isBreak, isFalse, reason: 'a redirect is not an ad break');
    expect(entries[2].isBreak, isFalse);
    expect(entries.every((e) => e.isBreak == false || !e.isPlayable), isTrue,
        reason: 'a break is never playable');
  });

  test('a gap cell is never captioned with the wire\'s own slot type', () {
    // A `flex` slot carries no program, and the old fallback titled the cell with
    // `slot.type` — the owner's channel 4 showed a row of cells literally reading
    // "flex". The cell stays (the strip is laid out by cumulative pitch, so it
    // holds the gap's place on the shared time axis) but it says nothing.
    Map<String, Object?> gap(int start, int stop, String type) => {
      'id': 'gap-$start',
      'start': start,
      'stop': stop,
      'duration': stop - start,
      'type': type,
    };

    final rows = galTvGuideRows(
      channels: [
        channel([
          slot(0, 30000, id: 's1'),
          gap(30000, 60000, 'flex'),
        ]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries.map((e) => e.title).toList(), ['Schindler’s List', '']);
    // The gap keeps its place on the time axis.
    expect(rows.single.entries.last.duration, const Duration(seconds: 30));
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

  test('an Other Videos cell the channel schedules itself is programming, not an ad', () {
    // The owner's `TEST FILLERS` channel runs three clips from an `Other Videos`
    // library as its own content. Library type alone called every one of them an
    // ad and put ad chrome and an UP NEXT button over his clips (2026-10-09);
    // provenance — is this a program the channel itself carries — is what tells
    // them from the fillers Tunarr drops into its breaks.
    final rows = galTvGuideRows(
      channels: [
        channel([
          slot(0, 30000, id: 'clip-1', title: 'Nemo danseaza', externalId: '5178', programType: 'other_video'),
          slot(30000, 60000, id: 'clip-2', title: 'full', externalId: '5179', programType: 'other_video'),
        ]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
      ownOtherVideoIdsByChannel: const {
        'ch-1': {'clip-1'},
      },
    );

    expect(rows.single.entries[0].isFiller, isFalse, reason: 'clip-1 is the channel’s own content');
    expect(rows.single.entries[1].isFiller, isTrue, reason: 'clip-2 is not scheduled by the channel');
  });

  test('a channel with no own-Other-Videos set still treats other_video as an ad', () {
    final rows = galTvGuideRows(
      channels: [
        channel([slot(0, 30000, id: 'ad-1', title: 'adidas', externalId: '5220', programType: 'other_video')]),
      ],
      windowStart: windowStart,
      windowEnd: windowEnd,
    );

    expect(rows.single.entries.single.isFiller, isTrue);
  });
}
