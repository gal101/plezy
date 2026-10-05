part of '../../video_player_screen.dart';

/// End-of-programme chaining: how many times to re-resolve when the schedule is
/// momentarily unplayable at the boundary (a `flex` break, a mid-transition
/// read), and the base delay between attempts — multiplied by the attempt
/// number, so the retries back off (2 s, 4 s, 6 s, ~12 s total before the player
/// hands back to the tab).
const int _galTvChainAttempts = 3;
const Duration _galTvChainRetryDelay = Duration(seconds: 2);

/// The player's GalTV layer: fetch/cache/retry for the in-player guide, plus
/// the toggle the controls' TV Guide button writes.
///
/// The rows come from [GalTvSessionArgs.guideProvider], injected by the GalTV
/// tab, so the player never talks to Tunarr directly and
/// [GalTvGuideOverlay] stays a pure widget. The list is fetched once when the
/// layer is first shown and cached for the route's lifetime; Retry drops the
/// cache and refetches. See `plezy-tunarr/client-integration.md` §3.2.
extension _VideoPlayerGalTvMethods on VideoPlayerScreenState {
  /// Flips the guide layer. The controls' TV Guide button calls this; the
  /// screen's listener on `guideVisible` handles the fetch.
  void _toggleGalTvGuide() {
    final galTv = widget.galTv;
    if (galTv == null || !galTv.hasGuide) return;
    galTv.guideVisible.value = !galTv.guideVisible.value;
  }

  void _closeGalTvGuide() => widget.galTv?.guideVisible.value = false;

  /// Close the guide if it is up, reporting whether it was. Back uses this so the
  /// layer eats the press instead of the route teardown behind it.
  bool _closeGalTvGuideIfVisible() {
    if (!(widget.galTv?.guideVisible.value ?? false)) return false;
    _closeGalTvGuide();
    return true;
  }

  /// Tune the channel a viewer picked in the guide (a row tap).
  Future<void> _tuneGalTvChannel(String channelId) async {
    final resolver = widget.galTv?.channelResolver;
    if (resolver == null || channelId == _galTvChannelId) return;
    await _runGalTvSwitch(() => resolver(channelId));
  }

  /// Surf one channel in [delta]'s direction (D-pad next/previous, transport
  /// buttons, media session).
  Future<void> _surfGalTvChannel(int delta) async {
    final surfer = widget.galTv?.channelSurfer;
    if (surfer == null) return;
    await _runGalTvSwitch(() => surfer(delta));
  }

  /// Snap the player back onto the tuned channel's live offset ("sync to live")
  /// after the viewer has seeked away from it.
  ///
  /// Resolves what is airing on the channel *now* and applies it — see
  /// [_applyGalTvPlan] for the seek-or-reload decision.
  Future<void> _resyncGalTv() async {
    final resolver = widget.galTv?.channelResolver;
    final channelId = _galTvChannelId;
    if (resolver == null || channelId == null || _galTvSwitching || _shuttingDown) return;

    try {
      final plan = await resolver(channelId);
      if (!mounted || _shuttingDown) return;
      if (plan == null) {
        showErrorSnackBar(context, t.galtv.nothingPlaying);
        return;
      }

      await _applyGalTvPlan(plan);
    } catch (error, stackTrace) {
      if (!mounted) return;
      appLogger.w('GalTV resync failed', error: error, stackTrace: stackTrace);
      showErrorSnackBar(context, t.galtv.switchFailed);
    }
  }

  /// Apply an already-resolved plan to the running player.
  ///
  /// Branches on the underlying file: a break/continuation segment of the same
  /// Plex item — the schedule splits one movie into several slots with
  /// increasing `seekOffsetMs` — is handled with a plain seek to the schedule's
  /// offset, while a genuinely new programme is reloaded in place with the same
  /// swap channel surfing uses. Shared by Sync-to-live and end-of-programme
  /// chaining, which differ only in how they obtain the plan.
  Future<void> _applyGalTvPlan(GalTvTunePlan plan) async {
    if (plan.plexRatingKey == _currentMetadata.id) {
      // Same file: jump to the live offset, then re-mark the grid's "now".
      await _seekPlayback(plan.seekOffset);
      if (!mounted || _shuttingDown) return;
      _adoptGalTvChannel(plan);
      return;
    }

    // A different item is airing now — reuse the in-place switch path.
    await _runGalTvSwitch(() async => plan);
  }

  /// The programme ended: keep the channel playing, in place.
  ///
  /// Applies the same plan Sync-to-live does, but **without leaving the route**.
  /// Exiting on completion is what dropped the viewer onto the tab's idle card:
  /// a programme boundary can land on a `flex` break or catch Tunarr
  /// mid-transition, and the tab's re-tune then resolved nothing to play. A null
  /// plan is therefore retried a few times, and only when the retries are
  /// exhausted does the session hand back to the tab (the pre-chaining
  /// behaviour), so a channel with a long dead gap cannot park on a finished
  /// file forever.
  Future<void> _chainGalTvOnCompletion() async {
    final resolver = widget.galTv?.channelResolver;
    final channelId = _galTvChannelId;
    if (resolver == null || channelId == null) {
      widget.galTv?.onProgrammeEnded?.call();
      await _handleBackButton();
      return;
    }

    for (var attempt = 0; attempt < _galTvChainAttempts; attempt++) {
      // Always wait before the first resolve: at the instant of EOF the schedule
      // usually still reports the item that just finished, and seeking to *its*
      // offset would land back on the end — an EOF loop. Backing off also covers
      // a boundary that lands on a `flex` break.
      await Future<void>.delayed(_galTvChainRetryDelay * (attempt + 1));
      if (!mounted || _shuttingDown || _galTvSwitching) return;

      GalTvTunePlan? plan;
      try {
        plan = await resolver(channelId);
      } catch (error, stackTrace) {
        appLogger.w('GalTV chaining resolve failed', error: error, stackTrace: stackTrace);
      }
      if (!mounted || _shuttingDown) return;
      if (plan == null) continue; // a break, or the schedule mid-transition

      if (plan.plexRatingKey == _currentMetadata.id) {
        // Same file. If the schedule still points at the tail of the item we just
        // finished, there is nothing to play yet — wait for it to tick over
        // rather than seeking straight back into EOF.
        final durationMs = _currentMetadata.durationMs;
        if (durationMs != null && plan.seekOffset.inMilliseconds >= durationMs - 1000) continue;
      }

      await _applyGalTvPlan(plan);
      return;
    }

    // Nothing playable after the retries: hand back to the tab rather than
    // parking on a finished file.
    widget.galTv?.onProgrammeEnded?.call();
    await _handleBackButton();
  }

  /// The shared switch: resolve the target through the tab, fetch its Plex item,
  /// and swap it on the same player. The route never pops, so the picture cuts
  /// from one programme to the next like a real zap and the guide layer stays up
  /// across the swap.
  ///
  /// Failures are surfaced rather than swallowed: a channel with nothing playable
  /// would otherwise read as a dead button.
  Future<void> _runGalTvSwitch(Future<GalTvTunePlan?> Function() resolve) async {
    if (_shuttingDown || _galTvSwitching) return;
    _galTvSwitching = true;
    _setPlayerState(() {});
    try {
      final plan = await resolve();
      if (!mounted || _shuttingDown) return;
      if (plan == null) {
        showErrorSnackBar(context, t.galtv.nothingPlaying);
        return;
      }

      final plexClient = context.getPlexClientWithFallback(null);
      final item = await plexClient.fetchItem(plan.plexRatingKey);
      if (!mounted || _shuttingDown) return;
      if (item == null) {
        showErrorSnackBar(context, t.galtv.nothingPlaying);
        return;
      }

      final outcome = await _reloadMediaInPlace(
        metadata: item,
        // Tunarr's offset decides where to land, not Plex's saved resume point —
        // the same rule the initial tune follows.
        resumePosition: plan.seekOffset,
        reason: 'galtv channel switch',
      );
      if (!mounted || _shuttingDown) return;
      if (outcome == MediaReloadOutcome.failed) return; // _reloadMediaInPlace shows its own error
      _adoptGalTvChannel(plan);
    } catch (error, stackTrace) {
      if (!mounted) return;
      appLogger.w('GalTV channel switch failed', error: error, stackTrace: stackTrace);
      showErrorSnackBar(context, t.galtv.switchFailed);
    } finally {
      if (mounted) _setPlayerState(() => _galTvSwitching = false);
    }
  }

  /// Adopt a switch that opened successfully: move the identity, tell the tab, and
  /// re-mark the grid's "now" without disturbing an open layer.
  void _adoptGalTvChannel(GalTvTunePlan plan) {
    // Tell the tab first: the transport's surf bounds and the grid's "now" both
    // come from the tab, so its state must be current before this screen
    // rebuilds and before the grid is refetched.
    widget.galTv?.onChannelChanged?.call(plan);

    _setPlayerState(() {
      _galTvChannelId = plan.channel.id;
      _galTvChannelNumber = plan.channel.number;
      _galTvChannelName = plan.channel.name;
      _galTvChannelLogoUrl = plan.logoUrl;
    });

    if (widget.galTv?.guideVisible.value ?? false) {
      // Refetch in place: the current grid keeps painting until the new rows
      // land, so a zap never flashes a spinner.
      unawaited(_loadGalTvGuideRows());
    } else {
      // Force a fresh fetch on the next open — the cached rows still mark the
      // channel we just left as "now".
      _galTvGuideRows = null;
    }
  }

  /// The layer's side effects: the first show starts the fetch, and the layer
  /// holds the chrome so it cannot auto-hide underneath. Visibility itself is
  /// rendered by the overlay's own `ValueListenableBuilder`, so no screen
  /// rebuild is needed here.
  void _handleGalTvGuideVisibilityChanged() {
    if (!mounted) return;
    if (widget.galTv?.guideVisible.value ?? false) {
      _chromeController.hold(PlayerChromeHold.guide);
      if (_galTvGuideRows == null && !_galTvGuideLoading) {
        unawaited(_loadGalTvGuideRows());
      }
    } else {
      // Release restarts auto-hide; the chrome resumes its normal lifecycle.
      _chromeController.release(PlayerChromeHold.guide);
    }
  }

  void _retryGalTvGuide() {
    _galTvGuideRows = null;
    _galTvGuideError = null;
    unawaited(_loadGalTvGuideRows());
  }

  Future<void> _loadGalTvGuideRows() async {
    final provider = widget.galTv?.guideProvider;
    if (provider == null) return;
    // A switch that lands while a fetch is in flight must supersede it rather
    // than be dropped: the in-flight rows still mark the channel we just left as
    // "now", so dropping the refetch would leave the grid stale.
    final generation = ++_galTvGuideFetchGeneration;
    _galTvGuideLoading = true;
    _galTvGuideError = null;
    _setPlayerState(() {});
    try {
      final rows = await provider();
      if (!mounted || generation != _galTvGuideFetchGeneration) return;
      _galTvGuideRows = rows;
    } catch (error, stackTrace) {
      if (!mounted || generation != _galTvGuideFetchGeneration) return;
      appLogger.w('GalTV guide load failed', error: error, stackTrace: stackTrace);
      _galTvGuideError = t.liveTv.guideReloadFailed;
    } finally {
      if (mounted && generation == _galTvGuideFetchGeneration) {
        _galTvGuideLoading = false;
        _setPlayerState(() {});
      }
    }
  }
}
