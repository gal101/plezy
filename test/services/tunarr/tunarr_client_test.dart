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

  group('TunarrClient.fetchProgramRef', () {
    test('returns the program externalId and its library type', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.toString(), 'https://gate.example.com/api/programs/faa640a4-0000');
          return _json(<String, Object?>{'title': 'All Quiet', 'externalId': '466', 'type': 'movie'});
        }),
      );

      final ref = await client.fetchProgramRef('faa640a4-0000');
      expect(ref, isNotNull);
      expect(ref!.ratingKey, '466');
      expect(ref.type, 'movie');
      expect(ref.isOtherVideo, isFalse, reason: 'a film from the Movies library can never be an ad');
      client.dispose();
    });

    /// The first half of the filler discriminator: the library type. Necessary but
    /// **not** sufficient — a channel may schedule clips from an `Other Videos`
    /// library as its own programming, which is why the second half
    /// (`fetchChannelOwnOtherVideoProgramIds`) exists.
    test('flags an Other Videos program as an other_video candidate', () async {
      final client = _client(
        MockClient((request) async => _json(<String, Object?>{'externalId': '5200', 'type': 'other_video'})),
      );

      final ref = await client.fetchProgramRef('p');
      expect(ref!.isOtherVideo, isTrue);
      client.dispose();
    });

    test('returns null when the program carries no externalId', () async {
      final client = _client(MockClient((request) async => _json(<String, Object?>{'title': 'All Quiet'})));

      expect(await client.fetchProgramRef('p'), isNull);
      client.dispose();
    });
  });

  group('TunarrClient.fetchChannelOwnOtherVideoProgramIds', () {
    test('asks for the channel\'s own other_video programs and collects their uuids', () async {
      final client = _client(
        MockClient((request) async {
          expect(request.url.path, '/api/channels/chan-1/programs');
          expect(request.url.queryParameters['type'], 'other_video');
          expect(request.url.queryParameters['offset'], '0');
          return _json(<String, Object?>{
            'total': 2,
            'size': 2,
            'result': <Object?>[
              <String, Object?>{'uuid': 'clip-1', 'type': 'other_video'},
              <String, Object?>{'uuid': 'clip-2', 'type': 'other_video'},
            ],
          });
        }),
      );

      expect(await client.fetchChannelOwnOtherVideoProgramIds('chan-1'), {'clip-1', 'clip-2'});
      client.dispose();
    });

    test('pages until the server says the whole set is in', () async {
      final offsets = <String>[];
      final client = _client(
        MockClient((request) async {
          final offset = request.url.queryParameters['offset']!;
          offsets.add(offset);
          return offset == '0'
              ? _json(<String, Object?>{'total': 2, 'result': <Object?>[<String, Object?>{'uuid': 'a'}]})
              : _json(<String, Object?>{'total': 2, 'result': <Object?>[<String, Object?>{'uuid': 'b'}]});
        }),
      );

      expect(await client.fetchChannelOwnOtherVideoProgramIds('chan-1'), {'a', 'b'});
      expect(offsets, ['0', '1']);
      client.dispose();
    });

    /// A side lookup that fails must not fail a tune, and must not turn a
    /// channel's own clips into ads: the caller falls back to the coarse rule.
    test('degrades to an empty set when the route fails', () async {
      final client = _client(MockClient((request) async => http.Response('', 500)));

      expect(await client.fetchChannelOwnOtherVideoProgramIds('chan-1'), isEmpty);
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
