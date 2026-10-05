import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';

/// The guide grid only ever carries what the overlay needs to draw: a title, a
/// time range, and — for the cell's backdrop — the **Plex ratingKey**, which is
/// `program.externalId`. A `flex` break has no Plex identity and must not
/// pretend to.
void main() {
  TunarrLineupChannel channel(List<Map<String, Object?>> programs) => TunarrLineupChannel(
    id: 'ch-1',
    name: 'War Movies',
    number: '1',
    slots: programs.map(TunarrLineupSlot.fromJson).toList(),
  );

  test('a playable slot carries its Plex ratingKey through to the cell', () {
    final rows = galTvGuideRows(
      channels: [
        channel([
          {
            'id': 'slot-a',
            'start': 0,
            'stop': 60000,
            'duration': 60000,
            'type': 'content',
            'program': {'title': 'Schindler\u2019s List', 'externalId': '466'},
          },
        ]),
      ],
    );

    expect(rows.single.entries.single.ratingKey, '466');
  });

  test('a flex break has no ratingKey, even if the body carries one', () {
    final rows = galTvGuideRows(
      channels: [
        channel([
          {
            'id': 'slot-b',
            'start': 0,
            'stop': 60000,
            'duration': 60000,
            'type': 'flex',
            'program': {'title': 'Commercial Break', 'externalId': '466'},
          },
        ]),
      ],
    );

    expect(rows.single.entries.single.ratingKey, isNull);
    expect(rows.single.entries.single.isPlayable, isFalse);
  });
}
