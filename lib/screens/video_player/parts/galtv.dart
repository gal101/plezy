part of '../../video_player_screen.dart';

/// End-of-item chaining. The channel is followed at **item** level: every read of
/// `native-playback` names both what is on now and what follows it, so the item
/// after this one is already known when the boundary arrives — it is played with
/// no further read. A `flex` gap is a wait of a published length, not a poll:
/// re-reading is what empties a break (see [GalTvTuneResult]).

/// Bounds on a single gap wait: never sleep less than this (a zero-length gap
/// would spin) and never more (a nonsense value must not park the route).
const Duration _galTvWaitFloor = Duration(seconds: 5);
const Duration _galTvWaitCeiling = Duration(minutes: 6);

/// How many gap waits one route may hold through before handing the session back
/// to the tab — a safety valve so a permanently dead channel cannot park the
/// player on a slate forever.
const int _galTvMaxWaits = 30;

/// How long to sleep before asking again when a read returned nothing usable.
const Duration _galTvReadRetryDelay = Duration(seconds: 30);

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
      final result = await resolver(channelId);
      if (!mounted || _shuttingDown) return;
      final plan = result?.current.plan;
      if (plan == null) {
        showErrorSnackBar(context, t.galtv.nothingPlaying);
        return;
      }

      await _applyGalTvPlan(plan);
      if (!mounted || _shuttingDown) return;
      // The same read named what follows: carry it so the boundary is free.
      _armGalTv(result!.next, result.current.duration);
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
  ///
  /// **A same-file seek is only valid while the player is still on the file.**
  /// Parked at its end (`state.completed`: the platforms report eof-reached,
  /// Android also flips `pause`, and mpv has dropped the item) a bare seek
  /// repositions nothing — and it still *looks* like it worked, because a seek
  /// writes its target optimistically — which leaves the viewer on a frozen
  /// picture that never plays. So [afterCompletion] reopens the item instead,
  /// and a plan that arrives while the player is parked does too.
  ///
  /// [afterCompletion] is set by the end-of-programme path, which must always
  /// leave the channel playing; Sync-to-live leaves it off so a seek cannot
  /// override a pause the viewer chose.
  Future<void> _applyGalTvPlan(GalTvTunePlan plan, {bool afterCompletion = false}) async {
    // The item now on screen decides whether the chrome offers the Up-Next slate —
    // see [_galTvItemIsFiller]. Set before any early return, so a same-file seek
    // onto a filler updates it too.
    _markGalTvItemFiller(plan.isFiller);
    final currentPlayer = player;
    final parkedAtEnd = currentPlayer?.state.completed ?? false;
    if (!afterCompletion && !parkedAtEnd && plan.plexRatingKey == _currentMetadata.id) {
      // Same file, still on the file: jump to the live offset, then re-mark the
      // grid's "now".
      await _seekPlayback(plan.seekOffset);
      if (!mounted || _shuttingDown) return;
      _adoptGalTvChannel(plan.channel, logoUrl: plan.logoUrl, programId: plan.programId);
      return;
    }

    if (afterCompletion && currentPlayer != null) {
      // The channel must keep playing, so mark the intent *before* the reopen: a
      // reload only auto-starts an item that was playing, and a parked player is
      // reported as not playing. This is also where a restriction refusing
      // playback (automotive) clears the intent instead.
      await _playWithPlaybackIntent(currentPlayer);
      if (!mounted || _shuttingDown) return;
    }

    // A different item is airing now — or this one had already ended — so open it
    // in place, one switch at a time.
    if (_shuttingDown || _galTvSwitching) return;
    _galTvSwitching = true;
    _setPlayerState(() {});
    try {
      await _openGalTvPlan(plan);
    } finally {
      if (mounted) _setPlayerState(() => _galTvSwitching = false);
    }
  }

  /// The item on screen ended: keep the channel playing, in place.
  ///
  /// Two sources, in order:
  ///
  /// 1. **The armed item** — the one the previous read of `native-playback` named
  ///    as following what was playing. It is played here without asking Tunarr
  ///    anything, which is the whole point: a read records the filler it predicts
  ///    for a future instant, and the picker's list cooldown reads that row, so
  ///    asking again is what leaves a break with nothing to play (see
  ///    [GalTvTuneResult]). This also makes the hand-over seamless — no slate, no
  ///    round trip.
  /// 2. **One fresh read**, when nothing is armed: it names both what is on now
  ///    and what follows it, so it arms the *next* boundary as it goes.
  ///
  /// A `flex` gap is then *waited out* — the slate is shown and the route resumes
  /// when the gap's own published clock runs out — and only the exhaustion of
  /// [_galTvMaxWaits] hands the session back to the tab.
  Future<void> _chainGalTvOnCompletion() async {
    final resolver = widget.galTv?.channelResolver;
    final channelId = _galTvChannelId;
    if (resolver == null || channelId == null) {
      await _exitGalTvToTab();
      return;
    }

    final generation = _galTvChainGeneration;
    final armed = _takeGalTvArm();
    if (armed != null) {
      await _advanceGalTv(armed);
      return;
    }

    final result = await _readGalTvState(resolver, channelId);
    if (!mounted || _shuttingDown || generation != _galTvChainGeneration) return;
    if (result != null) {
      await _advanceGalTv(result.current, after: result.next);
      return;
    }

    // The channel answered nothing at all. Hold the slate and look again on a
    // slow clock rather than dropping the viewer onto the tab's idle card.
    await _waitGalTvGap(GalTvItemStep.wait(_galTvReadRetryDelay), null, resolver: resolver, channelId: channelId);
  }

  /// Play [step], or wait it out showing the slate, carrying [after] as the item
  /// that will be due when [step] ends.
  Future<void> _advanceGalTv(GalTvItemStep step, {GalTvItemStep? after}) async {
    final plan = step.plan;
    if (plan == null) {
      await _waitGalTvGap(step, after);
      return;
    }
    _armGalTv(after, step.duration);
    await _applyGalTvPlan(plan, afterCompletion: true);
  }

  /// Hold the route through a gap and resume the moment the gap's own clock runs
  /// out, then continue with [after] — or with one fresh read when there is none.
  ///
  /// **Owned by the channel it started on.** A hold can last minutes, and a
  /// channel switch during it must retire it: the loop captures
  /// [_galTvChainGeneration] on entry and gives up the moment a switch or another
  /// adoption bumps it. Without that it kept its old channel's armed ad and its
  /// old slate — the owner's 2026-10-08 report: *"Switch back to channel 2 →
  /// UPNEXT screen stays on??? on top of channel 2?? … then suddenly an AD starts
  /// playing — so obviously somehow still thinks i am watching channel 3"*.
  ///
  /// A **wait, never a poll**. `native-playback` records the content-backed item
  /// it computes for `now + streamDuration + 1`, i.e. the filler it predicts will
  /// be playable at the end of the gap; the picker's per-list cooldown reads that
  /// very row, so re-asking inside a break pushes the list into cooldown and keeps
  /// the break empty. Measured 2026-10-08 on `TEST FILLERS`: two reads 8 s apart
  /// turned `flex 57 s → "Sucrets"` into `flex 148 s → "full"`, and a 6 s poll
  /// loop starved a 150 s break from end to end. So the length of the sleep comes
  /// from the server, and the item that plays at the end of it is the arm.
  Future<void> _waitGalTvGap(
    GalTvItemStep gap,
    GalTvItemStep? after, {
    Future<GalTvTuneResult?> Function(String channelId)? resolver,
    String? channelId,
  }) async {
    final galTv = widget.galTv;
    final resolve = resolver ?? galTv?.channelResolver;
    final channel = channelId ?? _galTvChannelId;
    if (galTv == null || resolve == null || channel == null) {
      await _exitGalTvToTab();
      return;
    }

    final generation = _galTvChainGeneration;
    var remaining = gap.duration;
    var armed = after;
    for (var wait = 0; wait < _galTvMaxWaits; wait++) {
      await _silenceGalTvGap();
      await _refreshGalTvUpNext();
      if (!mounted || _shuttingDown || _staleGalTvHold(generation)) return;
      await Future<void>.delayed(_galTvWaitDelay(remaining));
      if (!mounted || _shuttingDown || _galTvSwitching || _staleGalTvHold(generation)) return;

      final step = armed;
      armed = null;
      if (step != null) {
        galTv.upNext.value = null;
        await _advanceGalTv(step);
        return;
      }

      final result = await _readGalTvState(resolve, channel);
      if (!mounted || _shuttingDown || _staleGalTvHold(generation)) return;
      if (result == null) {
        remaining = _galTvReadRetryDelay; // nothing usable: look again, slowly
        continue;
      }
      if (result.current.isPlayable) {
        galTv.upNext.value = null;
        await _advanceGalTv(result.current, after: result.next);
        return;
      }

      // Still a gap — Tunarr shortened it to the moment the next item becomes
      // eligible — so sleep this one out too, carrying whatever it named.
      remaining = result.current.duration;
      armed = result.next;
    }

    await _exitGalTvToTab();
  }

  /// True when the channel this hold started on is no longer the one on screen —
  /// a switch or another adoption has bumped the chain. The hold must give up
  /// silently: whoever bumped it now owns the picture and the slate.
  bool _staleGalTvHold(int generation) => generation != _galTvChainGeneration;

  /// Silence the picture while a gap is held.
  ///
  /// A gap reached by *switching* leaves the previous channel's item loaded and
  /// still playing, so its audio runs on under the slate — the owner heard
  /// exactly that (2026-10-08: *"the media that was playing on the prev channel is
  /// still playing beneath, i can hear it"*). A gap reached by a programme
  /// *ending* needs nothing: that player is already parked at EOF.
  ///
  /// The play intent is deliberately left alone — the item that ends the gap
  /// reopens through [_applyGalTvPlan]'s `afterCompletion` path, which marks
  /// "should play" itself, so pausing here cannot leave the next item stopped.
  Future<void> _silenceGalTvGap() async {
    final currentPlayer = player;
    if (currentPlayer == null || !currentPlayer.state.playing) return;
    try {
      await currentPlayer.pause();
    } catch (error, stackTrace) {
      appLogger.w('GalTV gap pause failed', error: error, stackTrace: stackTrace);
    }
  }

  /// One read of the channel's item sequence. Failures are logged, never thrown:
  /// the caller's job is to keep the viewer somewhere sensible.
  Future<GalTvTuneResult?> _readGalTvState(
    Future<GalTvTuneResult?> Function(String channelId) resolver,
    String channelId,
  ) async {
    try {
      return await resolver(channelId);
    } catch (error, stackTrace) {
      appLogger.w('GalTV item-sequence read failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Remember the item that will be due when the item on screen ends, and when
  /// that is. [inDuration] is what the server said was left of the item on screen.
  void _armGalTv(GalTvItemStep? next, Duration inDuration) {
    _galTvArmed = next;
    _galTvArmedDueAt = next == null ? null : DateTime.now().add(inDuration);
  }

  void _clearGalTvArm() {
    _galTvArmed = null;
    _galTvArmedDueAt = null;
  }

  /// Take the armed item when it is due now, dropping it otherwise. A stale arm
  /// (the viewer paused, seeked, or left the route parked) would start the wrong
  /// thing late, so it is discarded and the caller reads the channel instead.
  /// The item that just finished is refused too — reopening it lands back on its
  /// end — which is [_isGalTvAtFinishedTail]'s job.
  GalTvItemStep? _takeGalTvArm() {
    final armed = _galTvArmed;
    final due = _galTvArmedDueAt;
    _clearGalTvArm();
    if (armed == null || due == null) return null;
    if (!galTvArmIsDue(due, DateTime.now())) return null;
    final plan = armed.plan;
    if (plan != null && _isGalTvAtFinishedTail(plan)) return null;
    return armed;
  }

  /// How long to sleep for a gap wait: the server's own figure, clamped so a
  /// zero-length gap cannot spin and a nonsense one cannot park the route.
  Duration _galTvWaitDelay(Duration requested) {
    if (requested < _galTvWaitFloor) return _galTvWaitFloor;
    if (requested > _galTvWaitCeiling) return _galTvWaitCeiling;
    return requested;
  }

  /// Refresh the slate's contents. A failure is logged and ignored — a gap with no
  /// title is still a gap, and the wait's own clock is what resumes play.
  ///
  /// A payload picked for another channel is **refused**, not displayed: the
  /// overlay draws the label from the channel on screen, so accepting one would
  /// print "CH 2 · UP NEXT <a channel 3 programme>" (owner report, 2026-10-08).
  Future<void> _refreshGalTvUpNext() async {
    final galTv = widget.galTv;
    final provider = galTv?.nextProgrammeProvider;
    if (galTv == null || provider == null) return;
    try {
      final upNext = await provider();
      if (!mounted || _shuttingDown) return;
      // A slate raised by the *gap* is what the channel is showing, not an offer:
      // it is never dismissible (see [_galTvUpNextDismissible]).
      _galTvUpNextDismissible = false;
      galTv.upNext.value = upNext != null && upNext.channelId != _galTvChannelId ? null : upNext;
    } catch (error, stackTrace) {
      appLogger.w('GalTV up-next lookup failed', error: error, stackTrace: stackTrace);
    }
  }

  /// Raise the slate: the viewer asked, so it is theirs to close.
  ///
  /// Two triggers share it — the credits marker's button, and a **filler** playing
  /// (an ad is a break, and "what is next" is what a break raises). Deliberately
  /// *not* automatic in either case: a slate appearing over the picture on its own
  /// would be a jump scare. Same provider the break slate uses, so the payload
  /// still carries the channel it was picked for and a stale one is refused.
  Future<void> _showGalTvUpNext() async {
    final galTv = widget.galTv;
    final provider = galTv?.nextProgrammeProvider;
    if (galTv == null || provider == null) return;

    GalTvUpNext? upNext;
    try {
      upNext = await provider();
    } catch (error, stackTrace) {
      appLogger.w('GalTV credits up-next lookup failed', error: error, stackTrace: stackTrace);
      return;
    }
    if (!mounted || _shuttingDown || upNext == null || upNext.channelId != _galTvChannelId) return;

    // The flag is read inside the same `ValueListenableBuilder` that the value
    // change rebuilds, so no `setState` is needed: one frame sees both.
    _galTvUpNextDismissible = true;
    galTv.upNext.value = upNext;
  }

  /// The slate's X: back to the credits. The button stays available for as long
  /// as the marker is on screen, so this is a "not now", not a "never".
  void _dismissGalTvUpNext() {
    _galTvUpNextDismissible = false;
    widget.galTv?.upNext.value = null;
  }

  /// True when [plan] would reopen the item that just finished, at its very end —
  /// the schedule still points at it, so there is nothing to play yet.
  bool _isGalTvAtFinishedTail(GalTvTunePlan plan) {
    if (plan.plexRatingKey != _currentMetadata.id) return false;
    final durationMs = _currentMetadata.durationMs;
    return durationMs != null && plan.seekOffset.inMilliseconds >= durationMs - 1000;
  }

  /// The pre-chaining behaviour, now only a last resort: tell the tab the
  /// programme ended and leave the route.
  Future<void> _exitGalTvToTab() async {
    final galTv = widget.galTv;
    if (galTv != null) galTv.upNext.value = null;
    galTv?.onProgrammeEnded?.call();
    await _handleBackButton();
  }

  /// The shared switch: resolve a channel's item sequence through the tab, fetch
  /// its Plex item, and swap it on the same player. The route never pops, so the
  /// picture cuts from one channel to the next like a real zap and the guide layer
  /// stays up across the swap.
  ///
  /// **A channel in a gap is followed, not refused.** Tapping a channel whose
  /// schedule is in a `flex` stretch used to answer "nothing is playing on that
  /// channel" and stay put, which left the viewer unable to reach that channel at
  /// all from the guide. Instead the identity moves there and the slate comes up
  /// while the gap runs out ([_waitGalTvGap]) — the same thing the tab does when it
  /// tunes into a break.
  ///
  /// Failures are surfaced rather than swallowed: a channel the tab cannot resolve
  /// at all still reads as a dead button.
  Future<void> _runGalTvSwitch(Future<GalTvTuneResult?> Function() resolve) async {
    if (_shuttingDown || _galTvSwitching) return;
    _galTvSwitching = true;
    // Retire any hold that is still counting down for the channel being left
    // *before* the resolve round trip: otherwise it can wake mid-switch and start
    // its own arm on the new channel (owner report, 2026-10-08). Its arm goes too —
    // it belongs to the old channel's schedule.
    _galTvChainGeneration++;
    _clearGalTvArm();
    _setPlayerState(() {});

    // A gap is held *after* the switch guard is released: the wait can last
    // minutes, and [_waitGalTvGap] bails out the moment another switch starts.
    GalTvItemStep? gap;
    GalTvItemStep? gapNext;
    try {
      final result = await resolve();
      if (!mounted || _shuttingDown) return;
      if (result == null) {
        showErrorSnackBar(context, t.galtv.nothingPlaying);
        return;
      }

      final step = result.current;
      if (!step.isPlayable) {
        // Adopt the channel *before* holding: the chrome, the guide's tuned row
        // and the slate's "Up next" all have to describe the channel being
        // followed, not the one being left.
        _adoptGalTvChannel(result.channel, logoUrl: result.logoUrl);
        gap = step;
        gapNext = result.next;
      } else {
        final opened = await _openGalTvPlan(step.plan!);
        if (!mounted || _shuttingDown || !opened) return;
        // The same read also named the item that follows this one, so the next
        // boundary needs no read at all (and a read is a write — see
        // [GalTvTuneResult]).
        _armGalTv(result.next, step.duration);
      }
    } catch (error, stackTrace) {
      if (!mounted) return;
      appLogger.w('GalTV channel switch failed', error: error, stackTrace: stackTrace);
      showErrorSnackBar(context, t.galtv.switchFailed);
      return;
    } finally {
      if (mounted) _setPlayerState(() => _galTvSwitching = false);
    }

    if (gap != null && mounted && !_shuttingDown) {
      await _waitGalTvGap(gap, gapNext);
    }
  }

  /// Record whether the item now on screen is a filler (an ad).
  ///
  /// Drives two things at once: the UP NEXT affordance in the chrome
  /// (`galTvOnFiller` → `_galTvFillerAffordance`) and the restricted
  /// ad-playback chrome. Every plan that reaches the player goes through this —
  /// a plan applied to the running file ([_applyGalTvPlan]) *and* one opened in
  /// place ([_openGalTvPlan], which a channel switch calls directly).
  void _markGalTvItemFiller(bool isFiller) {
    // Two jobs, because both follow from "this is the item on screen now".
    //
    // 1. The flag: whether the restricted ad chrome applies.
    // 2. **What the channel plays next**, refreshed on *every* item — not only on a
    //    filler. The miniature hint above UP NEXT is offered at two separate
    //    moments (the whole of a filler, and a **credits** marker), and the credits
    //    of a two-hour film appear minutes after this method last ran for it, so
    //    the answer has to be ready in advance. The chrome decides *whether* to
    //    show it; this only keeps the payload current.
    unawaited(_refreshGalTvNextHint());
    if (_galTvItemIsFiller == isFiller) return;
    _setPlayerState(() => _galTvItemIsFiller = isFiller);
  }

  /// Resolve the channel's next *programme* for the compact hint.
  ///
  /// Comes from the **lineup** through `nextProgrammeProvider`, never from the
  /// armed item: during a break `native-playback.next` is the next *ad*, and an
  /// ad is not an answer to "what is next". The lineup is also what makes a break
  /// transparent — a `flex` slot is not playable and a filler is skipped
  /// (`galTvUpNext`), so a channel that breaks for an hour still answers with the
  /// film *behind* the break, and its own start time an hour out.
  ///
  /// The tuned channel is captured **before** the await and the answer is refused
  /// unless it names that same channel: a payload resolved for the channel the
  /// viewer just left would otherwise appear under the new channel's label (the
  /// stale-attachment rule the slate and the guide rows both follow).
  Future<void> _refreshGalTvNextHint() async {
    final galTv = widget.galTv;
    final provider = galTv?.nextProgrammeProvider;
    if (galTv == null || provider == null) return;
    final channelId = _galTvChannelId;
    try {
      final upNext = await provider();
      if (!mounted || _shuttingDown) return;
      galTv.nextUp.value = upNext != null && upNext.channelId == channelId ? upNext : null;
    } catch (error, stackTrace) {
      appLogger.w('GalTV next-programme lookup failed', error: error, stackTrace: stackTrace);
      // A failed lookup must not leave a stale programme on screen either.
      if (mounted && !_shuttingDown && channelId == _galTvChannelId) galTv.nextUp.value = null;
    }
  }

  /// Open [plan] on the running player, in place. Returns false when nothing was
  /// opened — the reason is on screen already.
  ///
  /// **This is the one place every plan passes through, so it is where the
  /// filler flag is mirrored.** A channel switch ([_runGalTvSwitch]) calls this
  /// directly rather than through [_applyGalTvPlan], so the assignment used to
  /// live only in the latter: switching *into* a channel that was mid-ad left
  /// [_galTvItemIsFiller] holding the channel being left, and the UP NEXT button
  /// only appeared from the *next* item on — the owner's 2026-10-08 report.
  Future<bool> _openGalTvPlan(GalTvTunePlan plan) async {
    _markGalTvItemFiller(plan.isFiller);
    final plexClient = context.getPlexClientWithFallback(null);
    final item = await plexClient.fetchItem(plan.plexRatingKey);
    if (!mounted || _shuttingDown) return false;
    if (item == null) {
      showErrorSnackBar(context, t.galtv.nothingPlaying);
      return false;
    }

    final outcome = await _reloadMediaInPlace(
      metadata: item,
      // Tunarr's offset decides where to land, not Plex's saved resume point —
      // the same rule the initial tune follows.
      resumePosition: plan.seekOffset,
      reason: 'galtv channel switch',
    );
    if (!mounted || _shuttingDown) return false;
    if (outcome == MediaReloadOutcome.failed) return false; // _reloadMediaInPlace shows its own error
    _adoptGalTvChannel(plan.channel, logoUrl: plan.logoUrl, programId: plan.programId);
    return true;
  }

  /// Adopt a channel the session is now following: move the identity, tell the
  /// tab, and re-mark the grid's "now" without disturbing an open layer.
  ///
  /// [programId] is null when the channel is being followed through a gap rather
  /// than onto a playable item — the guide marks the *slot* as "now", and a gap
  /// has no item, so a null simply leaves that channel's cell unmarked.
  void _adoptGalTvChannel(TunarrChannel channel, {String? logoUrl, String? programId}) {
    // The picture now belongs to another channel: retire any hold that is still
    // running for the previous one and take its slate down. A slate left up here
    // is exactly the owner's *"UPNEXT screen stays on … on top of channel 2"*
    // (2026-10-08) — the gap hold that owns it refreshes it again the moment it
    // decides the new channel is in a gap.
    //
    // The *arm* is deliberately not touched: `_advanceGalTv` arms the next item
    // before applying the plan, so clearing it here would erase the very thing
    // that makes the next boundary free. Channel switches clear it themselves.
    _galTvChainGeneration++;
    _galTvUpNextDismissible = false;
    widget.galTv?.upNext.value = null;

    // A channel followed through a gap has no item on screen, so it cannot be an
    // ad: without this the flag would keep whatever the channel being *left* was
    // playing, and a switch away from an ad would leave the restricted ad chrome
    // (and the UP NEXT button) on the new channel's empty break.
    if (programId == null) _markGalTvItemFiller(false);

    // Tell the tab first: the transport's surf bounds and the grid's "now" both
    // come from the tab, so its state must be current before this screen
    // rebuilds and before the grid is refetched.
    widget.galTv?.onChannelChanged?.call(channel, programId);

    _setPlayerState(() {
      _galTvChannelId = channel.id;
      _galTvChannelNumber = channel.number;
      _galTvChannelName = channel.name;
      _galTvChannelLogoUrl = logoUrl;
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

  /// The break/credits slate paints *over* the player's chrome and carries its own
  /// buttons, so while it is up it owns the remote — exactly like the guide.
  ///
  /// The hold matters for the TV path specifically: with the chrome *hidden*, an
  /// arrow is the deliberate "seek without showing the controls" gesture, so the
  /// slate's buttons could never win the ring. Held, the chrome stays presented
  /// and the arrows traverse focus instead (owner report, 2026-10-08: *"up next
  /// screen appears, has an x, but doesnt take dpad/keyboard control. pressing
  /// arrows on my keyboard seeks the credits +10"*).
  void _handleGalTvUpNextChanged() {
    if (!mounted) return;
    if (widget.galTv?.upNext.value != null) {
      _chromeController.hold(PlayerChromeHold.slate);
    } else {
      _chromeController.release(PlayerChromeHold.slate);
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
