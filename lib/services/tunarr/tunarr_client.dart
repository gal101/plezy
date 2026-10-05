import '../../models/tunarr/tunarr_channel.dart';
import '../../models/tunarr/tunarr_lineup.dart';
import '../../models/tunarr/tunarr_now_playing.dart';
import 'tunarr_http_client.dart';

/// Typed wrapper over [TunarrHttpClient] for the GalTV tab.
///
/// Every path here is a *proxied* Tunarr route living at the gate root
/// (`/api/…`), so [TunarrHttpClient.send] is called with `apiScoped: false` —
/// only `/api/v1/auth/*` sits under [TunarrConstants.apiPath], and these are
/// not it. The gate allow-lists all of these prefixes.
///
/// Responses are returned as parsed models; non-2xx statuses are mapped to the
/// typed [TunarrFailure]s by [TunarrHttpClient.throwForStatus], with one
/// deliberate exception: a 404 on native-playback is a channel with no
/// schedule, not an error.
class TunarrClient {
  final TunarrHttpClient http;

  TunarrClient({required this.http});

  void dispose() => http.dispose();

  /// `GET /api/channels` — every channel the gate's account can see.
  Future<List<TunarrChannel>> fetchChannels() async {
    final res = await http.send('GET', '/api/channels', apiScoped: false);
    TunarrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! List) return const <TunarrChannel>[];
    return data
        .whereType<Map>()
        .map((e) => TunarrChannel.fromJson(e.cast<String, Object?>()))
        .toList();
  }

  /// `GET /api/channels/{id}/native-playback`.
  ///
  /// Returns null when the channel has no schedule (the gate answers 404)
  /// instead of throwing; every other non-2xx still maps to its failure.
  Future<TunarrNowPlaying?> fetchNowPlaying(String channelId) async {
    final res = await http.send('GET', '/api/channels/$channelId/native-playback', apiScoped: false);
    if (res.statusCode == 404) return null;
    TunarrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! Map) return null;
    return TunarrNowPlaying.fromJson(data.cast<String, Object?>());
  }

  /// `GET /api/programs/{programId}` — resolves the program's Plex rating key
  /// (`externalId`). Null when the program carries none.
  Future<String?> fetchPlexRatingKey(String programId) async {
    final res = await http.send('GET', '/api/programs/$programId', apiScoped: false);
    TunarrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! Map) return null;
    final externalId = data['externalId'];
    if (externalId == null) return null;
    final value = externalId.toString();
    return value.isEmpty ? null : value;
  }

  /// `GET /api/channels/all/lineups` for a UTC window.
  ///
  /// `includePrograms=true` is always sent: the slot program body is nested
  /// and absent otherwise, and the resolve step needs `program.externalId`.
  Future<List<TunarrLineupChannel>> fetchLineups({
    required DateTime from,
    required DateTime to,
  }) async {
    final res = await http.send(
      'GET',
      '/api/channels/all/lineups',
      query: <String, Object?>{
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'includePrograms': 'true',
      },
      apiScoped: false,
    );
    TunarrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! List) return const <TunarrLineupChannel>[];
    return data
        .whereType<Map>()
        .map((e) => TunarrLineupChannel.fromJson(e.cast<String, Object?>()))
        .toList();
  }
}
