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
  });

  final String channelId;
  final String channelNumber;
  final String channelName;

  /// Client-loadable channel logo, or null when the channel has no icon — the
  /// row then keeps its plain number-and-name column.
  final String? logoUrl;

  final List<GalTvGuideEntry> entries;
}

/// Map Tunarr's `/api/channels/all/lineups` payload into guide rows.
///
/// [currentChannelId] / [currentProgramId] come from the running player (the
/// `native-playback` join key), and mark which cell is "now" — Tunarr's slot
/// `id` equals `current.programId`, so the match is exact rather than
/// time-derived.
List<GalTvGuideRow> galTvGuideRows({
  required List<TunarrLineupChannel> channels,
  String? currentChannelId,
  String? currentProgramId,
  String? Function(String? iconPath)? resolveLogoUrl,
}) {
  return [
    for (final channel in channels)
      GalTvGuideRow(
        channelId: channel.id,
        channelNumber: channel.number,
        channelName: channel.name,
        logoUrl: resolveLogoUrl?.call(channel.iconPath),
        entries: [
          for (final slot in channel.slots)
            GalTvGuideEntry(
              title: slot.program?.title ?? slot.type,
              start: DateTime.fromMillisecondsSinceEpoch(slot.start),
              stop: DateTime.fromMillisecondsSinceEpoch(slot.stop),
              ratingKey: slot.isPlayable ? slot.program?.externalId : null,
              isPlayable: slot.isPlayable,
              isCurrent: channel.id == currentChannelId && slot.id == currentProgramId,
            ),
        ],
      ),
  ];
}
