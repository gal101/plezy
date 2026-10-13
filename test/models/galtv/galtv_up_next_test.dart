import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';

/// The break slate has one job: name the *next* programme. Two ways to get it
/// wrong, both pinned here — naming the cell the viewer is already inside (a
/// programme is "up next" only once it has started, and the break itself has no
/// Plex identity), and naming something that cannot be played.
///
/// The comparison is anchored on Tunarr's `serverTimeMs`, not the device clock,
/// because the rows carry server-authored slot times: a TV with a wrong clock
/// must still name the same programme as every other viewer.
void main() {
  GalTvGuideEntry entry({
    required int startMs,
    required int stopMs,
    String title = 'Iron Man',
    String? ratingKey = '466',
    bool isPlayable = true,
  }) => GalTvGuideEntry(
    title: title,
    start: DateTime.fromMillisecondsSinceEpoch(startMs),
    stop: DateTime.fromMillisecondsSinceEpoch(stopMs),
    ratingKey: ratingKey,
    isPlayable: isPlayable,
    isCurrent: false,
  );

  GalTvGuideRow row(String channelId, List<GalTvGuideEntry> entries) =>
      GalTvGuideRow(channelId: channelId, channelNumber: '1', channelName: 'Tom Cruise', entries: entries);

  final serverNow = DateTime.fromMillisecondsSinceEpoch(1_000_000);

  test('skips the break it is sitting in and names the programme after it', () {
    final rows = [
      row('ch-1', [
        entry(startMs: 940_000, stopMs: 1_000_000, title: 'Coca-Cola 1954'),
        entry(startMs: 940_000, stopMs: 1_000_000, title: 'Commercial Break', ratingKey: null, isPlayable: false),
        entry(startMs: 1_000_000, stopMs: 1_180_000, title: 'Iron Man'),
      ]),
    ];

    final upNext = galTvUpNext(rows, 'ch-1', serverNow);

    expect(upNext?.title, 'Iron Man');
    expect(upNext?.ratingKey, '466');
    expect(upNext?.startsAt.millisecondsSinceEpoch, 1_000_000);
  });

  test('a programme that is already running is not "up next"', () {
    final rows = [
      row('ch-1', [
        entry(startMs: 900_000, stopMs: 1_200_000, title: 'Schindler’s List', ratingKey: '1'),
        entry(startMs: 1_200_000, stopMs: 1_380_000, title: 'Iron Man'),
      ]),
    ];

    expect(galTvUpNext(rows, 'ch-1', serverNow)?.title, 'Iron Man');
  });

  test('a playable cell with no Plex identity is skipped, not offered', () {
    final rows = [
      row('ch-1', [
        entry(startMs: 1_000_000, stopMs: 1_180_000, title: 'Unresolvable', ratingKey: null),
        entry(startMs: 1_180_000, stopMs: 1_380_000, title: 'Iron Man'),
      ]),
    ];

    expect(galTvUpNext(rows, 'ch-1', serverNow)?.title, 'Iron Man');
  });

  test('another channel\'s row is ignored', () {
    final rows = [
      row('ch-2', [entry(startMs: 1_000_000, stopMs: 1_180_000, title: 'Wrong channel')]),
    ];

    expect(galTvUpNext(rows, 'ch-1', serverNow), isNull);
  });

  test('the payload names the channel it was picked for', () {
    // The slate's *label* is drawn from whatever channel is on screen, so the
    // payload has to carry its own channel for a host to refuse a stale one —
    // otherwise the card reads "CH 2 · UP NEXT <a channel 3 programme>".
    final rows = [
      row('ch-3', [entry(startMs: 1_000_000, stopMs: 1_180_000, title: 'Doritos 2013')]),
    ];

    final upNext = galTvUpNext(rows, 'ch-3', serverNow);

    expect(upNext?.channelId, 'ch-3');
    expect(upNext?.title, 'Doritos 2013');
  });

  test('returns null when the window holds nothing playable', () {
    final rows = [
      row('ch-1', [
        entry(startMs: 1_000_000, stopMs: 1_180_000, title: 'Commercial Break', ratingKey: null, isPlayable: false),
      ]),
    ];

    expect(galTvUpNext(rows, 'ch-1', serverNow), isNull);
  });

  test('returns null for a channel that is not in the fetched window at all', () {
    expect(galTvUpNext(const [], 'ch-1', serverNow), isNull);
  });
}
