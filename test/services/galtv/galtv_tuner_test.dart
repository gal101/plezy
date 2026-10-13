import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';
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

  group('GalTvTuner.probe', () {
    test('reads the item sequence: the item on air and the one that follows it', () async {
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
              'next': <String, Object?>{
                'programId': 'ef0cd06f-1f6b-4dd6-9d1f-2b0b1a1d0001',
                'seekOffsetMs': 0,
                'remainingMs': 61162,
                'type': 'content',
                'title': 'mid-60s - Tide',
              },
            });
          }
          if (request.url.path.startsWith('/api/programs/')) {
            final id = request.url.pathSegments.last;
            return _json(<String, Object?>{'externalId': id == 'faa640a4-16cc-4b50-8136-b9a8f3f5ebc8' ? '466' : '5176'});
          }
          return _json(<String, Object?>{}, status: 404);
        }),
      );

      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'));

      expect(result, isNotNull);
      final plan = result!.plan;
      expect(plan, isNotNull);
      expect(plan!.plexRatingKey, '466');
      expect(plan.programId, 'faa640a4-16cc-4b50-8136-b9a8f3f5ebc8');
      expect(plan.seekOffset, const Duration(milliseconds: 2972873));
      expect(plan.remainingMs, 5955831);
      expect(plan.title, 'All Quiet on the Western Front');
      expect(plan.channel.name, 'Tom Cruise');
      expect(result.serverTimeMs, 1791121712873);

      // The whole point of the type: the item that follows arrives in the same
      // read, resolved, so the boundary needs no further `native-playback` call.
      final next = result.next?.plan;
      expect(next, isNotNull);
      expect(next!.plexRatingKey, '5176');
      expect(next.title, 'mid-60s - Tide');

      expect(requests, [
        'https://gate.example.com/api/channels/chan-1/native-playback',
        'https://gate.example.com/api/programs/faa640a4-16cc-4b50-8136-b9a8f3f5ebc8',
        'https://gate.example.com/api/programs/ef0cd06f-1f6b-4dd6-9d1f-2b0b1a1d0001',
      ]);
      client.dispose();
    });

    test('a flex step is a wait of its own length, never a Plex lookup', () async {
      var programLookups = 0;
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{'remainingMs': 60000, 'type': 'flex'},
              'next': null,
            });
          }
          programLookups += 1;
          return _json(<String, Object?>{'externalId': '999'});
        }),
      );

      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'));

      expect(result, isNotNull);
      expect(result!.plan, isNull);
      expect(result.current.isPlayable, isFalse);
      expect(result.current.waitFor, const Duration(seconds: 60));
      expect(programLookups, 0, reason: 'a break has no Plex identity, so it must never reach the resolver');
      client.dispose();
    });

    test('a gap carries the ad that becomes playable when it runs out', () async {
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{'remainingMs': 57506, 'type': 'flex'},
              'next': <String, Object?>{
                'programId': 'a44d51fd-bec1-4342-bf04-e1e0b04907f0',
                'seekOffsetMs': 0,
                'remainingMs': 60629,
                'type': 'content',
                'title': 'mid-60s - Sucrets',
              },
            });
          }
          return _json(<String, Object?>{'externalId': '5175'});
        }),
      );

      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'));

      expect(result!.current.waitFor, const Duration(milliseconds: 57506));
      expect(result.next?.plan?.plexRatingKey, '5175');
      expect(result.next?.plan?.title, 'mid-60s - Sucrets');
      client.dispose();
    });

    test('a content item whose program carries no externalId becomes a wait, not a plan', () async {
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{'programId': 'p1', 'seekOffsetMs': 5, 'remainingMs': 10000, 'type': 'content'},
              'next': null,
            });
          }
          return _json(<String, Object?>{'title': 'no external id here'});
        }),
      );

      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'One'));

      expect(result, isNotNull);
      expect(result!.plan, isNull);
      expect(result.current.waitFor, const Duration(seconds: 10));
      client.dispose();
    });

    test('a channel with no schedule (404) resolves to null rather than throwing', () async {
      final client = _client(MockClient((request) async => _json(<String, Object?>{'error': 'not found'}, status: 404)));

      expect(await GalTvTuner(client: client).probe(_channel('empty', 7, 'Empty')), isNull);
      client.dispose();
    });
  });

  /// The **Hide ads** setting. A filler is a real, playable item the viewer has
  /// asked not to see, so the tuner turns it into a *wait* of its own length
  /// rather than dropping it: the break is still spent, the slate stays up, and
  /// the programme after it starts at its scheduled second.
  ///
  /// Everything here turns on `GalTvTunePlan.isFiller` — an `Other Videos` item
  /// the channel does **not** schedule itself (see `galTvProgramIsFiller`). These
  /// mocks answer no channel-content lookup, so the coarse half of the rule is
  /// what applies; the group below covers the provenance half.
  group('GalTvTuner.probe with hideFillers', () {
    /// A channel mid-break: the item on air is the ad Tunarr picked, and the item
    /// after it is the film the break is holding up.
    TunarrClient adThenFilm() => _client(
      MockClient((request) async {
        if (request.url.path.endsWith('/native-playback')) {
          return _json(<String, Object?>{
            'serverTimeMs': 1,
            'current': <String, Object?>{
              'programId': 'ad-1',
              'seekOffsetMs': 0,
              'remainingMs': 31240,
              'type': 'content',
              'title': 'Netflix 2014 - Hold On',
            },
            'next': <String, Object?>{
              'programId': 'film-1',
              'seekOffsetMs': 0,
              'remainingMs': 7200000,
              'type': 'content',
              'title': 'All Quiet on the Western Front',
            },
          });
        }
        final id = request.url.pathSegments.last;
        return _json(<String, Object?>{
          'externalId': id == 'ad-1' ? '5200' : '466',
          'type': id == 'ad-1' ? 'other_video' : 'movie',
        });
      }),
    );

    test('an Other Videos item plays when the setting is off', () async {
      final client = adThenFilm();
      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'));

      expect(result!.plan?.plexRatingKey, '5200');
      client.dispose();
    });

    /// The chrome offers the Up-Next slate for the whole ad, so the player has to be
    /// told an item is a filler even when fillers are allowed to play — the flag is
    /// not merely an input to `hideFillers`.
    test('the plan says whether the item is a filler, whether or not it plays', () async {
      final client = adThenFilm();
      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'));

      expect(result!.plan?.isFiller, isTrue);
      expect(result.next?.plan?.isFiller, isFalse, reason: 'the film after the break is a programme');
      client.dispose();
    });

    test('an Other Videos item becomes a wait of its own length when the setting is on', () async {
      final client = adThenFilm();
      final result = await GalTvTuner(client: client)
          .probe(_channel('chan-1', 1, 'Tom Cruise'), hideFillers: true);

      expect(result!.current.isPlayable, isFalse);
      expect(result.current.waitFor, const Duration(milliseconds: 31240));
      // The item after the ad is real content, so the same read still arms it —
      // the chained waits this creates need no extra `native-playback` call.
      expect(result.next?.plan?.plexRatingKey, '466');
      client.dispose();
    });

    test('hiding ads never touches real content', () async {
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('/native-playback')) {
            return _json(<String, Object?>{
              'serverTimeMs': 1,
              'current': <String, Object?>{
                'programId': 'film-1',
                'seekOffsetMs': 0,
                'remainingMs': 1000,
                'type': 'content',
                'title': 'All Quiet',
              },
              'next': null,
            });
          }
          return _json(<String, Object?>{'externalId': '466', 'type': 'movie'});
        }),
      );

      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 1, 'Tom Cruise'), hideFillers: true);

      expect(result!.plan?.plexRatingKey, '466');
      client.dispose();
    });
  });

  /// The **provenance** half of the filler rule, reported from the owner's own
  /// channel layout on 2026-10-09: `TEST FILLERS` schedules three clips from an
  /// `Other Videos` library as its **programming**, so a library-typed rule put ad
  /// chrome and an UP NEXT button over clips he was watching as content while the
  /// real ads were indistinguishable from them.
  ///
  /// The discriminator is `GET /api/channels/{id}/programs?type=other_video` — the
  /// programs the channel itself carries — and these tests are the two sides of it.
  group('GalTvTuner.probe and a channel whose own programming is Other Videos', () {
    TunarrClient clipsChannel({required bool schedulesTheClip}) => _client(
      MockClient((request) async {
        if (request.url.path.endsWith('/native-playback')) {
          return _json(<String, Object?>{
            'serverTimeMs': 1,
            'current': <String, Object?>{
              'programId': 'clip-1',
              'seekOffsetMs': 0,
              'remainingMs': 30064,
              'type': 'content',
              'title': 'Nemo danseaza',
            },
            'next': null,
          });
        }
        if (request.url.path.endsWith('/programs')) {
          expect(request.url.queryParameters['type'], 'other_video');
          return _json(<String, Object?>{
            'total': schedulesTheClip ? 1 : 0,
            'result': schedulesTheClip
                ? <Object?>[
                    <String, Object?>{'uuid': 'clip-1', 'type': 'other_video'},
                  ]
                : <Object?>[],
          });
        }
        return _json(<String, Object?>{'externalId': '5178', 'type': 'other_video'});
      }),
    );

    test('an Other Videos item the channel schedules is a programme, not an ad', () async {
      final client = clipsChannel(schedulesTheClip: true);
      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 3, 'TEST FILLERS'));

      expect(result!.plan?.isFiller, isFalse);
      expect(result.plan?.plexRatingKey, '5178');
      client.dispose();
    });

    test('an Other Videos item the channel does not schedule is an ad', () async {
      final client = clipsChannel(schedulesTheClip: false);
      final result = await GalTvTuner(client: client).probe(_channel('chan-1', 3, 'TEST FILLERS'));

      expect(result!.plan?.isFiller, isTrue);
      client.dispose();
    });

    test('hideFillers leaves the channel its own clips and waits out the ads', () async {
      final ownClip = await GalTvTuner(client: clipsChannel(schedulesTheClip: true))
          .probe(_channel('chan-1', 3, 'TEST FILLERS'), hideFillers: true);
      expect(ownClip!.current.isPlayable, isTrue, reason: 'the channel’s own clip is programming');

      final ad = await GalTvTuner(client: clipsChannel(schedulesTheClip: false))
          .probe(_channel('chan-1', 3, 'TEST FILLERS'), hideFillers: true);
      expect(ad!.current.isPlayable, isFalse);
      expect(ad.current.waitFor, const Duration(milliseconds: 30064));
    });
  });

  /// The per-channel lookup the **guide rows** and the Home shelf need, where the
  /// caller maps a whole lineup rather than one plan.
  group('GalTvTuner.ownOtherVideoIdsByChannel', () {
    TunarrLineupChannel lineup(String id, List<String?> programTypes) => TunarrLineupChannel(
      id: id,
      name: id,
      number: '1',
      slots: [
        for (var index = 0; index < programTypes.length; index++)
          TunarrLineupSlot(
            id: '$id-$index',
            start: index * 1000,
            stop: (index + 1) * 1000,
            duration: 1000,
            type: 'content',
            program: TunarrProgram(title: id, externalId: '$index', type: programTypes[index]),
          ),
      ],
    );

    test('asks only the channels whose lineup carries an other_video program', () async {
      final asked = <String>[];
      final client = _client(
        MockClient((request) async {
          final channelId = request.url.pathSegments[2];
          asked.add(channelId);
          return _json(<String, Object?>{
            'total': 1,
            'result': <Object?>[
              <String, Object?>{'uuid': '$channelId-own'},
            ],
          });
        }),
      );

      final ids = await GalTvTuner(client: client).ownOtherVideoIdsByChannel([
        lineup('clips', const ['other_video', 'other_video']),
        lineup('films', const ['movie']),
        lineup('tv', const ['episode']),
      ]);

      expect(asked, ['clips']);
      expect(ids, {
        'clips': {'clips-own'},
      });
      client.dispose();
    });

    test('a deployment of films and episodes costs no call at all', () async {
      var calls = 0;
      final client = _client(
        MockClient((request) async {
          calls++;
          return _json(<String, Object?>{'total': 0, 'result': const <Object?>[]});
        }),
      );

      final ids = await GalTvTuner(client: client)
          .ownOtherVideoIdsByChannel([lineup('films', const ['movie']), lineup('tv', const ['episode'])]);

      expect(ids, isEmpty);
      expect(calls, 0);
      client.dispose();
    });
  });

  group('galTvArmIsDue', () {
    final due = DateTime(2026, 10, 8, 12, 0, 0);

    test('accepts an arm inside the tolerance on either side, and refuses one beyond it', () {
      expect(galTvArmIsDue(due, DateTime(2026, 10, 8, 12, 0, 19)), isTrue);
      expect(galTvArmIsDue(due, DateTime(2026, 10, 8, 11, 59, 45)), isTrue);
      expect(galTvArmIsDue(due, DateTime(2026, 10, 8, 12, 0, 21)), isFalse);
      expect(galTvArmIsDue(due, DateTime(2026, 10, 8, 11, 59, 30)), isFalse);
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
