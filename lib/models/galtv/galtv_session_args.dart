import 'package:flutter/foundation.dart';

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
    this.guideProvider,
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

  /// Supplies the guide grid. Injected by the GalTV tab so the player never talks
  /// to Tunarr directly and the overlay stays a pure widget.
  final Future<List<GalTvGuideRow>> Function()? guideProvider;

  /// Resolves a channel's *current* airing into a launch target. Injected by the
  /// tab (which owns Tunarr); the player only receives the finished plan, so it
  /// still never speaks to Tunarr itself. Null when the channel has nothing
  /// direct-playable right now.
  final Future<GalTvTunePlan?> Function(String channelId)? channelResolver;

  /// Resolves the neighbouring channel's current airing for a surf: [delta] is
  /// `-1` (previous) or `+1` (next). Injected by the tab alongside
  /// [channelResolver].
  final Future<GalTvTunePlan?> Function(int delta)? channelSurfer;

  /// Whether a neighbour exists in [delta]'s direction. Synchronous because the
  /// transport consults it while building, so a remote never offers a step the
  /// surf would refuse. Injected by the tab from its cached channel list.
  final bool Function(int delta)? hasSiblingChannel;

  /// Reports a successful switch back to the tab so it can persist the channel
  /// and keep its idle state in sync.
  final ValueChanged<GalTvTunePlan>? onChannelChanged;

  /// Called when the item finishes playing naturally, *before* the player tears
  /// down. The tab uses it to distinguish "programme ended, re-tune" from "user
  /// pressed back, show the idle state" — without it, re-tuning on every exit
  /// would trap the user in the route.
  final VoidCallback? onProgrammeEnded;

  /// Whether the guide layer is up. Owned here — not by the player — so the
  /// toggle button deep in the controls tree and the overlay in the screen-level
  /// `Stack` share one source of truth.
  final ValueNotifier<bool> guideVisible = ValueNotifier<bool>(false);

  bool get hasGuide => guideProvider != null;

  /// Whether the guide can tune a different channel. A session without a
  /// resolver still shows the grid, it just cannot switch from it.
  bool get canSwitchChannel => channelResolver != null;

  /// Returns true when [ratingKey] is the same item this session started on,
  /// i.e. a continuation segment rather than a new programme.
  bool isSameItem(String? ratingKey) => ratingKey != null && ratingKey == plexRatingKey;

  void dispose() => guideVisible.dispose();
}
