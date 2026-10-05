/// Constants for the Tunarr auth/proxy gate in front of a Tunarr instance.
///
/// Unlike Seerr, this gate is stateless: it issues no cookie and authenticates
/// every request from the caller-supplied Plex token. The one exception is the
/// sign-in call, which exchanges a Plex token for the account/identity data in
/// [TunarrSession].
abstract final class TunarrConstants {
  /// Prefix of the auth endpoint (`POST /api/v1/auth/plex`). Note that the
  /// *proxied* Tunarr paths below sit at the root (`/api/...`), not under this
  /// prefix — only auth lives under `/api/v1`.
  static const String apiPath = '/api/v1';

  /// Sign-in path, joined under [apiPath].
  static const String signInPath = '/auth/plex';

  /// Allow-listed health endpoint, used as the cheap reachability probe.
  static const String healthPath = '/api/system/health';

  /// Header every authenticated request carries, mirroring Plex's own token
  /// header. The gate never accepts a `Cookie`.
  static const String plexTokenHeader = 'X-Plex-Token';

  static const Duration probeTimeout = Duration(seconds: 8);
  static const Duration authTimeout = Duration(seconds: 20);
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Path prefixes the gate proxies. Any path outside these is rejected with
  /// 403 before Tunarr is consulted.
  static const List<String> gatewayPathPrefixes = <String>[
    '/api/channels',
    '/api/guide',
    '/api/programs',
    '/api/programming',
    '/api/system/health',
    '/api/xmltv.xml',
  ];

  /// Whether [path] (as sent on the wire, including any `/api` prefix) is one
  /// the gate allows through.
  static bool isGatewayPathAllowed(String path) => gatewayPathPrefixes.any(path.startsWith);

  /// Gate `error` codes carried in the JSON body of a rejection.
  static const String errorMissingPlexToken = 'missing-plex-token';
  static const String errorPlex401 = 'plex-401';
  static const String errorNoLibraries = 'no-libraries';
  static const String errorPlex503 = 'plex-503';
  static const String errorPlexUnreachable = 'plex-unreachable';
  static const String errorTunarrUnreachable = 'tunarr-unreachable';
}
