import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/galtv/galtv_favorites.dart';
import 'package:plezy/services/galtv/galtv_favorites_sync.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/tunarr/tunarr_client.dart';
import 'package:plezy/services/tunarr/tunarr_http_client.dart';

import '../../test_helpers/prefs.dart';

/// A scripted gate: it answers `GET /galtv/favorites` from its own list and
/// records every write, so a test can tell "adopted" from "pushed".
class _FakeGate {
  _FakeGate({
    List<String> channels = const [],
    this.getStatus = 200,
    this.errorCode = 'boom',
    List<int> putStatuses = const [204],
  }) : channels = [...channels],
       putStatuses = [...putStatuses];

  final List<String> channels;
  final int getStatus;

  /// The gate's JSON `error` code on a refusal — `path-not-allowed` is what an
  /// older gate answers the favourites route with.
  final String errorCode;

  /// One answer per write attempt (`the last one repeats if the calls run past it`).
  final List<int> putStatuses;

  int getCalls = 0;
  int putCalls = 0;
  final List<String> paths = [];
  final List<List<String>> writes = [];

  late final MockClient mock = MockClient((request) async {
    paths.add(request.url.path);
    if (request.method == 'GET') {
      getCalls += 1;
      if (getStatus != 200) return _json({'error': errorCode}, status: getStatus);
      return _json({'channels': channels});
    }

    putCalls += 1;
    final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
    writes.add((body['channels'] as List).cast<String>());
    final status = putStatuses[putCalls - 1 < putStatuses.length ? putCalls - 1 : putStatuses.length - 1];
    if (status >= 200 && status < 300) {
      channels
        ..clear()
        ..addAll(writes.last);
      return http.Response('', status);
    }
    return _json({'error': errorCode}, status: status);
  });
}

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

GalTvFavoritesSync _syncFor(_FakeGate gate, {int plexId = 42, List<Duration> retryDelays = const []}) =>
    GalTvFavoritesSync(
      client: TunarrClient(
        http: TunarrHttpClient(baseUrl: 'https://gate.example.com', plexToken: 'plex-token', httpClient: gate.mock),
      ),
      plexId: plexId,
      retryDelays: retryDelays,
    );

List<String> _cached() => GalTvFavorites.read(SettingsService.instance);

Future<void> _seedCache(List<String> channels, {String owner = ''}) async {
  await SettingsService.instance.write(SettingsService.galtvFavoriteChannelIds, channels);
  await SettingsService.instance.write(SettingsService.galtvFavoritesCacheOwner, owner);
}

/// The pinned product rule: one Plex account's favourites, on every device.
void main() {
  setUp(() {
    resetSharedPreferencesForTest();
  });

  test('a pull adopts the account’s list, and reads it from the gate', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(channels: ['ch-2', 'ch-9']);
    await _seedCache(['ch-1']);

    final resolved = await _syncFor(gate).pull();

    expect(resolved, ['ch-2', 'ch-9']);
    expect(_cached(), ['ch-2', 'ch-9'], reason: 'the cache follows the account');
    expect(gate.paths, ['/galtv/favorites']);
    expect(gate.putCalls, 0, reason: 'nothing to push: the account already has a list');
    expect(SettingsService.instance.read(SettingsService.galtvFavoritesCacheOwner), '42');
  });

  test('the first sync pushes a list this device built instead of wiping it', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate();
    await _seedCache(['ch-3', 'ch-4']);

    final resolved = await _syncFor(gate).pull();

    expect(resolved, ['ch-3', 'ch-4'], reason: 'the list made on the TV survives the first sign-in');
    expect(gate.writes, [
      ['ch-3', 'ch-4'],
    ]);
    expect(_cached(), ['ch-3', 'ch-4']);
    expect(SettingsService.instance.read(SettingsService.galtvFavoritesCacheOwner), '42');
  });

  test('a cache belonging to another Plex user is never pushed at this one', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(channels: ['ch-7']);
    await _seedCache(['ch-1'], owner: '99');

    final resolved = await _syncFor(gate, plexId: 42).pull();

    expect(gate.putCalls, 0, reason: 'profile B must not inherit profile A’s stars');
    expect(resolved, ['ch-7']);
    expect(_cached(), ['ch-7']);
    expect(SettingsService.instance.read(SettingsService.galtvFavoritesCacheOwner), '42');
  });

  test('a gate without the routes leaves the device-local list exactly as it is', () async {
    await SettingsService.getInstance();
    // What an older gate answers: the path is outside its proxy allow-list.
    final gate = _FakeGate(getStatus: 403, errorCode: 'path-not-allowed');
    await _seedCache(['ch-1']);

    expect(await _syncFor(gate).pull(), isNull);
    expect(_cached(), ['ch-1'], reason: 'no server list means local-only, not empty');
    expect(gate.putCalls, 0);
  });

  test('a write that fails is pushed again on the next pull, not overwritten', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(channels: ['ch-old'], putStatuses: [500, 204]);
    await _seedCache(['ch-1'], owner: '42');

    final sync = _syncFor(gate, retryDelays: const [Duration.zero]);
    await sync.push(['ch-old', 'ch-1']);

    expect(gate.writes.length, 2, reason: 'one retry before giving up');
    // The gate refused both? No — the second attempt landed.
    expect(gate.channels, ['ch-old', 'ch-1']);

    await sync.pull();
    expect(_cached(), ['ch-old', 'ch-1']);
  });

  test('a write that never lands is remembered, and the next pull pushes it', () async {
    await SettingsService.getInstance();
    // The first write is refused; the retry the pull makes is accepted.
    final gate = _FakeGate(channels: ['ch-old'], putStatuses: [500, 204]);
    await _seedCache(['ch-old']);

    final sync = _syncFor(gate);
    final firstPull = await sync.pull();
    expect(firstPull, ['ch-old']);

    // The viewer's toggle has already written the cache (that is what `push` is
    // told); every attempt to tell the gate fails for now.
    await _seedCache(['ch-old', 'ch-1'], owner: '42');
    expect(await sync.push(['ch-old', 'ch-1']), isFalse);
    expect(_cached(), ['ch-old', 'ch-1']);

    expect(await sync.pull(), ['ch-old', 'ch-1'], reason: 'the unsynced edit wins the next pull');
    expect(gate.writes.last, ['ch-old', 'ch-1']);
    expect(gate.channels, ['ch-old', 'ch-1'], reason: 'and it reaches the account on that pull');
  });

  test('a push the gate does not support stops there instead of retrying', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(putStatuses: [405]);
    await _seedCache(['ch-1']);

    expect(await _syncFor(gate, retryDelays: const [Duration.zero]).push(['ch-1']), isFalse);

    expect(gate.putCalls, 1, reason: 'a missing route is answered once, not hammered');
    expect(_cached(), ['ch-1']);
  });

  test('a pull that changes nothing writes nothing', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(channels: ['ch-1']);
    await _seedCache(['ch-1'], owner: '42');

    final notifications = <List<String>>[];
    SettingsService.instance.listenable(SettingsService.galtvFavoriteChannelIds).addListener(() {
      notifications.add(_cached());
    });

    await _syncFor(gate).pull();

    // Home rebuilds its shelves from exactly this notifier, so an equal-but-new
    // list would re-enter the load that asked for the pull.
    expect(notifications, isEmpty);
  });

  test('two pulls in one frame share a single read', () async {
    await SettingsService.getInstance();
    final gate = _FakeGate(channels: ['ch-1']);
    final sync = _syncFor(gate);

    final results = await Future.wait([sync.pull(), sync.pull(), sync.pull()]);

    expect(gate.getCalls, 1);
    expect(results, [
      ['ch-1'],
      ['ch-1'],
      ['ch-1'],
    ]);
  });
}
