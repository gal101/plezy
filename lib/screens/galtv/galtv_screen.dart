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

      final plan = await tuner.planFor(channel, resolveLogoUrl: _resolveLogoUrl);
      if (plan == null) {
        if (mounted) {
          setState(() {
            _lastChannel = channel;
            _error = t.galtv.nothingPlaying;
          });
        }
        return;
      }

      if (!mounted) return;
      await SettingsService.instance.write(SettingsService.galtvLastChannelId, channel.id);
      if (!mounted) return;
      setState(() => _lastChannel = channel);
      await _launch(plan);
    } catch (error) {
      if (mounted) setState(() => _error = t.galtv.tuneFailed);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _launch(GalTvTunePlan plan) async {
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
      guideProvider: _loadGuideRows,
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
    return galTvGuideRows(
      channels: lineups,
      // The same bounds the fetch used: rows are clamped to them so every
      // channel shares one time origin (the guide's ruler depends on it).
      windowStart: windowStart,
      windowEnd: windowEnd,
      currentChannelId: _activeChannelId,
      currentProgramId: _activeProgramId,
      resolveLogoUrl: _resolveLogoUrl,
    );
  }

  /// Turn a channel's Tunarr `icon.path` into a URL the client can load, against
  /// the gate the session was signed in to. Null when the tab is gone — this runs
  /// inside resolve closures that follow awaits, and a logo is never worth a
  /// crash on `context`.
  String? _resolveLogoUrl(String? iconPath) {
    if (!mounted) return null;
    return resolveTunarrIconUrl(iconPath, context.read<TunarrAccountProvider>().client?.http.baseUrl);
  }

  /// Resolve a channel id from the guide into a launchable plan — the same
  /// resolve step as entry, so a tap in the guide and a fresh tune behave alike.
  /// Reloads the channel list once when the id is not cached (a channel created
  /// in Tunarr after this tab opened).
  Future<GalTvTunePlan?> _resolveChannel(String channelId) async {
    final client = context.read<TunarrAccountProvider>().client;
    if (client == null) return null;
    final tuner = GalTvTuner(client: client);

    var channel = GalTvTuner.channelById(_channels, channelId);
    if (channel == null) {
      _channels = GalTvTuner.sortedByNumber(await tuner.loadChannels());
      channel = GalTvTuner.channelById(_channels, channelId);
    }
    if (channel == null) return null;
    return tuner.planFor(channel, resolveLogoUrl: _resolveLogoUrl);
  }

  /// Resolve the neighbouring channel ([delta] ±1) for a D-pad surf.
  Future<GalTvTunePlan?> _surfChannel(int delta) async {
    final target = GalTvTuner.neighbour(_channels, _activeChannelId, delta);
    if (target == null) return null;
    return _resolveChannel(target.id);
  }

  /// Sync answer for the transport's next/previous affordances: whether a
  /// neighbour exists in [delta]'s direction.
  bool _hasSiblingChannel(int delta) => GalTvTuner.neighbour(_channels, _activeChannelId, delta) != null;

  /// The player switched channels: remember it for the next tab entry and move
  /// the guide's "now" marker onto the new channel/programme.
  void _handleChannelChanged(GalTvTunePlan plan) {
    _activeChannelId = plan.channel.id;
    _activeProgramId = plan.programId;
    unawaited(SettingsService.instance.write(SettingsService.galtvLastChannelId, plan.channel.id));
    if (mounted) setState(() => _lastChannel = plan.channel);
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
