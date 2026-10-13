import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../mixins/refreshable.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../models/galtv/galtv_session_args.dart';
import '../../models/tunarr/tunarr_channel.dart';
import '../../providers/tunarr_account_provider.dart';
import '../../services/galtv/galtv_tuner.dart';
import '../../services/settings_service.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/video_player_navigation.dart';
import '../libraries/state_messages.dart';
import '../../widgets/galtv/galtv_up_next_overlay.dart';
import '../../widgets/galtv/galtv_guide_overlay.dart';

/// The GalTV tab: a lean-back virtual TV channel backed by Tunarr's schedule but
/// played as a Plex Direct Play.
///
/// Entering the tab tunes the last channel the user watched (channel 1 on a
/// fresh install) and opens the player on whatever is airing *right now*, at
/// Tunarr's own offset. The guide is a layer inside that player route, not a
/// separate screen — see `plezy-tunarr/client-integration.md` §3.2.
///
/// This screen therefore holds almost no UI of its own: it resolves a channel to
/// a playable Plex item, launches the player, and shows a loading/error/idle
/// state in the gaps.
class GalTvScreen extends StatefulWidget {
  const GalTvScreen({super.key, this.onExitToHome});

  /// Called when the viewer leaves the player with **Back** instead of letting
  /// the programme end. At that point the tab has nothing worth showing — its
  /// idle card is a lone Watch button — so the shell hands them back to Home; the
  /// tab re-tunes on the next entry. Null (a bare screen, e.g. in a test) keeps
  /// the idle state, which is the old behaviour.
  final VoidCallback? onExitToHome;

  @override
  State<GalTvScreen> createState() => _GalTvScreenState();
}

class _GalTvScreenState extends State<GalTvScreen> with FocusableTab {
  bool _resolving = false;
  String? _error;
  TunarrChannel? _lastChannel;

  /// Channels in surf order, cached at each tune so the guide's tap targets and
  /// the player's next/previous bounds answer without a network call. Refreshed
  /// lazily if a tap names a channel this cache has never seen.
  List<TunarrChannel> _channels = const [];

  /// The channel and programme on screen right now. The player moves these
  /// through [GalTvSessionArgs.onChannelChanged] on every switch, so the guide's
  /// "now" marker follows the picture instead of the launch plan.
  String? _activeChannelId;
  String? _activeProgramId;

  /// Set by the player's completion callback so returning here can tell "the
  /// programme ended, re-tune" from "the user pressed back, show the idle state".
  /// Re-tuning on every exit would trap the user in the player route.
  bool _programmeEnded = false;

  /// The channel is in a break with nothing playable *right now*, so the tab waits
  /// for the next programme instead of declaring an error.
  ///
  /// This is the entry-path half of the player's break hold, and it matters more
  /// than it looks: entering during a `flex` gap is the common case, not the edge
  /// case — on a 9-minute loop of 30 s clips with 150 s breaks, 83 % of the time
  /// is gap. Treating that as a fatal error dead-ends the viewer on a Retry card
  /// they cannot escape, because the guide (which is how you change channel) lives
  /// in the player route, not here.
  bool _waitingForStart = false;
  GalTvUpNext? _upNext;
  Timer? _waitTimer;

  /// The step the read that put the tab into its waiting state already named as
  /// the one that follows — played at the wake moment *without* asking Tunarr
  /// again, because every `native-playback` read records the filler it predicts
  /// (see `GalTvTuneResult`) and re-asking is what keeps a break empty.
  GalTvItemStep? _armedStep;

  /// When [_armedStep] falls due. A wake that lands far from it (a timer the OS
  /// suspended) means the arm no longer names what should be starting, so it is
  /// dropped and the channel is read instead.
  DateTime? _armedDueAt;

  /// Tunarr's clock, latched at the last read, with the local instant it was
  /// read. Everything that needs "what time is it on the server" — the "Up next"
  /// slate above all — is computed from this pair instead of spending another
  /// stateful read on it. Device clock drift over a session is milliseconds; a
  /// *wrong* device clock cannot creep in at all, because only the elapsed
  /// difference is taken locally.
  int? _serverTimeMs;
  DateTime? _serverClockReadAt;

  /// The channel list, opened from the waiting card. The same
  /// [GalTvGuideOverlay] the player shows — the tab would otherwise be a dead end
  /// during a break, because the guide is the only way to change channel.
  bool _guideOpen = false;
  List<GalTvGuideRow>? _rows;
  bool _rowsLoading = false;
  String? _rowsError;
  bool _switching = false;

  /// Headers every channel-logo request needs (the gate authenticates images too,
  /// so `Image.network` cannot piggyback on the Tunarr client).
  Map<String, String>? _logoHeaders;

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  @override
  void focusActiveTabIfReady() {
    // Entering the tab always tunes. Guarded so a rebuild cannot stack tunes.
    if (_resolving) return;
    unawaited(_tune());
  }

  Future<void> _tune() async {
    if (_resolving) return;

    final account = context.read<TunarrAccountProvider>();
    final client = account.client;
    if (client == null) {
      setState(() => _error = t.galtv.tuneFailed);
      return;
    }

    setState(() {
      _resolving = true;
      _error = null;
      _waitingForStart = false;
    });

    final tuner = GalTvTuner(client: client);
    try {
      final channels = await tuner.loadChannels();
      _channels = GalTvTuner.sortedByNumber(channels);
      final channel = GalTvTuner.pickInitialChannel(
        channels,
        SettingsService.instance.read(SettingsService.galtvLastChannelId),
      );
      if (channel == null) {
        if (mounted) setState(() => _error = t.galtv.nothingPlaying);
        return;
      }

      final result = await tuner.probe(channel, resolveLogoUrl: _resolveLogoUrl, hideFillers: _hideAds);
      _latchServerClock(result);
      final step = result?.current;
      if (step == null || !step.isPlayable) {
        // A gap with nothing playable *yet* — normal, not an error. Show what is
        // coming and wake when the server says this step runs out; see
        // [_waitingForStart] and [_armWaiting].
        if (!mounted) return;
        _lastChannel = channel;
        // The tab's guide highlights and autofocuses this channel, exactly as the
        // player's does for the picture on screen.
        _activeChannelId = channel.id;
        setState(() {
          _error = null;
          _waitingForStart = true;
          _upNext = null;
        });
        unawaited(_refreshUpNext(channel));
        _armWaiting(result?.next, waitFor: step?.waitFor);
        return;
      }

      _stopWaiting();
      if (!mounted) return;
      await SettingsService.instance.write(SettingsService.galtvLastChannelId, channel.id);
      if (!mounted) return;
      setState(() => _lastChannel = channel);
      await _launch(step.plan!, armedNext: result?.next, armedIn: step.duration);
    } catch (error) {
      if (mounted) setState(() => _error = t.galtv.tuneFailed);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _launch(GalTvTunePlan plan, {GalTvItemStep? armedNext, Duration? armedIn}) async {
    final plexClient = context.getPlexClientWithFallback(null);
    final item = await plexClient.fetchItem(plan.plexRatingKey);
    if (!mounted) return;
    if (item == null) {
      setState(() => _error = t.galtv.nothingPlaying);
      return;
    }

    _programmeEnded = false;
    _activeChannelId = plan.channel.id;
    _activeProgramId = plan.programId;
    // The gate authenticates every proxied path, so the logo requests need the
    // same Plex token the API calls carry — `Image.network` cannot inherit it
    // from the Tunarr client.
    final plexToken = await context.read<TunarrAccountProvider>().resolvePlexToken();
    if (!mounted) return;
    final args = GalTvSessionArgs(
      channelId: plan.channel.id,
      channelNumber: plan.channel.number,
      channelName: plan.channel.name,
      channelLogoUrl: plan.logoUrl,
      logoHeaders: plexToken == null || plexToken.isEmpty ? null : {'X-Plex-Token': plexToken},
      plexRatingKey: plan.plexRatingKey,
      programId: plan.programId,
      // A channel tuned mid-ad opens with an ad already playing, and the route is
      // opened from a plan only here — the player has no other way to learn it.
      isFiller: plan.isFiller,
      armedNext: armedNext,
      armedIn: armedIn,
      guideProvider: _loadGuideRows,
      nextProgrammeProvider: _nextProgramme,
      channelResolver: _resolveChannel,
      channelSurfer: _surfChannel,
      hasSiblingChannel: _hasSiblingChannel,
      onChannelChanged: _handleChannelChanged,
      onProgrammeEnded: () => _programmeEnded = true,
    );

    await navigateToVideoPlayer(
      context,
      metadata: item,
      initialPosition: plan.seekOffset,
      // Tunarr decides the position, not Plex's saved resume point.
      resolveWatchState: false,
      // No quality preset on purpose: inheriting the user's default keeps
      // Direct Play for a default install without permanently disabling the
      // legitimate transcode fallback. See client-integration.md §4.2.
      galTv: args,
    );

    if (!mounted) return;
    setState(() => _lastChannel = plan.channel);

    // The programme ended on its own: the schedule has moved on, so re-tune
    // instead of leaving a dead idle state.
    if (_programmeEnded) {
      _programmeEnded = false;
      if (mounted) unawaited(_tune());
      return;
    }

    // Backed out deliberately. The tab is a dead end at this point — an idle card
    // with a Watch button — so hand the viewer to Home instead of parking them
    // there. Re-opening the player behind their back would trap them in a pop/
    // re-push loop, which is what the idle state was for; Home is the escape.
    widget.onExitToHome?.call();
  }

  /// Fills the guide grid: one range call for every channel, already carrying the
  /// Plex id per cell (`client-integration.md` §4.1).
  ///
  /// Marks "now" from the player's *live* identity, not the launch plan, so a
  /// refetch after a channel switch highlights the new channel.
  Future<List<GalTvGuideRow>> _loadGuideRows() async {
    final client = context.read<TunarrAccountProvider>().client;
    if (client == null) return const [];

    final now = DateTime.now().toUtc();
    // A long runway: the guide renders only what fits the panel, so it needs
    // material to fill an ultrawide, not just a laptop window.
    final windowStart = now.subtract(const Duration(minutes: 30));
    final windowEnd = now.add(const Duration(hours: 12));
    final lineups = await client.fetchLineups(from: windowStart, to: windowEnd);
    // Which `Other Videos` programs each channel schedules *itself* — the half of
    // `galTvProgramIsFiller` a lineup alone cannot answer. Only channels whose
    // lineup carries such a program are asked, so a deployment of films and
    // episodes pays nothing for it.
    final ownOtherVideoIds = await GalTvTuner(client: client).ownOtherVideoIdsByChannel(lineups);
    return galTvGuideRows(
      channels: lineups,
      // The same bounds the fetch used: rows are clamped to them so every
      // channel shares one time origin (the guide's ruler depends on it).
      windowStart: windowStart,
      windowEnd: windowEnd,
      currentChannelId: _activeChannelId,
      currentProgramId: _activeProgramId,
      resolveLogoUrl: _resolveLogoUrl,
      ownOtherVideoIdsByChannel: ownOtherVideoIds,
    );
  }

  /// The player's slate asks for the tuned channel's next programme.
  Future<GalTvUpNext?> _nextProgramme() => _nextProgrammeFor(_activeChannelId);

  /// The next direct-playable programme on [channelId] — powers both the player's
  /// break slate and the tab's waiting card.
  ///
  /// Anchored on Tunarr's `serverTimeMs`, never the device clock: the rows carry
  /// server-authored slot times, so a TV whose clock is off would otherwise name
  /// the programme that is already airing. The clock is read from
  /// [_latchedServerNow], because the slate must **not** spend a
  /// `native-playback` read of its own — each such read records the filler it
  /// predicts for a future instant, which is precisely what keeps a break empty
  /// (see `GalTvTuneResult`).
  Future<GalTvUpNext?> _nextProgrammeFor(String? channelId) async {
    if (channelId == null) return null;

    var serverNow = _latchedServerNow();
    if (serverNow == null) {
      // Nothing has been read this session yet: learn the clock once. The tab
      // probes before it draws, so this is a first-frame path at most.
      final nowPlaying = await context.read<TunarrAccountProvider>().client?.fetchNowPlaying(channelId);
      if (nowPlaying == null) return null;
      _serverTimeMs = nowPlaying.serverTimeMs;
      _serverClockReadAt = DateTime.now();
      serverNow = _latchedServerNow();
      if (serverNow == null) return null;
    }

    return galTvUpNext(await _loadGuideRows(), channelId, serverNow);
  }

  /// Tunarr's clock now: the value latched at the last read plus locally measured
  /// elapsed time. Only the *difference* is local, so a device with a wrong clock
  /// cannot shift it.
  DateTime? _latchedServerNow() {
    final base = _serverTimeMs;
    final readAt = _serverClockReadAt;
    if (base == null || readAt == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      base + DateTime.now().difference(readAt).inMilliseconds,
      isUtc: true,
    );
  }

  void _latchServerClock(GalTvTuneResult? result) {
    if (result == null) return;
    _serverTimeMs = result.serverTimeMs;
    _serverClockReadAt = DateTime.now();
  }

  /// Hold the tab on [next] — the item the read that entered the waiting state
  /// already named — and wake when [waitFor] runs out.
  ///
  /// Deliberately one scheduled wake, not a poll: `native-playback` records the
  /// filler it predicts for a future instant, so a tab that re-reads every 10 s
  /// starves the very break it is waiting on (measured 2026-10-08 — a poll loop
  /// kept a 150 s break empty from end to end). The arm is played at the wake
  /// moment with no further read; a further read happens only when the arm is
  /// missing or is itself a wait.
  void _armWaiting(GalTvItemStep? next, {Duration? waitFor}) {
    _armedStep = next;
    _armedDueAt = DateTime.now().add(waitFor ?? const Duration(seconds: 30));
    _waitTimer?.cancel();
    _waitTimer = Timer(_waitDelay(waitFor), () => unawaited(_retryWaitingChannel()));
  }

  /// Take the armed step when it is still due now, dropping it otherwise — a
  /// stale arm would start the wrong item, and one read re-syncs instead.
  GalTvItemStep? _takeArmedStep() {
    final armed = _armedStep;
    final due = _armedDueAt;
    _armedStep = null;
    _armedDueAt = null;
    if (armed == null) return null;
    if (due != null && !galTvArmIsDue(due, DateTime.now())) return null;
    return armed;
  }

  /// How long to sleep before looking at the channel again: whatever the server
  /// said is left of the gap, clamped so a bogus value cannot park the tab and a
  /// zero-length gap cannot spin.
  Duration _waitDelay(Duration? wait) {
    const floor = Duration(seconds: 5);
    const ceiling = Duration(minutes: 5);
    final requested = (wait ?? const Duration(seconds: 30)) + const Duration(milliseconds: 500);
    if (requested < floor) return floor;
    if (requested > ceiling) return ceiling;
    return requested;
  }

  void _stopWaiting() {
    _waitTimer?.cancel();
    _waitTimer = null;
    _armedStep = null;
    _armedDueAt = null;
    _waitingForStart = false;
    _upNext = null;
  }

  /// Wake for the channel this tab is waiting on. Deliberately lighter than
  /// [_tune] — the channel is already known — and it must **not** touch
  /// [_resolving], or the waiting card would blink into a spinner at every wake.
  Future<void> _retryWaitingChannel() async {
    final channel = _lastChannel;
    final client = context.read<TunarrAccountProvider>().client;
    if (channel == null || client == null) return;

    // Play what the previous read already named for this instant: asking again
    // would record yet another prediction for an item nobody plays.
    final armed = _takeArmedStep();
    if (armed != null) {
      if (armed.isPlayable) {
        _stopWaiting();
        if (!mounted) return;
        await _launch(armed.plan!);
        return;
      }
      _armWaiting(null, waitFor: armed.waitFor);
      return;
    }

    GalTvTuneResult? result;
    try {
      result = await GalTvTuner(client: client).probe(channel, resolveLogoUrl: _resolveLogoUrl, hideFillers: _hideAds);
    } catch (_) {
      _armWaiting(null, waitFor: null); // one more try after the fallback delay
      return;
    }
    if (!mounted) return;
    _latchServerClock(result);

    final step = result?.current;
    if (step == null || !step.isPlayable) {
      unawaited(_refreshUpNext(channel)); // the schedule ticks over while we wait
      _armWaiting(result?.next, waitFor: step?.waitFor);
      return;
    }

    _stopWaiting();
    if (!mounted) return;
    await _launch(step.plan!, armedNext: result?.next, armedIn: step.duration);
  }

  /// Refresh the waiting card's "Up next" line. A missing label is not worth
  /// losing the wait over, and a payload picked for a channel the tab is no longer
  /// waiting on is dropped rather than shown under the wrong channel name.
  Future<void> _refreshUpNext(TunarrChannel channel) async {
    try {
      final upNext = await _nextProgrammeFor(channel.id);
      if (!mounted || !_waitingForStart) return;
      setState(() => _upNext = upNext != null && upNext.channelId != channel.id ? null : upNext);
    } catch (_) {
      // A break with no label is still a break.
    }
  }

  /// Open the tab's channel list — the **same** [GalTvGuideOverlay] the player
  /// shows, fed by the same range fetch. Without it the tab is a dead end during
  /// a break, because the guide is the only place a channel can be changed.
  Future<void> _openChannelGuide() async {
    setState(() => _guideOpen = true);
    await _loadRowsForGuide();
  }

  void _closeChannelGuide() {
    if (mounted) setState(() => _guideOpen = false);
  }

  Future<void> _loadRowsForGuide() async {
    if (_rowsLoading) return;
    setState(() {
      _rowsLoading = true;
      _rowsError = null;
    });
    try {
      // Channel logos are proxied by the gate, which authenticates images like
      // every other path, so the grid needs the same token the API calls use.
      final token = await context.read<TunarrAccountProvider>().resolvePlexToken();
      final rows = await _loadGuideRows();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        if (token != null && token.isNotEmpty) _logoHeaders = {'X-Plex-Token': token};
      });
    } catch (_) {
      if (mounted) setState(() => _rowsError = t.galtv.tuneFailed);
    } finally {
      if (mounted) setState(() => _rowsLoading = false);
    }
  }

  /// Tune the channel picked in the tab's guide: leave the wait and open the
  /// player, exactly as the player's own guide does.
  Future<void> _selectChannelFromGuide(String channelId) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final result = await _resolveChannel(channelId);
      if (!mounted) return;
      final step = result?.current;

      if (step == null || !step.isPlayable) {
        // The picked channel is in a break too: follow it and keep waiting.
        final channel = GalTvTuner.channelById(_channels, channelId);
        if (channel != null) {
          _activeChannelId = channel.id;
          _armedStep = null;
          setState(() {
            _lastChannel = channel;
            _upNext = null;
            _guideOpen = false;
          });
          unawaited(_refreshUpNext(channel));
        }
        return;
      }

      _stopWaiting();
      setState(() => _guideOpen = false);
      if (!mounted) return;
      await _launch(step.plan!, armedNext: result?.next, armedIn: step.duration);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// Turn a channel's Tunarr `icon.path` into a URL the client can load, against
  /// the gate the session was signed in to. Null when the tab is gone — this runs
  /// inside resolve closures that follow awaits, and a logo is never worth a
  /// crash on `context`.
  String? _resolveLogoUrl(String? iconPath) {
    if (!mounted) return null;
    return resolveTunarrIconUrl(iconPath, context.read<TunarrAccountProvider>().client?.http.baseUrl);
  }

  /// The **Hide ads** setting, read fresh at every probe so flipping it lands on
  /// the next boundary instead of being latched for the session.
  ///
  /// It is enforced in the tuner, not here: a filler becomes a *wait* of its own
  /// length, which is precisely the gap-hold this screen already knows how to
  /// sit through — so the slate stays up, no ad is played, and the programme
  /// after the break still starts at its scheduled second.
  bool get _hideAds => SettingsService.instance.read(SettingsService.galtvHideAds);

  /// Resolve a channel id from the guide into its current item sequence — the
  /// same read as entry, so a tap in the guide and a fresh tune behave alike.
  /// Reloads the channel list once when the id is not cached (a channel created
  /// in Tunarr after this tab opened).
  Future<GalTvTuneResult?> _resolveChannel(String channelId) async {
    final client = context.read<TunarrAccountProvider>().client;
    if (client == null) return null;
    final tuner = GalTvTuner(client: client);

    var channel = GalTvTuner.channelById(_channels, channelId);
    if (channel == null) {
      _channels = GalTvTuner.sortedByNumber(await tuner.loadChannels());
      channel = GalTvTuner.channelById(_channels, channelId);
    }
    if (channel == null) return null;
    final result = await tuner.probe(channel, resolveLogoUrl: _resolveLogoUrl, hideFillers: _hideAds);
    _latchServerClock(result);
    return result;
  }

  /// Resolve the neighbouring channel ([delta] ±1) for a D-pad surf.
  Future<GalTvTuneResult?> _surfChannel(int delta) async {
    final target = GalTvTuner.neighbour(_channels, _activeChannelId, delta);
    if (target == null) return null;
    return _resolveChannel(target.id);
  }

  /// Sync answer for the transport's next/previous affordances: whether a
  /// neighbour exists in [delta]'s direction.
  bool _hasSiblingChannel(int delta) => GalTvTuner.neighbour(_channels, _activeChannelId, delta) != null;

  /// The player switched (or followed) a channel: remember it for the next tab
  /// entry and move the guide's "now" marker onto the new channel. [programId] is
  /// null while the player is following a gap, which clears the marker instead of
  /// leaving it on the item the old channel was airing.
  void _handleChannelChanged(TunarrChannel channel, String? programId) {
    _activeChannelId = channel.id;
    _activeProgramId = programId;
    unawaited(SettingsService.instance.write(SettingsService.galtvLastChannelId, channel.id));
    if (mounted) setState(() => _lastChannel = channel);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final channel = _lastChannel;

    if (_resolving) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    if (_guideOpen) {
      final tuned = _lastChannel;
      return Scaffold(
        body: SafeArea(
          child: GalTvGuideOverlay(
            rows: _rows,
            isLoading: _rowsLoading,
            error: _rowsError,
            currentChannelId: _activeChannelId,
            channelLabel: tuned == null ? null : 'CH ${tuned.number} · ${tuned.name}',
            channelLogoUrl: tuned == null ? null : _resolveLogoUrl(tuned.iconPath),
            logoHeaders: _logoHeaders,
            client: context.getPlexClientWithFallback(null),
            isSwitching: _switching,
            onSelectChannel: _selectChannelFromGuide,
            onClose: _closeChannelGuide,
            onRetry: () => unawaited(_loadRowsForGuide()),
          ),
        ),
      );
    }

    if (_waitingForStart) {
      final upNext = _upNext;
      return Scaffold(
        body: SafeArea(
          child: upNext == null
              ? const Center(child: CircularProgressIndicator())
              : GalTvUpNextOverlay(
                  upNext: upNext,
                  channelLabel: channel == null ? null : 'CH ${channel.number} · ${channel.name}',
                  logoHeaders: _logoHeaders,
                  client: context.getPlexClientWithFallback(null),
                  onBrowseChannels: _openChannelGuide,
                ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: SafeArea(
          child: ErrorStateWidget(
            message: _error!,
            icon: Symbols.error_rounded,
            onRetry: _tune,
            actionAutofocus: true,
            actionUseBackgroundFocus: true,
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: EmptyStateWidget(
          icon: Symbols.tv_rounded,
          message: channel == null ? t.galtv.emptyTitle : 'CH ${channel.number} · ${channel.name}',
          subtitle: channel == null ? t.galtv.emptyBody : null,
          onAction: _tune,
          actionLabel: t.galtv.watch,
          actionIcon: Symbols.play_arrow_rounded,
        ),
      ),
    );
  }
}
