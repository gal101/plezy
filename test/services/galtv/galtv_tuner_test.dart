import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/services/galtv/galtv_tuner.dart';
import 'package:plezy/services/tunarr/tunarr_client.dart';
import 'package:plezy/services/tunarr/tunarr_http_client.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

TunarrClient _client(MockClient mock) => TunarrClient(
  http: TunarrHttpClient(baseUrl: 'https://gate.example.com', plexToken: 'plex-token', httpClient: mock),
);

TunarrChannel _channel(String id, Object number, String name) =>
    TunarrChannel.fromJson(<String, Object?>{'id': id, 'number': number, 'name': name});

void main() {
  group('GalTvTuner.pickInitialChannel', () {
    test('returns the remembered channel when it still exists', () {
      final channels = [_channel('a', 1, 'One'), _channel('b', 2, 'Two')];

      expect(GalTvTuner.pickInitialChannel(channels, 'b')?.id, 'b');
    });

    test('falls back to the lowest-numbered channel, not list order', () {
      final channels = [_channel('nine', 9, 'Nine'), _channel('one', 1, 'One'), _channel('five', 5, 'Five')];

      expect(GalTvTuner.pickInitialChannel(channels, null)?.id, 'one');
    });

    test('ignores a remembered channel that no longer exists', () {
      final channels = [_channel('a', 1, 'One')];

      expect(GalTvTuner.pickInitialChannel(channels, 'deleted')?.id, 'a');
    });

    test('treats an empty remembered id as "never tuned"', () {
      final channels = [_channel('a', 1, 'One'), _channel('b', 2, 'Two')];

      expect(GalTvTuner.pickInitialChannel(channels, '')?.id, 'a');
    });

    test('returns null for an empty channel list', () {
      expect(GalTvTuner.pickInitialChannel(const [], 'a'), isNull);
    });
  });

  group('GalTvTuner.planFor', () {
    test('joins now-playing -> program -> Plex ratingKey and keeps the server offset', () async {
      final requests = <String>[];
      final client = _client(
        MockClient((request) async {
          requests.add(request.url.toString());
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1791121712873,
              'current': <String, Object?>{
                'programId': 'faa640a4-16cc-4b50-8136-b9a8f3f5ebc8',
                'seekOffsetMs': 2972873,
                'remainingMs': 5955831,
                'itemStartedAtMs': 1791118740000,
                'type': 'content',
                'title': 'All Quiet on the Western Front',
              },
              'next': <String, Object?>{'programId': 'ef0cd06f', 'type': 'content'},
            });
          }
          if (request.url.path.startsWith('/api/programs/')) {
            return _json(<String, Object?>{'externalId': '466', 'title': 'All Quiet on the Western Front'});
          }
          return _json(<String, Object?>{}, status: 404);
        }),
      );

      final plan = await GalTvTuner(client: client).planFor(_channel('chan-1', 1, 'Tom Cruise'));

      expect(plan, isNotNull);
      expect(plan!.plexRatingKey, '466');
      expect(plan.programId, 'faa640a4-16cc-4b50-8136-b9a8f3f5ebc8');
      expect(plan.seekOffset, const Duration(milliseconds: 2972873));
      expect(plan.remainingMs, 5955831);
      expect(plan.title, 'All Quiet on the Western Front');
      expect(plan.channel.name, 'Tom Cruise');
      expect(requests, [
        'https://gate.example.com/api/channels/chan-1/native-playback',
        'https://gate.example.com/api/programs/faa640a4-16cc-4b50-8136-b9a8f3f5ebc8',
      ]);
      client.dispose();
    });

    test('a flex slot resolves to null without asking Plex for a ratingKey', () async {
      var programLookups = 0;
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{'programId': 'flex-1', 'seekOffsetMs': 0, 'remainingMs': 60000, 'type': 'flex'},
              'next': null,
            });
          }
          programLookups += 1;
          return _json(<String, Object?>{'externalId': '999'});
        }),
      );

      final plan = await GalTvTuner(client: client).planFor(_channel('chan-1', 1, 'Tom Cruise'));

      expect(plan, isNull);
      expect(programLookups, 0, reason: 'a break has no Plex identity, so it must never reach the resolver');
      client.dispose();
    });

    test('returns null when the program carries no externalId', () async {
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{'programId': 'p1', 'seekOffsetMs': 5, 'remainingMs': 10, 'type': 'content'},
              'next': null,
            });
          }
          return _json(<String, Object?>{'title': 'no external id here'});
        }),
      );

      expect(await GalTvTuner(client: client).planFor(_channel('chan-1', 1, 'One')), isNull);
      client.dispose();
    });

    test('a channel with no schedule (404) resolves to null rather than throwing', () async {
      final client = _client(MockClient((request) async => _json(<String, Object?>{'error': 'not found'}, status: 404)));

      expect(await GalTvTuner(client: client).planFor(_channel('empty', 7, 'Empty')), isNull);
      client.dispose();
    });
  });

  group('GalTvTuner channel order', () {
    final shuffled = [
      _channel('c30', 30, 'Late'),
      _channel('c2', 2, 'Two'),
      _channel('cX', 'HD', 'Non-numeric'),
      _channel('c10', 10, 'Ten'),
    ];

    test('sorts by channel number, not wire order, with non-numeric ids last', () {
      expect(GalTvTuner.sortedByNumber(shuffled).map((c) => c.id), ['c2', 'c10', 'c30', 'cX']);
    });

    test('coerces a string channel number', () {
      final channels = [_channel('a', '10', 'Ten'), _channel('b', 9, 'Nine')];
      expect(GalTvTuner.sortedByNumber(channels).map((c) => c.id), ['b', 'a']);
    });

    test('channelById finds a hit and tolerates unknown/missing ids', () {
      expect(GalTvTuner.channelById(shuffled, 'c10')?.name, 'Ten');
      expect(GalTvTuner.channelById(shuffled, 'nope'), isNull);
      expect(GalTvTuner.channelById(shuffled, ''), isNull);
      expect(GalTvTuner.channelById(shuffled, null), isNull);
    });

    test('neighbour steps through surf order and clamps at both ends', () {
      expect(GalTvTuner.neighbour(shuffled, 'c2', 1)?.id, 'c10');
      expect(GalTvTuner.neighbour(shuffled, 'c30', 1)?.id, 'cX');
      expect(GalTvTuner.neighbour(shuffled, 'c10', -1)?.id, 'c2');
      expect(GalTvTuner.neighbour(shuffled, 'c2', -1), isNull, reason: 'no wrap-around at the first channel');
      expect(GalTvTuner.neighbour(shuffled, 'cX', 1), isNull, reason: 'no wrap-around at the last channel');
    });

    test('neighbour refuses an unknown current channel, a zero step, and an empty list', () {
      expect(GalTvTuner.neighbour(shuffled, 'ghost', 1), isNull);
      expect(GalTvTuner.neighbour(shuffled, 'c2', 0), isNull);
      expect(GalTvTuner.neighbour(const [], 'c2', 1), isNull);
    });
  });
}
