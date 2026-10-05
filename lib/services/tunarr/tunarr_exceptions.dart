import 'tunarr_constants.dart';

/// Shared surface of every Tunarr service failure, so a single catch arm in
/// the UI can render any of them.
///
/// [message] is English for stable logs and Sentry grouping. [display] is the
/// user-facing text when the failure is rendered in the UI; it is null when no
/// localized string was attached.
abstract interface class TunarrFailure implements Exception {
  String get message;
  String? get display;
  int? get statusCode;
}

/// The URL doesn't point at a reachable, answering Tunarr gate.
///
/// [statusCode] is the response that disqualified the URL, when one arrived at
/// all. Null means nothing answered (DNS, refused, TLS, timeout).
class TunarrUrlException implements TunarrFailure {
  @override
  final String message;
  @override
  final String? display;
  @override
  final int? statusCode;
  const TunarrUrlException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'TunarrUrlException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// Sign-in or token failure: the gate refused the Plex token, no token was
/// sent, or the account has no library shared with the server.
///
/// These share one type because the gate answers them all with 401 and the
/// caller's next step is the same — reconnect — but they carry distinct
/// [display] text so the UI can explain *why* (a rejected token reads
/// differently from an account with no shared library).
class TunarrAuthException implements TunarrFailure {
  @override
  final String message;
  @override
  final String? display;
  @override
  final int? statusCode;
  const TunarrAuthException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'TunarrAuthException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// Non-auth API failure with a server-provided message, or a 4xx/5xx the gate
/// answered without a recognized error code.
class TunarrApiException implements TunarrFailure {
  @override
  final String message;
  @override
  final String? display;
  @override
  final int? statusCode;
  const TunarrApiException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'TunarrApiException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// The gate's proxy layer failed instead of answering: `tunarr-unreachable`
/// (the gate cannot reach Tunarr), a bare 502, or a non-JSON 401/403 from an
/// SSO/auth proxy standing in front of the gate.
class TunarrProxyException implements TunarrFailure {
  @override
  final String message;
  @override
  final String? display;
  @override
  final int? statusCode;
  const TunarrProxyException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'TunarrProxyException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// The gate's `error` code carried in the JSON body of a rejection, if any.
String? tunarrErrorCode(Object? data) =>
    data is Map<String, dynamic> && data['error'] is String ? data['error'] as String : null;

/// Maps a non-2xx gate response to its typed failure.
///
/// The gate answers sign-in with `401 {"error": …}` where the code is the
/// whole diagnosis, and non-proxy failures with a bare status. An unrecognized
/// code or a bodyless 4xx/5xx becomes [TunarrApiException]; a 502 or
/// `tunarr-unreachable` is the proxy layer failing to reach Tunarr, so it
/// becomes [TunarrProxyException].
Exception tunarrExceptionForStatus(int statusCode, Object? data) {
  final code = tunarrErrorCode(data);
  switch (code) {
    case TunarrConstants.errorPlex401:
      return TunarrAuthException(
        'Plex rejected the token',
        display: 'Plex rejected the sign-in token. Sign in again with a valid Plex account.',
        statusCode: statusCode,
      );
    case TunarrConstants.errorMissingPlexToken:
      return TunarrAuthException(
        'The request carried no Plex token',
        display: 'No Plex token was sent. Sign in with a Plex account to continue.',
        statusCode: statusCode,
      );
    case TunarrConstants.errorNoLibraries:
      return TunarrAuthException(
        'No libraries are shared with this account',
        display: 'No library is shared with this account on the server.',
        statusCode: statusCode,
      );
    case TunarrConstants.errorTunarrUnreachable:
      return TunarrProxyException(
        'Tunarr is unreachable behind the gate',
        display: 'Tunarr is not responding right now. Try again in a moment.',
        statusCode: statusCode,
      );
    case TunarrConstants.errorPlex503:
    case TunarrConstants.errorPlexUnreachable:
      return TunarrApiException(
        'Plex is unavailable',
        display: 'Plex is currently unavailable. Try again in a moment.',
        statusCode: statusCode,
      );
  }
  if (statusCode == 502) {
    return TunarrProxyException(
      'Bad gateway from the Tunarr gate',
      display: 'The Tunarr server is not responding right now. Try again in a moment.',
      statusCode: statusCode,
    );
  }
  return TunarrApiException(
    'HTTP $statusCode${code == null ? '' : ': $code'}',
    statusCode: statusCode,
  );
}
