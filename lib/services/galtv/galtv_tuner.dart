import '../../models/galtv/galtv_guide.dart';
import '../../models/tunarr/tunarr_channel.dart';
import '../../models/tunarr/tunarr_lineup.dart';
import '../../models/tunarr/tunarr_now_playing.dart';
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
    this.isFiller = false,
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

  /// Whether this item is an **ad** — a filler Tunarr drew for a `flex`, not
  /// programming (see [galTvProgramIsFiller]).
  ///
  /// The player needs this even when fillers are allowed to play: an ad is a break
  /// the viewer is sitting through, and "what is next" is exactly the question a
  /// break raises — so the chrome offers the Up-Next slate for the duration. It is
  /// also what `hideFillers` turns into a wait, but the flag is set either way, so
  /// the two features never have to agree.
  final bool isFiller;

  @override
  String toString() =>
      'GalTvTunePlan(channel: ${channel.number} ${channel.name}, ratingKey: $plexRatingKey, '
      'seekOffset: ${seekOffset.inSeconds}s, remainingMs: $remainingMs)';
}

/// How far an *armed* item may sit from its due moment before it stops being the
/// item that should be starting — shared by the tab and the player so both drop
/// stale arms the same way. Playback drift (a pause, a seek back, a route left
/// parked) and a suspended app both move the real boundary; past this the
/// schedule has genuinely moved on and one fresh read is the honest answer.
const Duration galTvArmTolerance = Duration(seconds: 20);

/// Whether an item armed for [dueAt] is still due at [now]. Symmetric: an arm
/// that is due *early* is as suspect as one that is late, because both mean the
/// clock the arm was computed from is no longer the one playback is following.
bool galTvArmIsDue(DateTime dueAt, DateTime now, {Duration tolerance = galTvArmTolerance}) =>
    now.difference(dueAt).abs() <= tolerance;

/// One step of a channel's **item** sequence.
///
/// `native-playback` describes the schedule at *item* level, not slot level:
/// while a programme plays, its `next` is already the item that starts when it
/// ends — normally the filler Tunarr picked for the following break. A `flex`
/// step is a **timed wait**: Tunarr shortens it to the instant something becomes
/// eligible again, and its `next` names the item that plays when the wait runs
/// out. So a viewer never has to ask "what now?" twice — the step at hand says
/// both what to play and what comes after it.
class GalTvItemStep {
  const GalTvItemStep.play(GalTvTunePlan this.plan) : waitFor = null;
  const GalTvItemStep.wait(this.waitFor) : plan = null;

  /// The item to play — set exactly when this step is playable.
  final GalTvTunePlan? plan;

  /// How long an unplayable (`flex`) step runs, straight from the server.
  final Duration? waitFor;

  bool get isPlayable => plan != null;

  /// This step's own length: the wait, or the item's server-reported remainder.
  Duration get duration => waitFor ?? Duration(milliseconds: plan!.remainingMs);

  @override
  String toString() =>
      'GalTvItemStep(${plan?.toString() ?? 'wait ${waitFor?.inSeconds}s'})';
}

/// One `native-playback` answer, read as an item sequence: what is on now, what
/// follows it, and Tunarr's own clock at the read.
///
/// **[next] is not decoration — it is the whole point of the type.** Reading
/// `native-playback` is a *write*: the calculator records a play-history row for
/// every content-backed item it computes, and the endpoint computes two per
/// request — `current` at `now`, `next` at `now + current.streamDuration + 1`, the
/// second stamped in the **future**. That future row is what the filler picker's
/// per-list cooldown reads, so a client that re-reads instead of playing what the
/// response named pushes the channel's filler list into cooldown and starves the
/// very break it is asking about. Measured 2026-10-08 on `TEST FILLERS`: two
/// reads 8 s apart mid-break turned `flex 57 s → "Sucrets"` into
/// `flex 148 s → "full"`; a 6 s poll loop kept a 150 s break empty for its whole
/// length. Hence: **one read per item, and the returned [next] is played at the
/// boundary without asking again.**
class GalTvTuneResult {
  const GalTvTuneResult({
    required this.channel,
    required this.current,
    this.next,
    required this.serverTimeMs,
    this.logoUrl,
  });

  /// The channel this read is about — the identity the player adopts when it
  /// follows a guide tap, *including* when the channel is in a gap and there is
  /// no plan to carry it.
  final TunarrChannel channel;

  /// Client-loadable logo of [channel], resolved by the tab (which owns the gate
  /// base URL).
  final String? logoUrl;

  /// What is airing now — playable, or a wait.
  final GalTvItemStep current;

  /// The item that starts when [current] ends, or null at the end of the window.
  final GalTvItemStep? next;

  /// Tunarr's clock at the read, for wall-clock comparisons the device clock
  /// must not make (a TV with a wrong clock still lands on the same frame).
  final int serverTimeMs;

  /// The playable item on air right now, when there is one.
  GalTvTunePlan? get plan => current.plan;

  @override
  String toString() => 'GalTvTuneResult($current, next: $next)';
}

/// Resolves "what is playing on channel X right now" into a Plex item, and
/// decides which channel to tune on entry.
///
/// Deliberately player-agnostic: it only talks to Tunarr and returns a result, so
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

  /// Read the channel's **item sequence** — what is on now and what follows it.
  ///
  /// One call, one read of Tunarr's stateful endpoint (see [GalTvTuneResult] for
  /// why that matters). Null only when the channel has no schedule at all.
  ///
  /// A step is a *wait* when the schedule has nothing direct-playable — a `flex`
  /// break or a redirect — because those carry no Plex identity and must never
  /// reach the Plex resolver; the wait's length is what the server says is left
  /// of it, which is the moment to come back.
  ///
  /// [hideFillers] is the "hide ads" setting. When set, a playable item that is an
  /// **ad** — an `Other Videos` item the channel does not schedule itself, see
  /// [galTvProgramIsFiller] — is **also** turned into a wait of its own length.
  /// That is the whole feature: the viewer never sees the ad, the slate stays up
  /// through the break, and the programme after it still starts at its scheduled
  /// second. Because the same flag is applied to `next` as well as `current`, the
  /// sequence rebuilds itself into ad-free steps with no extra read — the
  /// item-sequence rule (one read per item) is unchanged by it.
  ///
  /// The flag is read per probe, so toggling it mid-break takes effect at the
  /// next boundary rather than retroactively un-playing an armed item.
  Future<GalTvTuneResult?> probe(
    TunarrChannel channel, {
    String? Function(String? iconPath)? resolveLogoUrl,
    bool hideFillers = false,
  }) async {
    final nowPlaying = await client.fetchNowPlaying(channel.id);
    final current = nowPlaying?.current;
    if (nowPlaying == null || current == null) return null;

    return GalTvTuneResult(
      channel: channel,
      logoUrl: resolveLogoUrl?.call(channel.iconPath),
      current: await _stepFor(channel, current, resolveLogoUrl, hideFillers),
      next: await _stepFor(channel, nowPlaying.next, resolveLogoUrl, hideFillers),
      serverTimeMs: nowPlaying.serverTimeMs,
    );
  }

  /// Turn one side of a `native-playback` answer into a step.
  ///
  /// Not playable, or a playable item whose program carries no Plex `externalId`,
  /// both become a wait of the item's own length: the viewer stays put and the
  /// next step is resolved when it runs out, rather than handing the Plex
  /// resolver something it cannot open.
  ///
  /// A **filler** is a third case, and it only becomes a wait under
  /// [hideFillers]; otherwise it plays like anything else. See
  /// [galTvProgramIsFiller] for how it is identified: an `Other Videos` item the
  /// channel does **not** schedule itself is one Tunarr drew for a break.
  Future<GalTvItemStep> _stepFor(
    TunarrChannel channel,
    TunarrPlaybackItem? item,
    String? Function(String? iconPath)? resolveLogoUrl,
    bool hideFillers,
  ) async {
    if (item == null) return const GalTvItemStep.wait(Duration.zero);
    final wait = GalTvItemStep.wait(Duration(milliseconds: item.remainingMs));
    if (!item.isPlayable) return wait;

    final program = await client.fetchProgramRef(item.programId);
    if (program == null) return wait;
    // The channel's own `Other Videos` content, asked for **only** when the item
    // could be an ad at all: a film or an episode is a programme by construction,
    // so a per-item round trip for them would buy nothing. The lookup degrades to
    // an empty set on failure, never to a failed probe.
    final ownOtherVideoIds = program.isOtherVideo
        ? await client.fetchChannelOwnOtherVideoProgramIds(channel.id)
        : const <String>{};
    final isFiller = galTvProgramIsFiller(
      type: program.type,
      programId: item.programId,
      channelOwnOtherVideoIds: ownOtherVideoIds,
    );
    if (hideFillers && isFiller) return wait;

    return GalTvItemStep.play(
      GalTvTunePlan(
        channel: channel,
        plexRatingKey: program.ratingKey,
        programId: item.programId,
        seekOffset: Duration(milliseconds: item.seekOffsetMs),
        // For `next` this is the item's full length, because the server computes
        // it at the instant that item starts.
        remainingMs: item.remainingMs,
        title: item.title,
        logoUrl: resolveLogoUrl?.call(channel.iconPath),
        isFiller: isFiller,
      ),
    );
  }

  /// Each channel's own `Other Videos` content, keyed by channel id — the second
  /// half of [galTvProgramIsFiller] for anything that maps a **lineup** rather
  /// than a plan (the guide rows, and through them the slate, the miniature hint
  /// and the Home shelf).
  ///
  /// Only channels whose lineup actually carries an `other_video` program are
  /// asked: a channel of films and episodes cannot be ambiguous, and skipping it
  /// keeps a normal deployment at **zero** extra calls. The rest are fetched in
  /// parallel; a failure yields an empty set for that channel, which reverts it
  /// to the coarse rule rather than failing the caller.
  Future<Map<String, Set<String>>> ownOtherVideoIdsByChannel(
    Iterable<TunarrLineupChannel> lineups,
  ) async {
    final needed = <String>[
      for (final lineup in lineups)
        if (lineup.slots.any((slot) => slot.program?.type == 'other_video')) lineup.id,
    ];
    if (needed.isEmpty) return const <String, Set<String>>{};
    final resolved = await Future.wait(needed.map(client.fetchChannelOwnOtherVideoProgramIds));
    return <String, Set<String>>{
      for (var index = 0; index < needed.length; index++) needed[index]: resolved[index],
    };
  }
}
