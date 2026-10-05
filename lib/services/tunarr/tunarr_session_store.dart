import '../../models/tunarr/tunarr_session.dart';
import '../../profiles/profile.dart';
import '../../utils/serial_future_queue.dart';
import '../base_shared_preferences_service.dart';

/// Per-Plex-profile persistence for the Tunarr session, mirroring
/// `SeerrSessionStore`'s `user_{uuid}_{baseKey}` scoping.
///
/// Unlike `SeerrSessionStore` this store does **not** route anything through
/// `CredentialVault`: a [TunarrSession] deliberately holds no Plex token and
/// no password (see the model's class note), so there is no secret to protect.
/// The persisted payload is just the gate URL, the account identity and the
/// visible library list.
class TunarrSessionStore {
  static const String _baseKey = 'tunarr_session';

  // Shared across profile-keyed provider/store lifetimes. Enqueue the entire
  // operation before any preferences await so a new load or clear cannot
  // overtake an old provider's still-running save.
  static final SerialFutureQueue _persistence = SerialFutureQueue();

  const TunarrSessionStore();

  String _scopedKey(String userUuid) => profileScopedPrefsKey(userUuid, _baseKey);

  Future<TunarrSession?> load(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    // Outside the try below on purpose: an unreadable slot must reach the
    // repair prompt, not be swallowed as 'no session'.
    final raw = readTolerantString(prefs, _scopedKey(userUuid));
    if (raw == null) return null;
    try {
      return TunarrSession.decode(raw);
    } catch (_) {
      return null;
    }
  });

  Future<void> save(String userUuid, TunarrSession session) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_scopedKey(userUuid), session.encode());
  });

  Future<void> clear(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_scopedKey(userUuid));
  });
}
