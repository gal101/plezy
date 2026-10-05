import '../../models/tunarr/tunarr_channel.dart';
import '../tunarr/tunarr_client.dart';

/// Everything the player needs to start on a channel: the Plex item to open and
/// where in it to land.
///
/// [seekOffset] comes from Tunarr's `native-playback.current.seekOffsetMs` and is
/// never computed from the device clock — `serverTimeMs` exists so a TV with a
/// wrong clock still lands on the same frame as every other viewer.
class GalTvTunePlan {
  const GalTvTunePlan({
    required this.channel,
    required this.plexRatingKey,
    required this.programId,
    required this.seekOffset,
    required this.remainingMs,
    this.title,
    this.logoUrl,
  });

  final TunarrChannel channel;

  /// The Plex `ratingKey` of the item airing right now (Tunarr `externalId`).
  final String plexRatingKey;

  /// Tunarr's program id for the current item — the join key back into a lineup
  /// and what end-of-programme chaining resolves the *next* item from.
  final String programId;

  final Duration seekOffset;

  /// Server-reported time left in the current item, used to schedule the swap
  /// slightly ahead of expiry.
  final int remainingMs;

  final String? title;

  /// Client-loadable channel logo, resolved by the tab (which owns the gate
  /// base URL) — the player never builds Tunarr URLs itself.
  final String? logoUrl;

  @override
  String toString() =>
      'GalTvTunePlan(channel: ${channel.number} ${channel.name}, ratingKey: $plexRatingKey, '
      'seekOffset: ${seekOffset.inSeconds}s, remainingMs: $remainingMs)';
}

/// Resolves "what is playing on channel X right now" into a Plex item, and
/// decides which channel to tune on entry.
///
/// Deliberately player-agnostic: it only talks to Tunarr and returns a plan, so
/// it is unit-testable without a Flutter binding, a running player, or a Plex
/// server.
class GalTvTuner {
  GalTvTuner({required this.client});

  final TunarrClient client;

  Future<List<TunarrChannel>> loadChannels() => client.fetchChannels();

  /// The channel to tune when the tab opens: the last one the user watched if it
  /// still exists, otherwise the lowest-numbered channel — channel 1 on a fresh
  /// install. Null only when [channels] is empty.
  static TunarrChannel? pickInitialChannel(List<TunarrChannel> channels, String? lastChannelId) {
    if (channels.isEmpty) return null;

    final remembered = channelById(channels, lastChannelId);
    if (remembered != null) return remembered;

    return sortedByNumber(channels).first;
  }

  /// The channels in the order a viewer surfs them: channel number ascending,
  /// numeric numbers ahead of non-numeric ones. Tunarr's presenting order, which
  /// the wire list does not necessarily match.
  static List<TunarrChannel> sortedByNumber(Iterable<TunarrChannel> channels) =>
      [...channels]..sort(_byChannelNumber);

  static int _byChannelNumber(TunarrChannel a, TunarrChannel b) {
    final aNumber = int.tryParse(a.number);
    final bNumber = int.tryParse(b.number);
    if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
    if (aNumber != null) return -1;
    if (bNumber != null) return 1;
    return a.number.compareTo(b.number);
  }

  /// The channel named [channelId], or null when it is absent — or when the id
  /// is null/empty, which means "never tuned".
  static TunarrChannel? channelById(Iterable<TunarrChannel> channels, String? channelId) {
    if (channelId == null || channelId.isEmpty) return null;
    for (final channel in channels) {
      if (channel.id == channelId) return channel;
    }
    return null;
  }

  /// The channel [delta] steps from [fromChannelId] in surf order, or null when
  /// that would run off either end. Surfing clamps — it never wraps — so the last
  /// channel cannot silently teleport to the first.
  static TunarrChannel? neighbour(Iterable<TunarrChannel> channels, String? fromChannelId, int delta) {
    if (delta == 0 || fromChannelId == null || fromChannelId.isEmpty) return null;
    final sorted = sortedByNumber(channels);
    final index = sorted.indexWhere((channel) => channel.id == fromChannelId);
    if (index < 0) return null;
    final target = index + delta;
    if (target < 0 || target >= sorted.length) return null;
    return sorted[target];
  }

  /// Resolve the current item on [channelId] to a playable Plex item.
  ///
  /// Returns null when there is nothing direct-playable right now: an empty
  /// schedule, or a `flex`/`redirect` slot (a break or a pointer to another
  /// channel) — those have no Plex identity, so passing one to the Plex resolver
  /// would fail on the TV.
  Future<GalTvTunePlan?> planFor(TunarrChannel channel, {String? Function(String? iconPath)? resolveLogoUrl}) async {
    final nowPlaying = await client.fetchNowPlaying(channel.id);
    final current = nowPlaying?.current;
    if (current == null || !current.isPlayable) return null;

    final ratingKey = await client.fetchPlexRatingKey(current.programId);
    if (ratingKey == null || ratingKey.isEmpty) return null;

    return GalTvTunePlan(
      channel: channel,
      plexRatingKey: ratingKey,
      programId: current.programId,
      seekOffset: Duration(milliseconds: current.seekOffsetMs),
      remainingMs: current.remainingMs,
      title: current.title,
      logoUrl: resolveLogoUrl?.call(channel.iconPath),
    );
  }
}
