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
List<GalTvGuideRow> galTvGuideRows({
  required List<TunarrLineupChannel> channels,
  required DateTime windowStart,
  required DateTime windowEnd,
  String? currentChannelId,
  String? currentProgramId,
  String? Function(String? iconPath)? resolveLogoUrl,
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
}) {
  final entries = <GalTvGuideEntry>[];
  for (final slot in channel.slots) {
    final start = slot.start < windowStartMs ? windowStartMs : slot.start;
    final stop = slot.stop > windowEndMs ? windowEndMs : slot.stop;
    // Entirely outside the window: it has no place on a time-aligned row.
    if (stop <= start) continue;
    entries.add(
      GalTvGuideEntry(
        title: slot.program?.title ?? slot.type,
        start: DateTime.fromMillisecondsSinceEpoch(start),
        stop: DateTime.fromMillisecondsSinceEpoch(stop),
        ratingKey: slot.isPlayable ? slot.program?.externalId : null,
        isPlayable: slot.isPlayable,
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
