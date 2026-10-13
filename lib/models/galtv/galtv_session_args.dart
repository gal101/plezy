import 'package:flutter/foundation.dart';

import '../../models/tunarr/tunarr_channel.dart';
import '../../services/galtv/galtv_tuner.dart';
import 'galtv_guide.dart';

/// Marks a player session as a GalTV virtual-TV session.
///
/// This is deliberately **not** `LiveTvSessionArgs`: `isLive` switches the player
/// onto the live HLS branch and would undo the whole point of GalTV (Plex Direct
/// Play of the underlying file). GalTV instead plays as ordinary VOD and uses
/// this object for the two things it genuinely needs:
///
/// 1. **Watch-reporting suppression.** A channel is a schedule, not something the
///    user chose to watch — without suppression every hop writes `/:timeline`,
///    local history, tracker scrobbles and the offline queue. The player gates all
///    of that on `widget.galTv != null || widget.isLive`.
/// 2. **The guide layer.** [guideProvider] fills the grid and [guideVisible]
///    drives the in-player *TV Guide* toggle button, so the button and the overlay
///    share one source of truth while the player itself stays ignorant of Tunarr.
///
/// The channel identity is carried so end-of-programme chaining and channel
/// up/down can resolve the *next* item without re-deriving which channel is on.
class GalTvSessionArgs {
  GalTvSessionArgs({
    required this.channelId,
    required this.channelNumber,
    required this.channelName,
    this.channelLogoUrl,
    this.logoHeaders,
    required this.plexRatingKey,
    required this.programId,
    this.isFiller = false,
    this.armedNext,
    this.armedIn,
    this.guideProvider,
    this.nextProgrammeProvider,
    this.channelResolver,
    this.channelSurfer,
    this.hasSiblingChannel,
    this.onChannelChanged,
    this.onProgrammeEnded,
  });

  /// Tunarr channel id — the key for re-resolving "what's on now".
  final String channelId;

  /// Channel number and name, for the chrome ("CH 1 · Tom Cruise").
  final String channelNumber;
  final String channelName;

  /// Client-loadable logo of the tuned channel, or null when it has no icon.
  final String? channelLogoUrl;

  /// Headers for the logo request. The gate authenticates **every** proxied
  /// path, images included, so `Image.network` needs the same `X-Plex-Token`
  /// the API calls carry — it cannot piggyback on the Tunarr client.
  final Map<String, String>? logoHeaders;

  /// The Plex `ratingKey` currently playing; used to recognise a same-item
  /// continuation (a movie split by breaks arrives as several items with the same
  /// ratingKey and increasing `startOffsetMs` — a normal case, not an anomaly).
  final String plexRatingKey;

  /// Tunarr's program id for the current item. Equals the lineup slot `id`, which
  /// is how the guide marks "now" and how chaining finds the next item.
  final String programId;

  /// Whether the item being launched is a **filler** (an ad) — `plan.isFiller`.
  ///
  /// Seeded into the player's own flag, because nothing else would set it before
  /// the first boundary: the route is opened with a Plex item and a seek offset,
  /// not with a plan, so every later assignment comes from a *subsequent* item.
  /// Without this, tuning a channel that happens to be mid-ad showed no UP NEXT
  /// button and no ad chrome until the next item — the owner's 2026-10-09 report.
  final bool isFiller;

  /// The item the launching read named as the one that follows the item being
  /// opened, and how much of that launched item was left at the read. Together
  /// they let the route start *armed*: the first boundary of the session plays
  /// [armedNext] without asking Tunarr anything (a read records the filler it
  /// predicts, so re-asking is what starves a break — see `GalTvTuneResult`).
  final GalTvItemStep? armedNext;
  final Duration? armedIn;

  /// Supplies the guide grid. Injected by the GalTV tab so the player never talks
  /// to Tunarr directly and the overlay stays a pure widget.
  final Future<List<GalTvGuideRow>> Function()? guideProvider;

  /// Supplies the *next* direct-playable programme, for the "Up next" slate the
  /// player shows while a break has nothing to play. Injected by the tab, which
  /// anchors the comparison on Tunarr's `serverTimeMs` — the player must not
  /// derive "what's next" from the device clock. Null disables the slate; the
  /// player then simply waits for the next item.
  ///
  /// It must come from the **lineup**, not from another `native-playback` read:
  /// asking that endpoint during a break writes the very history rows that keep
  /// the break empty. The tab keeps a latched server clock for it.
  final Future<GalTvUpNext?> Function()? nextProgrammeProvider;

  /// Resolves a channel's **item sequence** — what is on now and what follows it
  /// — for launch and for end-of-item chaining. Injected by the tab (which owns
  /// Tunarr); the player only receives the finished result, so it still never
  /// speaks to Tunarr itself.
  ///
  /// The result carries the *next* step on purpose: reading `native-playback`
  /// records the filler it predicts for a future instant, so a client that
  /// re-reads instead of playing what it was handed starves the channel's breaks
  /// (see `GalTvTuneResult`). Callers hold the arm and play it at the boundary —
  /// they do not ask again.
  final Future<GalTvTuneResult?> Function(String channelId)? channelResolver;

  /// Resolves the neighbouring channel's item sequence for a surf: [delta] is
  /// `-1` (previous) or `+1` (next). Injected by the tab alongside
  /// [channelResolver].
  final Future<GalTvTuneResult?> Function(int delta)? channelSurfer;

  /// Whether a neighbour exists in [delta]'s direction. Synchronous because the
  /// transport consults it while building, so a remote never offers a step the
  /// surf would refuse. Injected by the tab from its cached channel list.
  final bool Function(int delta)? hasSiblingChannel;

  /// Reports the channel the session is now following back to the tab so it can
  /// persist it and keep its idle state in sync. [programId] is the item on air
  /// when there is one — null while a gap is being followed, which leaves that
  /// channel's guide cell unmarked rather than pointing at a stale item.
  final void Function(TunarrChannel channel, String? programId)? onChannelChanged;

  /// Called when the item finishes playing naturally, *before* the player tears
  /// down. The tab uses it to distinguish "programme ended, re-tune" from "user
  /// pressed back, show the idle state" — without it, re-tuning on every exit
  /// would trap the user in the route.
  final VoidCallback? onProgrammeEnded;

  /// Whether the guide layer is up. Owned here — not by the player — so the
  /// toggle button deep in the controls tree and the overlay in the screen-level
  /// `Stack` share one source of truth.
  final ValueNotifier<bool> guideVisible = ValueNotifier<bool>(false);

  /// What the break slate is showing, or null when no slate is up.
  ///
  /// Owned here for the same reason [guideVisible] is: the player writes it while
  /// it holds the route through an unplayable break, the overlay in the
  /// screen-level `Stack` reads it, and neither widget owns the other.
  final ValueNotifier<GalTvUpNext?> upNext = ValueNotifier<GalTvUpNext?>(null);

  /// The channel's next **programme**, kept current while a filler (an ad) plays,
  /// so the compact hint above the UP NEXT button always has something to show.
  ///
  /// Deliberately separate from [upNext], which is the **slate's** state: a
  /// non-null value there mounts the full-screen layer. Raising that layer is the
  /// viewer's decision — a slate appearing over an ad on its own is the jump scare
  /// the slate's own design rules out — so the hint cannot reuse it.
  final ValueNotifier<GalTvUpNext?> nextUp = ValueNotifier<GalTvUpNext?>(null);

  bool get hasGuide => guideProvider != null;

  /// Whether the guide can tune a different channel. A session without a
  /// resolver still shows the grid, it just cannot switch from it.
  bool get canSwitchChannel => channelResolver != null;

  /// Returns true when [ratingKey] is the same item this session started on,
  /// i.e. a continuation segment rather than a new programme.
  bool isSameItem(String? ratingKey) => ratingKey != null && ratingKey == plexRatingKey;

  void dispose() {
    guideVisible.dispose();
    upNext.dispose();
    nextUp.dispose();
  }
}
