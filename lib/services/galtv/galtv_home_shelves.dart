import '../../media/media_backend.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_rating.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../models/tunarr/tunarr_channel.dart';
import '../../models/tunarr/tunarr_lineup.dart';
import 'galtv_favorites.dart';

/// The `MediaItem.id` prefix for a GalTV channel card on Home.
///
/// A card is not a Plex item, so its identity is synthesized; the channel id is
/// carried in the id itself because both Home hosts hand a tap back as a bare
/// [MediaItem] (`HubSection.onItemTap`, `TvBrowseRail.onActivateItem`).
const String galTvShelfItemIdPrefix = 'galtv_channel_';

/// Stable hub ids — used for the focus keys, the rail's identity and the icon.
const String galTvAllChannelsHubId = 'galtv_all_channels';
const String galTvFavoritesHubId = 'galtv_favorites';

/// The `MediaItem.id` for [channelId]'s Home card.
String galTvShelfItemId(String channelId) => '$galTvShelfItemIdPrefix$channelId';

/// The channel id behind a Home shelf card, or null when [itemId] is not one.
String? galTvShelfChannelId(String itemId) {
  if (!itemId.startsWith(galTvShelfItemIdPrefix)) return null;
  final id = itemId.substring(galTvShelfItemIdPrefix.length);
  return id.isEmpty ? null : id;
}

/// What a channel is airing at a given instant.
class GalTvAiring {
  const GalTvAiring({
    required this.title,
    required this.start,
    required this.stop,
    this.ratingKey,
    this.type,
    this.summary,
    this.year,
    this.contentRating,
  });

  final String title;

  /// Plex `ratingKey` of the airing programme, or null when the slot carries no
  /// Plex identity.
  final String? ratingKey;

  /// Plex library type as Tunarr stored it — `movie`, `episode`, `other_video`.
  /// Verified live on this deployment: the lineup's nested program body carries
  /// it. It decides which Plex image is worth asking for, see [_programmeArtPath].
  final String? type;

  /// Synopsis, year and content rating, carried for the Home preview so a
  /// synthesized card reads like a real one instead of a bare title. All three
  /// come from the lineup's nested program body — no extra fetch.
  final String? summary;
  final int? year;
  final String? contentRating;

  final DateTime start;
  final DateTime stop;
}

/// The Plex image path for an airing programme, given its library type.
///
/// A movie's backdrop (`art`, 16:9) is what a wide card wants. An **episode**
/// usually has no `art` of its own — Plex keeps the backdrop on the show — which
/// is the same trap the guide hit, and its documented answer is the episode's own
/// `thumb`, an episode still that is already 16:9. Verified against the live
/// deployment: a `TEST2` episode answers `type: "episode"` here and its `art`
/// does not resolve, so it painted the card's placeholder.
String _programmeArtPath(String ratingKey, String? type) =>
    '/library/metadata/$ratingKey/${type == 'episode' ? 'thumb' : 'art'}';

/// The card kind for an airing programme's library type.
///
/// It exists for the **preview's metadata line**: a `movie` gives
/// `Movie · <scores> · <rating> · <duration> · <year>` and an `episode` gives its
/// `S1 E8` label, exactly as any other Home card does. Anything else (a filler, a
/// gap) has no kind to borrow and stays a clip.
MediaKind _programmeKind(String? type) => switch (type) {
  'movie' => MediaKind.movie,
  'episode' => MediaKind.episode,
  _ => MediaKind.clip,
};

/// The Rotten Tomatoes entries of [ratings] — the only scores a Plex **listing**
/// carries, and therefore the only ones a Home card badges.
///
/// Plex's shelf payload maps just its critic/audience pair; the item payload a
/// detail fetch returns adds IMDb, TMDB and friends. Carrying those onto a channel
/// card made it badge scores no other shelf shows — the owner's rule, 2026-10-10:
/// *"SHOULD be only rotten tomatoes score for movies"*. `critic`/`audience` count
/// because that is how an unnamed tomato score arrives (`rating_utils` renders both
/// with the tomato badge).
List<MediaRatingSource> _tomatoRatings(Iterable<MediaRatingSource>? ratings) => [
  for (final rating in ratings ?? const <MediaRatingSource>[])
    if (rating.source.startsWith('rottenTomatoes') || rating.source == 'critic' || rating.source == 'audience')
      rating,
];

/// The Plex **wordmark** path for an airing programme, or null when the library
/// cannot have one.
///
/// A `clearLogo` is agent artwork: `Plex Movie` / `Plex TV Series` fetch it, while
/// an `Other Videos` library has no agent and therefore no logo (the same rule the
/// break slate documents for its own fallback). Asking for it costs nothing —
/// `ClearLogoImage` paints the title when the request 404s — but asking for one on
/// a filler would only ever be a miss.
String? _programmeLogoPath(String? ratingKey, String? type) {
  if (ratingKey == null) return null;
  if (type != 'movie' && type != 'episode') return null;
  return '/library/metadata/$ratingKey/clearLogo';
}

/// The slot covering [now] on [channel], or null when there is nothing playable
/// then (a `flex`/`redirect` gap, or a channel with no schedule in the window).
///
/// This is the wall-clock pick the Home shelf makes: unlike the player, a shelf
/// label carries no playback offset, so a device clock that is minutes off
/// cannot put anyone on the wrong frame the way a seek would.
GalTvAiring? galTvAiringAt(TunarrLineupChannel channel, DateTime now) {
  final nowMs = now.millisecondsSinceEpoch;
  for (final slot in channel.slots) {
    if (slot.start > nowMs || nowMs >= slot.stop) continue;
    return _airingOf(slot);
  }
  return null;
}

/// The **next programme** this channel will play — the first named, real-content
/// slot still ahead of [now].
///
/// A channel in a gap is showing nothing, and a card captioned with its own name
/// says nothing either. Looking ahead is what makes the row useful during the
/// frequent short breaks: the owner's ask, 2026-10-09 — *"if flex is playing can we
/// show the photo of the next upcoming movie/episode"*.
///
/// **Fillers are skipped**, because "the next movie/episode" is what was asked
/// for and what a viewer means: a channel that breaks for ads would otherwise
/// caption its card with the next *ad*. The discriminator is [galTvProgramIsFiller]
/// — the same rule the player runs — so [ownOtherVideoIds] (the channel's own
/// `Other Videos` content) is what keeps a channel whose programming *is* clips
/// from looking empty. A missing type is *not* a filler, so an unlabelled
/// programme is still shown.
///
/// Null when the window holds nothing but gaps and fillers — the card then falls
/// back to the channel itself.
GalTvAiring? galTvNextAiring(
  TunarrLineupChannel channel,
  DateTime now, {
  Set<String> ownOtherVideoIds = const {},
}) {
  final nowMs = now.millisecondsSinceEpoch;
  for (final slot in channel.slots) {
    if (slot.stop <= nowMs) continue;
    final airing = _airingOf(slot);
    if (airing == null) continue;
    if (galTvProgramIsFiller(
      type: slot.program?.type,
      programId: slot.id,
      channelOwnOtherVideoIds: ownOtherVideoIds,
    )) {
      continue;
    }
    return airing;
  }
  return null;
}

/// The nameable airing a slot carries, or null when it has none — a `flex`/
/// `redirect` gap, or a slot with no program body.
GalTvAiring? _airingOf(TunarrLineupSlot slot) {
  final program = slot.program;
  final title = program?.title?.trim();
  if (!slot.isPlayable || title == null || title.isEmpty) return null;
  return GalTvAiring(
    title: title,
    ratingKey: program!.externalId,
    type: program.type,
    summary: program.summary,
    year: program.year,
    contentRating: program.contentRating,
    start: DateTime.fromMillisecondsSinceEpoch(slot.start),
    stop: DateTime.fromMillisecondsSinceEpoch(slot.stop),
  );
}

/// Build the Home shelves for GalTV, in the order they are drawn: the viewer's
/// favourites first, then every channel.
///
/// Two shelves rather than one because they answer different questions — "what
/// do I watch" and "what is on" — and the all-channels row doubles as the debug
/// surface while the Tunarr instance is small. Favourites lead because that is
/// the owner's own call (2026-10-08): the row you curate is the one you want
/// first, and the debug row sits under it. The caller draws both **below**
/// Continue Watching.
///
/// The favourites shelf is built from [favoriteChannelIds] **filtered** against
/// [channels] (never pruned: `GalTvFavorites.visible` is the rule), so a channel
/// deleted in Tunarr simply stops being drawn, and a favourite that no longer
/// resolves can never put a card on the shelf that would launch nothing. When
/// nothing is left the shelf is not returned at all — an empty row is worse than
/// no row.
///
/// Pure: no prefs, no network, no widgets. The caller supplies the titles and the
/// subtitle format so this module stays free of i18n.
List<MediaHub> buildGalTvHomeShelves({
  required List<TunarrChannel> channels,
  required List<TunarrLineupChannel> lineups,
  required Set<String> favoriteChannelIds,
  required DateTime now,
  required String allChannelsTitle,
  required String favoritesTitle,
  required String Function(TunarrChannel channel) subtitleFor,

  /// The caption for a channel that is **in a gap**, whose card shows what is
  /// coming instead — the channel line plus when it starts. Falls back to
  /// [subtitleFor].
  String Function(TunarrChannel channel, DateTime startsAt)? upcomingSubtitleFor,
  String? Function(String? iconPath)? resolveLogoUrl,

  /// Each channel's own `Other Videos` content, keyed by channel id — what
  /// `GalTvTuner.ownOtherVideoIdsByChannel` returns. A channel missing from the
  /// map has none, which is the normal case.
  Map<String, Set<String>> ownOtherVideoIdsByChannel = const {},

  /// The **app's** Plex server id (`PlexClient.serverId`, a `machineIdentifier`).
  ///
  /// Every card carries it because the TV spotlight resolves its artwork client
  /// from `MediaItem.serverId`: without one, a `/library/metadata/...` path has no
  /// client to load through and the preview paints a bare gradient (verified on
  /// the TV 2026-10-10 — the two previews, normal vs channel, differed in exactly
  /// the images). It must come from the **client**, never from Tunarr: the
  /// lineup's `mediaSourceId` is Tunarr's own source UUID and resolves to no client
  /// at all (`9e74c745-…` vs Plex's `2b4de25a…`).
  String? plexServerId,

  /// The **Plex item** of each channel's airing (or next) programme, keyed by
  /// channel id — one metadata read per channel, made by the caller on a shelf
  /// load. It is what gives the preview its score row and Plex's own artwork:
  /// the lineup carries the schedule but no score at all. A channel missing from
  /// the map still gets its card, from the lineup alone.
  Map<String, MediaItem> programmeItemsByChannel = const {},
}) {
  final lineupsById = <String, TunarrLineupChannel>{for (final lineup in lineups) lineup.id: lineup};
  final channelsById = <String, TunarrChannel>{for (final channel in channels) channel.id: channel};

  final allChannels = _shelfHub(
    id: galTvAllChannelsHubId,
    title: allChannelsTitle,
    channels: channels,
    lineupsById: lineupsById,
    now: now,
    subtitleFor: subtitleFor,
    upcomingSubtitleFor: upcomingSubtitleFor,
    resolveLogoUrl: resolveLogoUrl,
    ownOtherVideoIdsByChannel: ownOtherVideoIdsByChannel,
    plexServerId: plexServerId,
    programmeItemsByChannel: programmeItemsByChannel,
  );

  final favoriteChannels = [
    for (final id in GalTvFavorites.visible(favoriteChannelIds, channelsById.keys.toSet()))
      channelsById[id]!,
  ];

  return [
    if (favoriteChannels.isNotEmpty)
      _shelfHub(
        id: galTvFavoritesHubId,
        title: favoritesTitle,
        channels: favoriteChannels,
        lineupsById: lineupsById,
        now: now,
        subtitleFor: subtitleFor,
        upcomingSubtitleFor: upcomingSubtitleFor,
        resolveLogoUrl: resolveLogoUrl,
        ownOtherVideoIdsByChannel: ownOtherVideoIdsByChannel,
        plexServerId: plexServerId,
        programmeItemsByChannel: programmeItemsByChannel,
      ),
    allChannels,
  ];
}

MediaHub _shelfHub({
  required String id,
  required String title,
  required List<TunarrChannel> channels,
  required Map<String, TunarrLineupChannel> lineupsById,
  required DateTime now,
  required String Function(TunarrChannel channel) subtitleFor,
  String Function(TunarrChannel channel, DateTime startsAt)? upcomingSubtitleFor,
  String? Function(String? iconPath)? resolveLogoUrl,
  Map<String, Set<String>> ownOtherVideoIdsByChannel = const {},
  String? plexServerId,
  Map<String, MediaItem> programmeItemsByChannel = const {},
}) {
  final items = [
    for (final channel in channels)
      _channelItem(
        channel: channel,
        lineup: lineupsById[channel.id],
        now: now,
        subtitleFor: subtitleFor,
        upcomingSubtitleFor: upcomingSubtitleFor,
        resolveLogoUrl: resolveLogoUrl,
        ownOtherVideoIds: ownOtherVideoIdsByChannel[channel.id] ?? const <String>{},
        plexServerId: plexServerId,
        programme: programmeItemsByChannel[channel.id],
      ),
  ];
  return MediaHub(id: id, identifier: id, title: title, type: 'mixed', size: items.length, items: items);
}

MediaItem _channelItem({
  required TunarrChannel channel,
  required TunarrLineupChannel? lineup,
  required DateTime now,
  required String Function(TunarrChannel channel) subtitleFor,
  String Function(TunarrChannel channel, DateTime startsAt)? upcomingSubtitleFor,
  String? Function(String? iconPath)? resolveLogoUrl,
  Set<String> ownOtherVideoIds = const {},
  String? plexServerId,
  MediaItem? programme,
}) {
  final airing = lineup == null ? null : galTvAiringAt(lineup, now);
  // A gap shows nothing of its own, so the card looks ahead instead: the next
  // programme's artwork and title, captioned with when it starts so it is not
  // mistaken for what is playing. Falling back to the channel's own logo only
  // when the window holds nothing more.
  final upcoming = airing != null || lineup == null
      ? null
      : galTvNextAiring(lineup, now, ownOtherVideoIds: ownOtherVideoIds);
  final shown = airing ?? upcoming;
  final ratingKey = shown?.ratingKey;
  final programmeArt = ratingKey == null ? null : _programmeArtPath(ratingKey, shown!.type);
  // Elapsed and total only for the item that is actually playing; a card showing
  // what comes next has no elapsed time to report.
  final (int? viewOffsetMs, int? durationMs) = switch (airing) {
    final GalTvAiring a => (
      now.difference(a.start).inMilliseconds.clamp(0, a.stop.difference(a.start).inMilliseconds),
      a.stop.difference(a.start).inMilliseconds,
    ),
    _ => (null, null),
  };
  final caption = upcoming != null
      ? (upcomingSubtitleFor ?? (channel, _) => subtitleFor(channel))(channel, upcoming.start)
      : subtitleFor(channel);
  // The card surface: a movie's Plex backdrop (16:9, what a wide card wants) or an
  // episode's own still, and the channel's logo when there is nothing to name.
  final thumbPath = programmeArt ?? resolveLogoUrl?.call(channel.iconPath);
  final tomatoes = _tomatoRatings(programme?.ratings);

  if (programme != null) {
    // **The same item every other Home shelf carries** — Plex's own mapping, as
    // returned by the client's `fetchItem`, so the preview's kind word, scores,
    // artwork, logo, episode numbering and blurb are the app's own rendering of the
    // same data rather than a reconstruction of it. Only what GalTV *owns* is
    // overridden:
    //
    // 1. the **id**, because the rail's tap routes through it;
    // 2. the **channel caption**;
    // 3. the **card surface** (our art rule, not the movie's portrait poster);
    // 4. the **channel's progress** — and `null` on a card that is only previewing
    //    what comes next, which freezed's `copyWith` *can* express (its nullable
    //    params are sentinels, so `null` clears). Plex's own resume point must never
    //    put a progress bar on a gap card.
    return programme.copyWith(
      id: galTvShelfItemId(channel.id),
      parentTitle: caption,
      thumbPath: thumbPath,
      viewOffsetMs: viewOffsetMs,
      durationMs: durationMs ?? programme.durationMs,
      // 5. the **scores**, trimmed to the tomatoes (see [_tomatoRatings]) — and with
      //    none, the bare scalar goes too rather than rendering a brand-less badge.
      ratings: tomatoes,
      rating: tomatoes.isEmpty ? null : programme.rating,
    );
  }

  // No Plex item — no client, a failed fetch, or a channel with nothing named.
  // The lineup's own fields still make a usable card.
  return MediaItem(
    id: galTvShelfItemId(channel.id),
    backend: MediaBackend.plex,
    kind: _programmeKind(shown?.type),
    title: shown?.title ?? channel.name,
    parentTitle: caption,
    // The rest is what the **TV spotlight** reads when the card takes focus: it
    // resolves an artwork client from `serverId` (without one its `/library/
    // metadata/...` path is unloadable and the preview is a blank gradient), draws
    // the backdrop from `artPath` and the wordmark from `clearLogoPath`, and prints
    // the synopsis and the year/rating/duration line under the title.
    serverId: plexServerId,
    summary: shown?.summary,
    year: shown?.year,
    contentRating: shown?.contentRating,
    artPath: programmeArt,
    // Plex keeps a `clearLogo` only for agent-backed libraries, so only a movie or
    // an episode gets the path — an `Other Videos` item has no wordmark and the
    // preview's title fallback is the honest answer there. The image itself is
    // resolved by `ClearLogoImage`, which falls back to the title when Plex has
    // nothing (the same contract the guide and the break slate rely on).
    clearLogoPath: _programmeLogoPath(ratingKey, shown?.type),
    // How far into what is *playing* — the app draws this off an item's own
    // position and duration (`MediaItem.hasActiveProgress`), the same bar
    // Continue Watching uses.
    viewOffsetMs: viewOffsetMs,
    durationMs: durationMs,
    thumbPath: thumbPath,
  );
}
