import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/abortable_http_request.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../utils/platform_http_client_io.dart'
    as platform;
import '../../utils/url_utils.dart';
import '../trackers/tracker_http_client.dart';
import 'tunarr_constants.dart';
import 'tunarr_exceptions.dart';

/// HTTP response paired with its decoded JSON body. `data` is null for
/// no-content responses and non-JSON bodies.
class TunarrResponse {
  final http.Response response;
  final dynamic data;
  const TunarrResponse(this.response, this.data);

  int get statusCode => response.statusCode;
}

/// What a 401/403 answer under the gate means.
enum TunarrRejection {
  /// Success or an ordinary API failure, without authentication evidence.
  none,

  /// The gate answered with its own JSON `{error}` body on a 401/403: a
  /// rejected Plex token, or a path outside the proxy allow-list.
  gate,

  /// A 401/403 without the gate's shape — an SSO redirect, HTTP Basic
  /// challenge, or API gateway. Never a reason to distrust a stored session.
  intermediary,
}

/// Supplies the profile's current Plex account token at request time, so a
/// client can outlive a token/profile change without capturing a stale copy.
/// Mirrors `SeerrPlexTokenSupplier`.
typedef TunarrPlexTokenSupplier = Future<String?> Function();

/// Thin wrapper around `package:http` for the Tunarr gate.
///
/// Two properties distinguish it from [SeerrHttpClient]:
///   1. No cookies, ever. The gate is stateless and authenticates every
///      request from the caller's Plex token, replayed as
///      [TunarrConstants.plexTokenHeader].
///   2. Auth lives under `/api/v1`, but the proxied Tunarr routes sit at the
///      root; [send] takes `apiScoped: false` for the latter.
class TunarrHttpClient {
  final String baseUrl;
  final String? plexToken;

  /// Consulted per request when [plexToken] is null, so a long-lived client
  /// picks up a rotated or newly-resolved token without being rebuilt.
  final TunarrPlexTokenSupplier? plexTokenSupplier;
  final http.Client _http;

  TunarrHttpClient({
    required String baseUrl,
    String? plexToken,
    this.plexTokenSupplier,
    http.Client? httpClient,
  }) : baseUrl = normalizeBaseUrl(baseUrl),
       plexToken = (plexToken?.isNotEmpty ?? false) ? plexToken : null,
       _http = httpClient ?? platform.createPlatformClient();

  void dispose() => _http.close();

  /// Send [method] to [path], returning the decoded JSON body. No status
  /// throws here: callers run [classify]/[throwForStatus] over the answer so a
  /// token rejection can feed the reconnect path.
  ///
  /// [apiScoped] prefixes [TunarrConstants.apiPath]; pass false for the
  /// allow-listed Tunarr routes that live at the root.
  Future<TunarrResponse> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    Duration timeout = TunarrConstants.requestTimeout,
    bool authenticated = true,
    bool apiScoped = true,
  }) async {
    if (!const {'GET', 'POST', 'PUT', 'DELETE'}.contains(method)) {
      throw ArgumentError('Unsupported HTTP method: $method');
    }
    final uri = _uri(path, query, apiScoped: apiScoped);
    final token = authenticated ? await _resolveToken() : null;
    // Never a Cookie: the gate does not accept one.
    final headers = <String, String>{
      'Accept': 'application/json',
      TunarrConstants.plexTokenHeader: ?token,
      if (body != null) 'Content-Type': 'application/json',
    };
    final sw = Stopwatch()..start();
    // Abortable so a timeout releases transport resources. Redirects are not
    // followed: the gate never issues one, so a 3xx is an auth proxy in front
    // of it and following it would hide that behind an HTML 200.
    final response = await sendAbortableHttpRequest(
      _http,
      method,
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
      timeout: timeout,
      operation: 'Tunarr $method $path',
      followRedirects: false,
    );
    appLogger.d('Tunarr $method $path -> ${response.statusCode} (${sw.elapsedMilliseconds}ms)');
    return TunarrResponse(response, TrackerHttpClient.decodeJson(response.body));
  }

  /// The explicit [plexToken] wins; otherwise the live [plexTokenSupplier] is
  /// asked once for this request. A blank/absent answer omits the header.
  Future<String?> _resolveToken() async {
    if (plexToken != null) return plexToken;
    final supplied = await plexTokenSupplier?.call();
    return (supplied?.isNotEmpty ?? false) ? supplied : null;
  }

  Uri _uri(String path, Map<String, Object?>? query, {required bool apiScoped}) {
    final prefix = apiScoped ? TunarrConstants.apiPath : '';
    final base = Uri.parse('$baseUrl$prefix$path');
    final encoded = encodeQueryParameters(query);
    return encoded.isEmpty ? base : base.replace(query: encoded);
  }

  /// Whether a 3xx/401/403 came from the gate itself (its JSON `{error}`
  /// shape) or from something standing in front of it.
  static TunarrRejection classify(TunarrResponse res) {
    final code = res.statusCode;
    if (code != 401 && code != 403) return TunarrRejection.none;
    return tunarrErrorCode(res.data) != null ? TunarrRejection.gate : TunarrRejection.intermediary;
  }

  /// Throw [TunarrProxyException] when [classify] says an intermediary
  /// answered; no-op otherwise.
  static void throwIfIntermediary(TunarrResponse res) {
    if (classify(res) != TunarrRejection.intermediary) return;
    throw TunarrProxyException(
      'An auth proxy answered instead of the Tunarr gate (HTTP ${res.statusCode})',
      display: 'A sign-in service is blocking access to the Tunarr server.',
      statusCode: res.statusCode,
    );
  }

  /// Throw the mapped exception for a 3xx/4xx/5xx response; no-op on success.
  static void throwForStatus(TunarrResponse res) {
    throwIfIntermediary(res);
    final code = res.statusCode;
    if (code >= 200 && code < 300) return;
    throw tunarrExceptionForStatus(code, res.data);
  }

  /// Trim whitespace and strip trailing slashes so request URLs agree on one
  /// canonical gate URL.
  static String normalizeBaseUrl(String input) {
    var v = input.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
