import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/tunarr/tunarr_session.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/prefs_recovery.dart';
import 'package:plezy/services/tunarr/tunarr_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Local in-memory prefs reset, instead of `test_helpers/prefs.dart`.
///
/// `TunarrSessionStore` only needs `BaseSharedPreferencesService`, so pulling in
/// the shared helper would drag `SettingsService` (and its navigation/i18n
/// graph) into this suite for no reason. Same platform fakes, narrower closure.
void _resetPrefs() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PrefsRecovery.debugSetSupportedPlatformOverride(false);
  SharedPreferences.setMockInitialValues({});
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  BaseSharedPreferencesService.resetForTesting();
}

TunarrSession _session({String username = 'alice', int plexId = 42}) => TunarrSession(
  baseUrl: 'https://gate.example.com',
  granted: true,
  username: username,
  email: '$username@example.com',
  plexId: plexId,
  sections: const ['Movies'],
  createdAt: 1700000000,
);

void main() {
  setUp(_resetPrefs);
  tearDown(() {
    SharedPreferences.resetStatic();
    BaseSharedPreferencesService.resetForTesting();
    PrefsRecovery.debugSetSupportedPlatformOverride(null);
  });

  group('TunarrSessionStore', () {
    const store = TunarrSessionStore();

    test('round-trips a session per profile', () async {
      final session = _session();
      await store.save('uuid-a', session);

      final loaded = await store.load('uuid-a');
      expect(loaded, isNotNull);
      expect(loaded!.encode(), session.encode());
    });

    test('isolates sessions between two profile uuids', () async {
      await store.save('uuid-a', _session(username: 'alice', plexId: 1));
      await store.save('uuid-b', _session(username: 'bob', plexId: 2));

      expect((await store.load('uuid-a'))!.username, 'alice');
      expect((await store.load('uuid-b'))!.username, 'bob');
      expect((await store.load('uuid-a'))!.plexId, 1);
      expect((await store.load('uuid-b'))!.plexId, 2);
    });

    test('returns null for a profile with no stored session', () async {
      await store.save('uuid-a', _session());
      expect(await store.load('uuid-b'), isNull);
    });

    test('clear removes only the addressed profile', () async {
      await store.save('uuid-a', _session());
      await store.save('uuid-b', _session());

      await store.clear('uuid-a');

      expect(await store.load('uuid-a'), isNull);
      expect(await store.load('uuid-b'), isNotNull);
    });

    test('never persists a Plex token', () async {
      await store.save('uuid-a', _session());
      final json = (await store.load('uuid-a'))!.toJson();

      expect(json.values.whereType<String>(), isNot(contains('plex-token')));
      expect(json.keys, isNot(contains('token')));
    });
  });
}
