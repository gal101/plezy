import 'package:flutter/foundation.dart';

import '../connection/connection_registry.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../models/tunarr/tunarr_session.dart';
import '../profiles/active_plex_token.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile_connection_registry.dart';
import '../services/tunarr/tunarr_auth_service.dart';
import '../services/tunarr/tunarr_client.dart';
import '../services/tunarr/tunarr_http_client.dart';
import '../services/tunarr/tunarr_session_store.dart';
import '../utils/app_logger.dart';

/// Resolve the active profile's Plex token for Tunarr sign-in: the profile's
/// per-user token when a bind exists (a Home user's Tunarr account maps to
/// their own plex.tv user), else the account token.
typedef TunarrPlexTokenSupplier = Future<String?> Function();

/// Builds the [TunarrPlexTokenSupplier] wired from the provider tree, where
/// the registries live above the profile session subtree.
TunarrPlexTokenSupplier buildTunarrPlexTokenSupplier({
  required ActiveProfileProvider activeProfile,
  required ConnectionRegistry connections,
  required ProfileConnectionRegistry profileConnections,
}) {
  return () async {
    final resolved = await resolveActivePlexToken(
      activeProfile: activeProfile,
      connections: connections,
      profileConnections: profileConnections,
      allowAccountTokenForHomeUser: true,
    );
    return resolved?.token;
  };
}

/// Owns the active Tunarr session for the currently-selected profile,
/// mirroring [SeerrAccountProvider]'s rebind shape: `onActiveProfileChanged`
/// loads the profile's stored session.
///
/// Unlike the OAuth trackers there is no in-provider connect flow — the
/// connect screen calls [signIn] and hands the finished session to
/// [adoptSession].
class TunarrAccountProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  TunarrAccountProvider({TunarrSessionStore? store, TunarrAuthService? authService})
    : _store = store ?? const TunarrSessionStore(),
      authService = authService ?? TunarrAuthService();

  final TunarrSessionStore _store;
  final TunarrAuthService authService;
  TunarrPlexTokenSupplier? _plexTokenSupplier;

  TunarrSession? _session;
  String _activeUserUuid = '';
  int _bindingGeneration = 0;
  TunarrClient? _client;

  TunarrSession? get session => _session;
  bool get isConnected => _session != null;

  /// The read-only Tunarr gateway client, or null while disconnected.
  ///
  /// Rebuilt whenever the session changes and given the *supplier* rather than a
  /// captured token, so every request resolves the active profile's live Plex
  /// token — a token captured once would go stale across a profile switch.
  TunarrClient? get client => _client;

  /// Label for the connected account: the signed-in Plex username when
  /// known, else the account email, else the instance label. Empty when
  /// disconnected, so `context.select` consumers can treat it as a scalar.
  String get displayName {
    final session = _session;
    if (session == null) return '';
    if (session.username.isNotEmpty) return session.username;
    if (session.email.isNotEmpty) return session.email;
    return session.instanceLabel;
  }

  /// Wired once from the provider tree (the registries live above the
  /// profile session subtree).
  void bindPlexTokenSupplier(TunarrPlexTokenSupplier supplier) => _plexTokenSupplier = supplier;

  /// The connect screen's "Sign in with Plex" needs the same token the
  /// silent re-auth path would use. Null on Jellyfin-only setups.
  Future<String?> resolvePlexToken() async {
    try {
      return await _plexTokenSupplier?.call();
    } catch (e) {
      appLogger.w('Tunarr: Plex token resolution failed', error: e);
      return null;
    }
  }

  /// Called whenever the active profile changes (or on initial load).
  Future<void> onActiveProfileChanged(String? newUserUuid) async {
    if (isDisposed) return;
    final userUuid = newUserUuid ?? '';
    final generation = ++_bindingGeneration;
    _activeUserUuid = userUuid;
    _setSession(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    final loaded = await _store.load(userUuid);
    _setSession(userUuid, generation, loaded);
  }

  /// Persist and bind a session the connect screen established.
  ///
  /// [signIn] deliberately does not adopt: the screen calls this once it has
  /// the finished session, so the provider never binds a session the screen
  /// is still validating.
  Future<void> adoptSession(TunarrSession session) async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    await _store.save(userUuid, session);
    _setSession(userUuid, generation, session);
  }

  /// Clear local state so the UI shows "not connected" and the user can
  /// re-link.
  Future<void> disconnect() async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    _setSession(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.clear(userUuid);
  }

  /// Sign in against [baseUrl] with the active profile's live Plex token.
  ///
  /// The token is read from the profile (never stored in the session).
  /// Throws a [StateError] when no token is available — e.g. a Jellyfin-only
  /// setup. Does not adopt the returned session; the screen calls
  /// [adoptSession] afterwards.
  Future<TunarrSession> signIn({required String baseUrl}) async {
    final plexToken = await resolvePlexToken();
    if (plexToken == null || plexToken.isEmpty) {
      throw StateError('Tunarr: no Plex token available for sign-in');
    }
    return authService.signIn(baseUrl: baseUrl, plexToken: plexToken);
  }

  void _setSession(String userUuid, int generation, TunarrSession? session) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    _session = session;
    _rebuildClient();
    safeNotifyListeners();
  }

  void _rebuildClient() {
    _client?.dispose();
    final session = _session;
    _client = session == null
        ? null
        : TunarrClient(
            http: TunarrHttpClient(baseUrl: session.baseUrl, plexTokenSupplier: resolvePlexToken),
          );
  }

  @override
  void dispose() {
    _client?.dispose();
    _client = null;
    super.dispose();
  }

  bool _isCurrentBinding(String userUuid, int generation) {
    return !isDisposed && userUuid == _activeUserUuid && generation == _bindingGeneration;
  }
}
