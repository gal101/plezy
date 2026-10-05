import 'package:http/http.dart' as http;

import '../../models/tunarr/tunarr_session.dart';
import '../../utils/url_utils.dart';
import 'tunarr_constants.dart';
import 'tunarr_exceptions.dart';
import 'tunarr_http_client.dart';

/// Sign-in against the Tunarr gate.
///
/// Unlike Seerr, the gate issues no session cookie and its sign-in answer *is*
/// the account data: `POST {base}/api/v1/auth/plex` with
/// `{"authToken": …}` returns `{granted, username, email, plexId, sections}`.
/// The Plex token itself is never persisted in the session.
class TunarrAuthService {
  final http.Client Function()? httpClientFactory;

  TunarrAuthService({this.httpClientFactory});

  TunarrHttpClient _client(String baseUrl, {String? plexToken}) =>
      TunarrHttpClient(baseUrl: baseUrl, plexToken: plexToken, httpClient: httpClientFactory?.call());

  /// Schemeless-input guesses, TLS first — mirroring Seerr's discovery. No
  /// default install port is guessed: a self-hosted gate can sit on any port,
  /// and a wrong default would only add noise to the race.
  static const List<BaseUrlGuess> _schemelessGuesses = [
    (scheme: 'https', port: null),
    (scheme: 'http', port: null),
  ];

  /// Expands a user-typed gate address into probe candidates. An explicit
  /// scheme is authoritative; otherwise TLS and plain HTTP are both tried.
  static List<String> expandUrlCandidates(String input) => expandBaseUrlCandidates(input, guesses: _schemelessGuesses);

  /// Cheap reachability check against the allow-listed health endpoint.
  ///
  /// Throws [TunarrUrlException] when nothing answers or the answer isn't a
  /// live gate. Unauthenticated on purpose: it only proves a server is there.
  Future<void> probe(String baseUrl) async {
    final client = _client(baseUrl);
    try {
      final TunarrResponse res;
      try {
        res = await client.send(
          'GET',
          TunarrConstants.healthPath,
          timeout: TunarrConstants.probeTimeout,
          authenticated: false,
          apiScoped: false,
        );
      } catch (e) {
        throw TunarrUrlException('Could not reach $baseUrl: $e', display: 'Could not reach the Tunarr server.');
      }
      if (res.statusCode >= 400) {
        throw TunarrUrlException(
          'No Tunarr gate at $baseUrl (HTTP ${res.statusCode})',
          display: 'No Tunarr server answered at this address.',
          statusCode: res.statusCode,
        );
      }
    } finally {
      client.dispose();
    }
  }

  /// Exchanges [plexToken] for a gate session.
  ///
  /// Parses the JSON body directly — there is no cookie to capture and no
  /// follow-up `/auth/me`. A non-200 is mapped to its typed failure; a 401
  /// carrying `no-libraries` is still a [TunarrAuthException] but with text
  /// that says the account is not shared on the server.
  Future<TunarrSession> signIn({required String baseUrl, required String plexToken}) async {
    if (plexToken.trim().isEmpty) {
      throw const TunarrAuthException(
        'No Plex token to sign in with',
        display: 'Sign in with a Plex account to continue.',
      );
    }
    final client = _client(baseUrl, plexToken: plexToken);
    try {
      final TunarrResponse res;
      try {
        res = await client.send(
          'POST',
          TunarrConstants.signInPath,
          body: {'authToken': plexToken},
          timeout: TunarrConstants.authTimeout,
          // The token rides in the body; the header is for later requests.
          authenticated: false,
        );
      } catch (e) {
        throw TunarrUrlException('Could not reach $baseUrl: $e', display: 'Could not reach the Tunarr server.');
      }
      if (res.statusCode != 200) {
        // A 401/403 without the gate's shape is an intermediary, not the gate.
        TunarrHttpClient.throwIfIntermediary(res);
        throw tunarrExceptionForStatus(res.statusCode, res.data);
      }
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw const TunarrApiException(
          'Sign-in returned no JSON body',
          display: 'The Tunarr server returned an unexpected response.',
        );
      }
      final session = TunarrSession.fromSignIn(
        baseUrl: client.baseUrl,
        json: data,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      if (!session.granted) {
        throw const TunarrAuthException(
          'Sign-in was not granted',
          display: 'The Tunarr server did not grant access.',
        );
      }
      return session;
    } finally {
      client.dispose();
    }
  }
}
