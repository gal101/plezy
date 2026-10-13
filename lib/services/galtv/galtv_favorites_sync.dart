import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../settings_service.dart';
import '../tunarr/tunarr_client.dart';
import 'galtv_favorites.dart';

/// Keeps one Plex account's favourite GalTV channels in step with the gate.
///
/// [SettingsService.galtvFavoriteChannelIds] is device-local, so a channel starred
/// on the TV was not starred on the laptop. The gate is the one component that
/// already knows **which Plex user is asking** (it validates every request's
/// `X-Plex-Token` against Plex and reads the identity from plex.tv), so it holds
/// the real list: `GET`/`PUT /galtv/favorites`, keyed by the Plex user id, one JSON
/// file per user (see `auth-gate/favorites.mjs`).
///
/// The rules this class enforces, in the owner's words (*"make favourites
/// persistent for each Plex user"*, 2026-10-10):
/// - **the server is the source of truth** — a pull adopts it;
/// - **the local pref is the cache and the offline answer** — the star is instant
///   and the picker still works with the gate down;
/// - **a first sync pushes rather than wipes** — a device that holds a list built
///   by this Plex user, while the server has none for them, pushes it up instead
///   of adopting the empty answer (otherwise the list made on the TV would be
///   erased by the first laptop that signs in);
/// - **a user's list is only ever theirs** — the cache records which Plex user it
///   belongs to ([SettingsService.galtvFavoritesCacheOwner]), because one device
///   shares one pref across profiles that can map to different Plex users; a cache
///   belonging to somebody else is adopted *from* the server, never pushed to it;
/// - **a failed write is remembered** — the next pull pushes it again instead of
///   adopting a server list that is stale by exactly that edit;
/// - **a gate without the routes means local-only**, which is the behaviour before
///   this feature existed. Nothing here throws: a sync failure is a debug-log line,
///   never a dialog over somebody's TV.
class GalTvFavoritesSync {
  GalTvFavoritesSync({
    required this.client,
    required this.plexId,
    SettingsService? settings,
    this.retryDelays = const [Duration(milliseconds: 400), Duration(milliseconds: 1200)],
  }) : _settings = settings ?? SettingsService.instance;

  /// The connected gate client — the same one the channel list and the guide use.
  final TunarrClient client;

  /// The Plex **user** the session signed in as (`TunarrSession.plexId`), which is
  /// the key the gate stores under. `0` when plex.tv could not be read at sign-in;
  /// the gate still knows the real user, so only the local ownership guard is lost.
  final int plexId;

  /// Backoff between write attempts. Injectable so a test does not sleep.
  final List<Duration> retryDelays;

  final SettingsService _settings;

  /// The in-flight pull, so a screen that reloads twice in a frame spends one read.
  Future<List<String>?>? _pulling;

  /// A list this device changed but the gate has not confirmed. Deliberately
  /// in-memory: it only has to survive until the next pull, and a restart re-reads
  /// the server, which is the whole design.
  List<String>? _unsynced;

  String get _ownerKey => '$plexId';

  /// Reconcile once. Returns the list that now stands, or null when the gate had
  /// nothing to say and the device-local list is the answer.
  Future<List<String>?> pull() async {
    final inFlight = _pulling;
    if (inFlight != null) return inFlight;
    final started = _pull();
    _pulling = started;
    try {
      return await started;
    } finally {
      if (identical(_pulling, started)) _pulling = null;
    }
  }

  /// The network half of a star toggle: the caller has already written the cache,
  /// so this only has to tell the gate. `true` when the gate stored the list.
  Future<bool> push(List<String> channels) => _put(channels);

  Future<List<String>?> _pull() async {
    try {
      return await _reconcile();
    } catch (error, stackTrace) {
      // The cache write itself can fail (a locked or unwritable pref store), and
      // this runs un-awaited from screens: nothing may escape it.
      appLogger.w('GalTV: favourites could not be synced', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// One reconciliation: adopt the account's list, or push the local one up.
  Future<List<String>?> _reconcile() async {
    List<String>? remote;
    try {
      remote = await client.fetchFavorites();
    } catch (error) {
      appLogger.w('GalTV: favourites could not be read', error: error);
      return null;
    }
    // No server list to adopt: an older gate, a refused token or no network. The
    // device-local list stands, exactly as it did before this feature.
    if (remote == null) return null;

    final pending = _unsynced;
    if (pending != null) {
      // The last write never landed, so the server is stale by exactly this edit:
      // pushing is the only answer that cannot lose it.
      await _put(pending);
      return pending;
    }

    final cached = GalTvFavorites.read(_settings);
    final owner = _settings.read(SettingsService.galtvFavoritesCacheOwner);
    final belongsToThisUser = cached.isNotEmpty && (owner.isEmpty || owner == _ownerKey);
    if (remote.isEmpty && belongsToThisUser) {
      await _put(cached);
      // Pushed or not, this device's list is now *this user's* list: claiming it
      // is what stops a profile switch from pushing it at somebody else later.
      await _claimOwner();
      return cached;
    }

    await _adopt(remote);
    return remote;
  }

  /// Store the gate's list as this device's cache, and claim it for this user.
  Future<void> _adopt(List<String> channels) async {
    // Guarded by value, not by hope: the favourites listenable is a
    // `ValueNotifier<List<String>>`, whose equality is identity, so writing an
    // equal-but-new list would notify every listener — and the listeners are what
    // asked for this pull (Home reloads its shelves on a favourites change).
    if (!listEquals(GalTvFavorites.read(_settings), channels)) {
      await _settings.write(SettingsService.galtvFavoriteChannelIds, channels);
    }
    await _claimOwner();
  }

  /// Record which Plex user the cached list belongs to.
  Future<void> _claimOwner() async {
    if (_settings.read(SettingsService.galtvFavoritesCacheOwner) != _ownerKey) {
      await _settings.write(SettingsService.galtvFavoritesCacheOwner, _ownerKey);
    }
  }

  /// Replace the gate's list, retrying a transient failure. Never throws.
  Future<bool> _put(List<String> channels) async {
    _unsynced = channels;
    var attempt = 0;
    while (true) {
      TunarrFavoritesWrite result;
      try {
        result = await client.replaceFavorites(channels);
      } catch (error) {
        appLogger.w('GalTV: favourites could not be written', error: error);
        result = TunarrFavoritesWrite.failed;
      }

      if (result == TunarrFavoritesWrite.stored) {
        if (identical(_unsynced, channels)) _unsynced = null;
        return true;
      }
      if (result == TunarrFavoritesWrite.unsupported) {
        // This gate has no such route; there is nothing to keep retrying against,
        // and every read from it will keep answering "no server list".
        if (identical(_unsynced, channels)) _unsynced = null;
        appLogger.d('GalTV: this gate has no favourites routes; staying device-local');
        return false;
      }

      if (attempt >= retryDelays.length) {
        // Still remembered in [_unsynced], so the next pull pushes it again.
        appLogger.w('GalTV: favourites write failed after ${attempt + 1} attempts');
        return false;
      }
      await Future<void>.delayed(retryDelays[attempt]);
      attempt += 1;
    }
  }
}
