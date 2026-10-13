import '../../models/tunarr/tunarr_channel.dart';
import '../../models/tunarr/tunarr_lineup.dart';
import '../../models/tunarr/tunarr_now_playing.dart';
import '../../utils/app_logger.dart';
import 'tunarr_constants.dart';
import 'tunarr_exceptions.dart';
import 'tunarr_http_client.dart';

/// The GalTV resolve step's view of one `GET /api/programs/{id}` answer.
///
/// [type] is the Plex library type Tunarr recorded for the program. Tunarr's
/// `native-playback` response reports an ad and a film identically
/// (`{type: 'content', programId, title, …}` — there is no `commercial` branch),
/// so the program behind the item is where "is this an ad?" has to be answered.
///
/// Verified live 2026-10-09 on this deployment:
/// - a Movies slot → `type: "movie"`;
/// - a `Test Ads` filler → `type: "other_video"`, from the Fillers library;
/// - a clip the channel schedules as **its own content** on `TEST FILLERS` →
///   `type: "other_video"` too, from the Test library.
///
/// So the library type is necessary but **not sufficient** — see
/// [galTvProgramIsFiller] for the rule, which also asks whether the channel
/// schedules the item itself.
class TunarrProgramRef {
  const TunarrProgramRef({required this.ratingKey, this.type});

  final String ratingKey;

  /// Plex library type as Tunarr stored it: `movie`, `episode`, `other_video`, …
  final String? type;

  /// Drawn from an `Other Videos` library — a filler *candidate*, not yet an ad.
  bool get isOtherVideo => type == 'other_video';

  @override
  String toString() => 'TunarrProgramRef($ratingKey, type: $type)';
}

/// What a `PUT /galtv/favorites` did.
enum TunarrFavoritesWrite {
  /// The gate stored the list.
  stored,

  /// This gate has no favourites routes — a deploy that predates them (404, 405,
  /// or the proxy's own 403 `path-not-allowed`). Retrying cannot change that.
  unsupported,

  /// Refused, or not reachable at all. Worth one retry.
  failed,
}

/// Typed wrapper over [TunarrHttpClient] for the GalTV tab.
///
/// Nearly every path here is a *proxied* Tunarr route living at the gate root
/// (`/api/…`), so [TunarrHttpClient.send] is called with `apiScoped: false` —
/// only `/api/v1/auth/*` sits under [TunarrConstants.apiPath], and these are
/// not it. The gate allow-lists all of these prefixes. The one exception is the
/// favourites pair ([fetchFavorites]/[replaceFavorites]): those are served by the
/// **gate itself** ([TunarrConstants.favoritesPath]) and never reach Tunarr.
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

  /// `GET /api/programs/{programId}` — the two facts the resolve step needs:
  /// the Plex rating key (`externalId`) and the program's Plex **library type**.
  ///
  /// Null when the program carries no `externalId` (nothing to launch).
  Future<TunarrProgramRef?> fetchProgramRef(String programId) async {
    final res = await http.send('GET', '/api/programs/$programId', apiScoped: false);
    TunarrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is! Map) return null;
    final externalId = data['externalId'];
    if (externalId == null) return null;
    final value = externalId.toString();
    if (value.isEmpty) return null;
    return TunarrProgramRef(ratingKey: value, type: data['type']?.toString());
  }

  /// `GET /api/channels/{id}/programs?type=other_video` — the program ids this
  /// channel schedules as **its own** content from an `Other Videos` library.
  ///
  /// The set exists because the library type alone cannot answer "is this an ad?"
  /// (see [galTvProgramIsFiller]): a channel may schedule clips from such a
  /// library as programming, and every one of them would otherwise be painted with
  /// ad chrome. An `other_video` item *outside* this set is one Tunarr drew to
  /// fill a `flex` — an ad.
  ///
  /// Verified live 2026-10-09: `TEST FILLERS` answers its three scheduled clips
  /// here (~3 KB) and every other channel answers an empty page (32 bytes), so the
  /// call is cheap enough to make per item and always fresh — **no cache**: a
  /// channel edited while the app runs is classified correctly on the next item.
  ///
  /// **Degrades to an empty set**, never throws: this is a refinement of the
  /// coarse rule, and a probe must not fail — or a channel's own clips be
  /// re-labelled as ads — because a side lookup had a bad minute. Paged, because
  /// a channel with a large `Other Videos` library is exactly the channel that
  /// needs the whole set.
  Future<Set<String>> fetchChannelOwnOtherVideoProgramIds(String channelId) async {
    const pageSize = 250;
    final ids = <String>{};
    var offset = 0;
    try {
      while (true) {
        final res = await http.send(
          'GET',
          '/api/channels/$channelId/programs',
          query: <String, Object?>{
            'type': 'other_video',
            'limit': '$pageSize',
            'offset': '$offset',
          },
          apiScoped: false,
        );
        TunarrHttpClient.throwForStatus(res);
        final data = res.data;
        if (data is! Map) break;
        final page = data['result'];
        if (page is! List) break;
        ids.addAll(
          page.whereType<Map>().map((e) => e['uuid']?.toString() ?? '').where((e) => e.isNotEmpty),
        );
        offset += page.length;
        final total = (data['total'] as num?)?.toInt() ?? ids.length;
        if (page.isEmpty || offset >= total) break;
      }
    } catch (error, stackTrace) {
      appLogger.w(
        'GalTV channel content lookup failed for $channelId',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return ids;
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

  /// `GET /galtv/favorites` — the starred channels the **gate** holds for the
  /// Plex account behind this request's token.
  ///
  /// Gate-native, not proxied ([TunarrConstants.favoritesPath]), so no Tunarr
  /// path gains write access and none of the request goes near Tunarr.
  ///
  /// `null` means "no usable server list" — an older gate without the routes, a
  /// refused token, or an unreachable gate — and the caller then keeps the
  /// device-local cache, which is exactly the behaviour before this feature. An
  /// **empty list is not null**: it is the gate saying this user has starred
  /// nothing, and it is adopted.
  ///
  /// Never throws: a background sync must not surface as a failure anywhere, so
  /// every unusable answer is a logged `null`.
  Future<List<String>?> fetchFavorites() async {
    final res = await http.send('GET', TunarrConstants.favoritesPath, apiScoped: false);
    if (res.statusCode == 200) {
      final data = res.data;
      final channels = data is Map ? data['channels'] : null;
      if (channels is List) {
        return [for (final id in channels) if (id is String) id];
      }
      appLogger.w('Tunarr: unreadable favourites body');
      return null;
    }
    if (!_favoritesRouteAbsent(res)) {
      appLogger.w('Tunarr: favourites read answered ${res.statusCode}');
    }
    return null;
  }

  /// `PUT /galtv/favorites` with `{"channels": [...]}` — replace the stored list.
  ///
  /// Whole-list replacement is deliberate: the list is one value per Plex user,
  /// so last write wins and there is no per-entry merge to get wrong.
  Future<TunarrFavoritesWrite> replaceFavorites(List<String> channelIds) async {
    final res = await http.send(
      'PUT',
      TunarrConstants.favoritesPath,
      body: <String, Object?>{'channels': channelIds},
      apiScoped: false,
    );
    if (res.statusCode >= 200 && res.statusCode < 300) return TunarrFavoritesWrite.stored;
    if (_favoritesRouteAbsent(res)) return TunarrFavoritesWrite.unsupported;
    appLogger.w('Tunarr: favourites write answered ${res.statusCode}');
    return TunarrFavoritesWrite.failed;
  }

  /// Whether an answer means "this gate has no such route" rather than a failure.
  ///
  /// A gate older than the favourites feature answers the *proxy*: 403
  /// `path-not-allowed` (the path is outside its `ALLOWED_PATHS`) for a `GET`, and
  /// 405 `method-not-allowed` for a `PUT` (its allow-list is `GET`/`HEAD`). 404 is
  /// the same story from anything else in front.
  static bool _favoritesRouteAbsent(TunarrResponse res) =>
      res.statusCode == 404 ||
      res.statusCode == 405 ||
      tunarrErrorCode(res.data) == TunarrConstants.errorPathNotAllowed;
}
