import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';
import 'package:plezy/models/tunarr/tunarr_now_playing.dart';

void main() {
  group('TunarrChannel', () {
    test('parses an int number defensively into a String', () {
      final channel = TunarrChannel.fromJson(<String, Object?>{
        'number': 1,
        'name': 'Tom Cruise',
        'id': '4c3a112a-0000',
        'icon': {'path': '/icons/tc.png'},
        'programCount': 6,
      });

      expect(channel.number, '1');
      expect(channel.name, 'Tom Cruise');
      expect(channel.id, '4c3a112a-0000');
      expect(channel.iconPath, '/icons/tc.png');
      expect(channel.programCount, 6);
    });

    test('parses a String number and a bare-string icon', () {
      final channel = TunarrChannel.fromJson(<String, Object?>{
        'number': '7',
        'name': 'Movies',
        'id': 'abc',
        'icon': 'https://example.com/i.png',
      });

      expect(channel.number, '7');
      expect(channel.iconPath, 'https://example.com/i.png');
      expect(channel.programCount, 0);
    });

    test('encode/decode round-trips', () {
      const channel = TunarrChannel(id: 'x', name: 'Y', number: '3', iconPath: '/i.png', programCount: 9);
      final decoded = TunarrChannel.decode(channel.encode());

      expect(decoded.id, 'x');
      expect(decoded.name, 'Y');
      expect(decoded.number, '3');
      expect(decoded.iconPath, '/i.png');
      expect(decoded.programCount, 9);
    });
  });

  group('TunarrPlaybackItem.isPlayable', () {
    TunarrPlaybackItem item(String type) => TunarrPlaybackItem(
      programId: 'p',
      seekOffsetMs: 0,
      remainingMs: 0,
      itemStartedAtMs: 0,
      type: type,
    );

    test('is true for content and custom only', () {
      expect(item('content').isPlayable, isTrue);
      expect(item('custom').isPlayable, isTrue);
      expect(item('redirect').isPlayable, isFalse);
      expect(item('flex').isPlayable, isFalse);
    });
  });

  group('TunarrNowPlaying', () {
    test('parses a null next', () {
      final nowPlaying = TunarrNowPlaying.fromJson(<String, Object?>{
        'serverTimeMs': 1791121712873,
        'current': <String, Object?>{
          'itemStartedAtMs': 1791119000000,
          'remainingMs': 5955831,
          'type': 'content',
          'seekOffsetMs': 2972873,
          'programId': 'faa640a4-0000',
          'title': 'All Quiet on the Western Front',
          'summary': 'A war film.',
        },
        'next': null,
      });

      expect(nowPlaying.serverTimeMs, 1791121712873);
      expect(nowPlaying.next, isNull);
      expect(nowPlaying.current, isNotNull);
      expect(nowPlaying.current!.programId, 'faa640a4-0000');
      expect(nowPlaying.current!.title, 'All Quiet on the Western Front');
      expect(nowPlaying.current!.seekOffsetMs, 2972873);
      expect(nowPlaying.current!.remainingMs, 5955831);
      expect(nowPlaying.current!.itemStartedAtMs, 1791119000000);
      expect(nowPlaying.current!.isPlayable, isTrue);
    });
  });

  group('TunarrLineupSlot.isPlayable', () {
    TunarrLineupSlot slot(String type) =>
        TunarrLineupSlot(id: 's', start: 0, stop: 0, duration: 0, type: type);

    test('is true for content and custom, false for redirect and flex', () {
      expect(slot('content').isPlayable, isTrue);
      expect(slot('custom').isPlayable, isTrue);
      expect(slot('redirect').isPlayable, isFalse);
      expect(slot('flex').isPlayable, isFalse);
    });
  });

  group('TunarrLineupChannel', () {
    test('reads externalId from the NESTED program object', () {
      final lineup = TunarrLineupChannel.fromJson(<String, Object?>{
        'id': '4c3a112a-0000',
        'name': 'Tom Cruise',
        'number': 1,
        'programs': <Object?>[
          <String, Object?>{
            'id': 'faa640a4-0000',
            'start': 1791119000000,
            'stop': 1791127000000,
            'duration': 8000000,
            'type': 'content',
            'program': <String, Object?>{
              'title': 'All Quiet on the Western Front',
              'externalId': '466',
              'summary': 'A war film.',
              'type': 'movie',
              'year': 1930,
              'durationMs': 8000000,
            },
          },
        ],
      });

      expect(lineup.slots, hasLength(1));
      final program = lineup.slots.single.program;
      expect(program, isNotNull);
      expect(program!.externalId, '466');
      expect(program.title, 'All Quiet on the Western Front');
      expect(program.year, 1930);
      expect(program.durationMs, 8000000);
    });

    test('a flat slot (no nested program) yields a null program', () {
      final lineup = TunarrLineupChannel.fromJson(<String, Object?>{
        'id': 'c',
        'name': 'N',
        'number': 1,
        'programs': <Object?>[
          <String, Object?>{'id': 's', 'start': 0, 'stop': 1, 'duration': 1, 'type': 'flex'},
        ],
      });

      expect(lineup.slots.single.program, isNull);
      expect(lineup.slots.single.isPlayable, isFalse);
    });

    test('reads the nested channel icon', () {
      final lineup = TunarrLineupChannel.fromJson(<String, Object?>{
        'id': 'c',
        'name': 'N',
        'number': 1,
        'icon': {'path': '/images/uploads/logo.png'},
        'programs': const <Object?>[],
      });

      expect(lineup.iconPath, '/images/uploads/logo.png');
    });
  });

  group('TunarrProgram', () {
    test('absent externalId stays null', () {
      final program = TunarrProgram.tryParse(<String, Object?>{'title': 'X'});
      expect(program, isNotNull);
      expect(program!.externalId, isNull);
    });

    test('tryParse rejects a non-map', () {
      expect(TunarrProgram.tryParse(null), isNull);
      expect(TunarrProgram.tryParse('nope'), isNull);
    });
  });

  group('resolveTunarrIconUrl', () {
    const gate = 'https://gate.example:10000';

    test('re-points a Tunarr-served /images/ upload at the gate', () {
      // Tunarr stores an upload as an absolute URL on its own host; only the gate
      // is reachable from the client.
      expect(
        resolveTunarrIconUrl('http://192.168.100.149:8000/images/uploads/ab12.png', gate),
        '$gate/images/uploads/ab12.png',
      );
      expect(resolveTunarrIconUrl('/images/tunarr.png', gate), '$gate/images/tunarr.png');
    });

    test('uses a third-party URL as-is', () {
      expect(
        resolveTunarrIconUrl('https://cdn.example/logo.png', gate),
        'https://cdn.example/logo.png',
      );
    });

    test('returns null without an icon, and without a base for a relative path', () {
      expect(resolveTunarrIconUrl(null, gate), isNull);
      expect(resolveTunarrIconUrl('   ', gate), isNull);
      expect(resolveTunarrIconUrl('/images/x.png', null), isNull);
    });
  });
}
