import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/tunarr/tunarr_client.dart';
import 'package:plezy/services/tunarr/tunarr_exceptions.dart';
import 'package:plezy/services/tunarr/tunarr_http_client.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

TunarrClient _client(MockClient mock) => TunarrClient(
  http: TunarrHttpClient(baseUrl: 'https://gate.example.com', plexToken: 'plex-token', httpClient: mock),
);

void main() {
  group('TunarrClient.fetchChannels', () {
    test('parses the channel list, coercing int and String numbers', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.toString(), 'https://gate.example.com/api/channels');
          return _json(<Object?>[
            <String, Object?>{
              'number': 1,
              'name': 'Tom Cruise',
              'id': '4c3a112a-0000',
              'icon': {'path': '/icons/tc.png'},
              'programCount': 6,
            },
            <String, Object?>{'number': '2', 'name': 'Sci-Fi', 'id': 'b', 'programCount': 0},
          ]);
        }),
      );

      final channels = await client.fetchChannels();
      expect(channels, hasLength(2));
      expect(channels[0].number, '1');
      expect(channels[0].name, 'Tom Cruise');
      expect(channels[0].iconPath, '/icons/tc.png');
      expect(channels[0].programCount, 6);
      expect(channels[1].number, '2');
      client.dispose();
    });

    test('maps a 500 to a typed failure', () async {
      final client = _client(MockClient((request) async => _json({'error': 'boom'}, status: 500)));

      await expectLater(client.fetchChannels(), throwsA(isA<TunarrApiException>()));
      client.dispose();
    });
  });

  group('TunarrClient.fetchNowPlaying', () {
    test('parses current and a null next', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.toString(), 'https://gate.example.com/api/channels/4c3a112a-0000/native-playback');
          return _json(<String, Object?>{
            'serverTimeMs': 1791121712873,
            'current': <String, Object?>{
              'itemStartedAtMs': 1791119000000,
              'remainingMs': 5955831,
              'type': 'content',
              'seekOffsetMs': 2972873,
              'programId': 'faa640a4-0000',
              'title': 'All Quiet on the Western Front',
            },
            'next': null,
          });
        }),
      );

      final nowPlaying = await client.fetchNowPlaying('4c3a112a-0000');
      expect(nowPlaying, isNotNull);
      expect(nowPlaying!.serverTimeMs, 1791121712873);
      expect(nowPlaying.next, isNull);
      expect(nowPlaying.current!.isPlayable, isTrue);
      client.dispose();
    });

    test('returns null on 404 instead of throwing', () async {
      final client = _client(MockClient((request) async => http.Response('', 404)));

      expect(await client.fetchNowPlaying('empty'), isNull);
      client.dispose();
    });
  });

  group('TunarrClient.fetchPlexRatingKey', () {
    test('returns the program externalId', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.toString(), 'https://gate.example.com/api/programs/faa640a4-0000');
          return _json(<String, Object?>{'title': 'All Quiet', 'externalId': '466'});
        }),
      );

      expect(await client.fetchPlexRatingKey('faa640a4-0000'), '466');
      client.dispose();
    });

    test('returns null when the program carries no externalId', () async {
      final client = _client(MockClient((request) async => _json(<String, Object?>{'title': 'All Quiet'})));

      expect(await client.fetchPlexRatingKey('p'), isNull);
      client.dispose();
    });
  });

  group('TunarrClient.fetchLineups', () {
    test('sends UTC ISO window with includePrograms=true and reads nested program.externalId', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.path, '/api/channels/all/lineups');
          expect(request.url.queryParameters['includePrograms'], 'true');
          expect(request.url.queryParameters['from'], '2026-10-04T00:00:00.000Z');
          expect(request.url.queryParameters['to'], '2026-10-05T00:00:00.000Z');
          return _json(<Object?>[
            <String, Object?>{
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
                  'program': <String, Object?>{'title': 'All Quiet', 'externalId': '466'},
                },
              ],
            },
          ]);
        }),
      );

      final lineups = await client.fetchLineups(
        from: DateTime.utc(2026, 10, 4),
        to: DateTime.utc(2026, 10, 5),
      );
      expect(lineups, hasLength(1));
      expect(lineups.single.slots.single.program!.externalId, '466');
      client.dispose();
    });
  });
}
