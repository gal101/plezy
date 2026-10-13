import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../tunarr/tunarr_lineup.dart';

/// One programme cell in the GalTV guide.
///
/// Deliberately decoupled from Tunarr's wire shape: the overlay that draws the
/// grid never parses JSON, and the tab that owns the network call never builds
/// widgets. See `plezy-tunarr/client-integration.md` §4.1 for why the whole grid
/// comes from a single range call.
class GalTvGuideEntry {
  const GalTvGuideEntry({
    required this.title,
    required this.start,
    required this.stop,
    required this.isPlayable,
    required this.isCurrent,
    this.ratingKey,
    this.isBreak = false,
    this.isFiller = false,
  });

  final String title;
  final DateTime start;
  final DateTime stop;

  /// The Plex `ratingKey` of the underlying item (Tunarr's `externalId`), used
  /// to paint the cell's backdrop through the app's normal Plex image pipeline.
  /// Null for a slot with no Plex identity (`flex`, `redirect`).
  final String? ratingKey;

  /// `content` / `custom` slots resolve to a Plex item; `flex` (a break) and
  /// `redirect` (a pointer to another channel) do not, and must never be sent to
  /// the Plex resolver.
  final bool isPlayable;

  /// The slot is a Tunarr **`flex`** — scheduled break time, not programming.
  ///
  /// Deliberately narrower than `!isPlayable`: a `redirect` is also unplayable
  /// but points at another channel, and calling that an ad break would be a lie.
  ///
  /// Worth knowing which cells can carry this at all: Tunarr **only emits a
  /// `flex` entry when it is longer than 30 minutes** — anything shorter is melded
  /// into the programme before it (`TVGUIDE_MAXIMUM_PADDING_LENGTH_MS`, see
  /// `AGENT.md` §5). So a break cell is always a substantial one.
  final bool isBreak;

  /// The slot **is playable but is an ad** — a Tunarr filler, drawn by Tunarr to
  /// fill a `flex` rather than scheduled by the channel.
  ///
  /// Decided by [galTvProgramIsFiller], which is the same rule the player runs,
  /// and it exists here for one reason: a filler is playable, so "what is next"
  /// would happily name the next *ad* — a channel whose breaks are padded with
  /// clips (the owner's `TEST FILLERS`) would answer "up next: Nemo danseaza".
  /// Nothing that promises a programme may name one of these.
  final bool isFiller;

  /// The slot the tuned channel is inside right now — what the guide should
  /// highlight.
  final bool isCurrent;

  Duration get duration => stop.difference(start);
}

/// One channel's row in the guide.
class GalTvGuideRow {
  const GalTvGuideRow({
    required this.channelId,
    required this.channelNumber,
    required this.channelName,
    required this.entries,
    this.logoUrl,
    this.leadingMs = 0,
  });

  final String channelId;
  final String channelNumber;
  final String channelName;

  /// Client-loadable channel logo, or null when the channel has no icon — the
  /// row then keeps its plain number-and-name column.
  final String? logoUrl;

  final List<GalTvGuideEntry> entries;

  /// How far this row's first cell sits from the fetched window's start.
  ///
  /// Every row is clamped to the *same* window, so the same `x` is the same time
  /// on every row — the grid's whole point. A channel whose schedule has a gap at
  /// the window start therefore needs a leading spacer (this value) or its first
  /// cell would land at `x` = the window start and every later cell would be early
  /// on that row alone.
  final int leadingMs;
}

/// Whether a Tunarr program is an **ad** (a filler) rather than programming.
///
/// Two facts are needed, and the library type alone is not enough:
///
/// 1. `type == 'other_video'` — Tunarr only ever fills a break from a Plex
///    `Other Videos` library (`client-integration.md` §3b), so anything else is a
///    programme by construction.
/// 2. The **channel must not schedule the item itself**. A channel may carry
///    clips from such a library as its own content — the owner's `TEST FILLERS`
///    is built exactly that way (three `Test`-library clips on a 150 s break) — and
///    a library-typed rule put ad chrome and an UP NEXT button over his clips
///    while he was watching them as programmes (reported 2026-10-09). What
///    separates the two is provenance: `GET /api/channels/{id}/programs` names
///    every program the channel carries (`?type=other_video` narrows it to the
///    ones that matter), so an `other_video` item *outside* that set is one Tunarr
///    drew to fill a `flex`.
///
/// Both halves are required. A film or an episode is never an ad even when the
/// channel does not schedule it, and an unscheduled `other_video` item always is.
bool galTvProgramIsFiller({
  required String? type,
  required String programId,
  required Set<String> channelOwnOtherVideoIds,
}) => type == 'other_video' && !channelOwnOtherVideoIds.contains(programId);

/// Map Tunarr's `/api/channels/all/lineups` payload into guide rows.
///
/// [currentChannelId] / [currentProgramId] come from the running player (the
/// `native-playback` join key), and mark which cell is "now" — Tunarr's slot
/// `id` equals `current.programId`, so the match is exact rather than
/// time-derived.
///
/// [windowStart] / [windowEnd] are the range the tab actually fetched. Every row
/// is clamped to that window so the rows share one time origin: a slot that began
/// before the window (or runs past it) is cut to the window edge, and a slot
/// entirely outside is dropped. Without this each row started at its own first
/// programme, so the same `x` was a different time on every channel and no ruler
/// above the grid could be honest. The amount a row is short at the start is
/// recorded as [GalTvGuideRow.leadingMs].
///
/// [ownOtherVideoIdsByChannel] is each channel's own `Other Videos` content as
/// program id — the second half of [galTvProgramIsFiller]. Callers pass what
/// `TunarrClient.fetchChannelOwnOtherVideoProgramIds` returned, per channel id; a
/// channel missing from the map (the usual case: its content is movies and
/// episodes, so nothing needs asking) is treated as having none.
List<GalTvGuideRow> galTvGuideRows({
  required List<TunarrLineupChannel> channels,
  required DateTime windowStart,
  required DateTime windowEnd,
  String? currentChannelId,
  String? currentProgramId,
  String? Function(String? iconPath)? resolveLogoUrl,
  Map<String, Set<String>> ownOtherVideoIdsByChannel = const {},
}) {
  final windowStartMs = windowStart.millisecondsSinceEpoch;
  final windowEndMs = windowEnd.millisecondsSinceEpoch;
  return [
    for (final channel in channels)
      _guideRow(
        channel: channel,
        windowStartMs: windowStartMs,
        windowEndMs: windowEndMs,
        currentChannelId: currentChannelId,
        currentProgramId: currentProgramId,
        resolveLogoUrl: resolveLogoUrl,
        ownOtherVideoIds: ownOtherVideoIdsByChannel[channel.id] ?? const <String>{},
      ),
  ];
}

GalTvGuideRow _guideRow({
  required TunarrLineupChannel channel,
  required int windowStartMs,
  required int windowEndMs,
  required String? currentChannelId,
  required String? currentProgramId,
  required String? Function(String? iconPath)? resolveLogoUrl,
  required Set<String> ownOtherVideoIds,
}) {
  final entries = <GalTvGuideEntry>[];
  for (final slot in channel.slots) {
    final start = slot.start < windowStartMs ? windowStartMs : slot.start;
    final stop = slot.stop > windowEndMs ? windowEndMs : slot.stop;
    // Entirely outside the window: it has no place on a time-aligned row.
    if (stop <= start) continue;
    entries.add(
      GalTvGuideEntry(
        // Empty for a gap, never the wire's own `type`. A `flex`/`redirect` slot
        // has no program, and the fallback that used to sit here printed the raw
        // API value — the owner's screenshot of channel 4 showed cells literally
        // captioned `flex`. The cell keeps its duration either way: the strip is
        // laid out by cumulative pitch, so dropping the entry would slide every
        // later cell off its own start time.
        title: slot.program?.title?.trim() ?? '',
        start: DateTime.fromMillisecondsSinceEpoch(start),
        stop: DateTime.fromMillisecondsSinceEpoch(stop),
        ratingKey: slot.isPlayable ? slot.program?.externalId : null,
        isPlayable: slot.isPlayable,
        isBreak: slot.type == 'flex' || slot.type == 'offline',
        // The slot `id` is the program's uuid — the same key `native-playback`
        // reports as `programId` and the one `fetchChannelOwnOtherVideoProgramIds`
        // returns, so the two halves of the rule line up exactly.
        isFiller: galTvProgramIsFiller(
          type: slot.program?.type,
          programId: slot.id,
          channelOwnOtherVideoIds: ownOtherVideoIds,
        ),
        isCurrent: channel.id == currentChannelId && slot.id == currentProgramId,
      ),
    );
  }

  // Slots arrive in schedule order, so the first kept entry is the earliest:
  // whatever it was cut by is the gap this row has at the window start.
  final leadingMs = entries.isEmpty ? 0 : entries.first.start.millisecondsSinceEpoch - windowStartMs;

  return GalTvGuideRow(
    channelId: channel.id,
    channelNumber: channel.number,
    channelName: channel.name,
    logoUrl: resolveLogoUrl?.call(channel.iconPath),
    leadingMs: leadingMs,
    entries: entries,
  );
}

/// The next direct-playable programme on a channel — what the in-player "Up
/// next" slate shows while a break has nothing to play.
///
/// [startsAt] is the slot's own start time as Tunarr authored it, so displaying
/// it needs a timezone, never a trust in the device clock.
class GalTvUpNext {
  const GalTvUpNext({
    required this.channelId,
    required this.title,
    required this.startsAt,
    this.ratingKey,
  });

  /// The channel this payload was picked for. **The slate's label and its title
  /// must come from the same channel**: the label is drawn from whatever channel
  /// is on screen now, so a payload left over from a channel the viewer just left
  /// would read as "CH 2 · UP NEXT <a channel 3 programme>" — the owner's
  /// 2026-10-08 report. Both hosts therefore refuse a payload whose [channelId] is
  /// not the channel they are showing, instead of trusting their own timing.
  final String channelId;

  final String title;
  final DateTime startsAt;
  final String? ratingKey;

  @override
  String toString() => 'GalTvUpNext($channelId: $title at $startsAt)';
}

/// The Plex artwork and blurb behind one "Up next" slate.
///
/// Deliberately narrow: it is exactly the handful of fields the slate paints,
/// resolved once per payload so the widget itself never touches a network model.
/// Every field is optional, because the honest answer for most of them on an
/// `Other Videos` item is "Plex has none" — see [logoPath].
class GalTvUpNextMedia {
  const GalTvUpNextMedia({
    this.title,
    this.subtitle,
    this.episodeLabel,
    this.summary,
    this.year,
    this.contentRating,
    this.duration,
    this.logoPath,
    this.artPath,
  });

  /// What the slate heads itself with. For an episode this is the **show** name
  /// (`MediaItem.displayTitle` already prefers the grandparent), because the show
  /// is what the viewer recognises and what the logo — the show's `clearLogo` —
  /// says anyway.
  final String? title;

  /// The episode's own title, when this is one. Null for a film.
  final String? subtitle;

  /// "S01E01" for an episode, null for anything else.
  ///
  /// Padded on purpose, which is a deliberate split from the two sibling forms in
  /// the codebase (`playlist_item_card.dart:246`, `livetv_program.dart:179` both
  /// print the compact `S1E1`): those sit in a list row read at arm's length,
  /// this one is the only text on a TV screen read from across a room.
  final String? episodeLabel;

  /// Synopsis (`MediaItem.summary`), shown under the title.
  final String? summary;

  final int? year;
  final String? contentRating;
  final Duration? duration;

  /// Plex `clearLogo` — the film's own wordmark, drawn instead of the title.
  ///
  /// **Null for anything Plex has no metadata agent for.** A `clearLogo` is
  /// agent artwork: the `Plex Movie` / `Plex TV Series` agents fetch it, while a
  /// video-file library (the `Other Videos` library every filler list is built
  /// from) has no agent and therefore no logo. The slate must therefore treat a
  /// missing logo as the normal case, not an error, and fall back to the title.
  final String? logoPath;

  /// Wide Plex `art`, used as the full-bleed backdrop.
  final String? artPath;

  /// Whether anything resolved at all — a slate with nothing to add falls back
  /// to the plain title card.
  bool get isEmpty =>
      (title ?? '').isEmpty &&
      (summary ?? '').isEmpty &&
      logoPath == null &&
      artPath == null &&
      year == null &&
      contentRating == null;

  /// The slate's view of a Plex item — the one mapping from `MediaItem`, shared
  /// by the overlay and the settings preview so the two can never drift.
  factory GalTvUpNextMedia.fromItem(MediaItem item) => GalTvUpNextMedia(
    title: item.displayTitle,
    subtitle: item.displaySubtitle,
    episodeLabel: _episodeLabel(item),
    summary: item.summary,
    year: item.year,
    contentRating: item.contentRating,
    duration: item.durationMs == null ? null : Duration(milliseconds: item.durationMs!),
    logoPath: item.clearLogoPath,
    artPath: item.artPath,
  );

  /// `S01E01`, or `E01` when Plex gave no season number.
  ///
  /// Null for anything that is not a single episode: numbering is a TV affordance
  /// and a film has nothing to number. `parentIndex`/`index` are Plex's
  /// season/episode pair, the same reading `livetv_program.dart:179` makes.
  static String? _episodeLabel(MediaItem item) {
    if (item.kind != MediaKind.episode) return null;
    final episode = item.index;
    if (episode == null) return null;
    final number = episode.toString().padLeft(2, '0');
    final season = item.parentIndex;
    return season == null ? 'E$number' : 'S${season.toString().padLeft(2, '0')}E$number';
  }

  /// The same item **without any artwork** — the case every filler and every
  /// `Other Videos` item is in, and the one worth previewing.
  GalTvUpNextMedia withoutArtwork() => GalTvUpNextMedia(
    title: title,
    subtitle: subtitle,
    episodeLabel: episodeLabel,
    summary: summary,
    year: year,
    contentRating: contentRating,
    duration: duration,
  );

  GalTvUpNextMedia withSummary(String? value) => GalTvUpNextMedia(
    title: title,
    subtitle: subtitle,
    episodeLabel: episodeLabel,
    summary: value,
    year: year,
    contentRating: contentRating,
    duration: duration,
    logoPath: logoPath,
    artPath: artPath,
  );
}

/// The first playable cell on [channelId] that starts at or after [serverNow],
/// or null when the fetched window has nothing left to play.
///
/// [serverNow] **must** come from Tunarr's `native-playback.serverTimeMs`: the
/// guide rows carry server-authored slot times, so anchoring the comparison on
/// the device clock would name the wrong programme on a TV whose clock is off —
/// the same reason playback never derives its offset locally.
///
/// A break is simply skipped: the `flex` cell covering "now" is not playable, so
/// the scan walks past it to the programme after it.
GalTvUpNext? galTvUpNext(List<GalTvGuideRow> rows, String channelId, DateTime serverNow) {
  for (final row in rows) {
    if (row.channelId != channelId) continue;
    for (final entry in row.entries) {
      if (!entry.isPlayable || entry.ratingKey == null) continue;
      // A break is already excluded above (it is not playable) — but a **filler**
      // is ordinary playable content, and naming it would answer "what is next"
      // with the next *ad*: on a channel whose breaks are padded with clips the
      // slate and the miniature hint would both say "up next: a 30 second
      // bumper". Keep walking, exactly like the Home shelf's look-ahead.
      if (entry.isFiller) continue;
      if (entry.start.isBefore(serverNow)) continue;
      return GalTvUpNext(
        channelId: channelId,
        title: entry.title,
        startsAt: entry.start,
        ratingKey: entry.ratingKey,
      );
    }
  }
  return null;
}
