import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../models/tunarr/tunarr_channel.dart';
import '../../providers/tunarr_account_provider.dart';
import '../../services/galtv/galtv_tuner.dart';
import '../../services/settings_service.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/galtv/galtv_guide_overlay.dart';
import '../../widgets/galtv/galtv_up_next_overlay.dart';
import '../libraries/state_messages.dart';

/// The artwork shapes the "Up next" slate has to survive — the ones a real
/// break only produces by chance, which is the whole reason the owner asked for
/// this screen: waiting on a live channel to serve up an Other Videos filler is
/// not a way to check that the no-logo layout reads.
enum GalTvUpNextPreviewScenario { live, noLogo, noMedia, long }

/// A deliberately long, multi-sentence blurb for [GalTvUpNextPreviewScenario.long].
///
/// Three lines of real synopsis, not a repeated word, is the only way to see
/// where the slate's clamp actually cuts — and a real film's summary is never
/// the two sentences Plex happens to have on hand.
const String _longPreviewSummary =
    'After a decade in the shadows, a retired deep-cover operative is pulled back for one last job when a ghost '
    'from her past surfaces in Lisbon. What begins as a routine extraction unravels into a conspiracy reaching the '
    'highest floors of the agency she once served, forcing her to choose between the only family she has left and '
    'the truth she has spent her life burying. A slow-burn thriller about loyalty, memory and the price of coming '
    'in from the cold.';

/// The media payload a scenario forces, given what Plex really returned.
///
/// Pure and top-level so each artwork case can be unit-tested without a widget,
/// a provider tree, or a server: the preview screen and the overlay must agree
/// on what "the no-logo case" means, and a widget test is a poor place to
/// assert that.
GalTvUpNextMedia? previewMediaFor(GalTvUpNextPreviewScenario scenario, GalTvUpNextMedia? real) {
  switch (scenario) {
    case GalTvUpNextPreviewScenario.live:
      // The honest answer, artwork and all — whatever Plex has is what the
      // viewer would see.
      return real;
    case GalTvUpNextPreviewScenario.noLogo:
      // The Other Videos / filler case: a title, a blurb and metadata, but no
      // agent artwork at all. `withoutArtwork` keeps exactly the fields such an
      // item really has.
      return real?.withoutArtwork();
    case GalTvUpNextPreviewScenario.noMedia:
      // No Plex metadata whatsoever: the resolver is never called and the slate
      // falls back to the plain title card.
      return null;
    case GalTvUpNextPreviewScenario.long:
      // Artwork stays; only the blurb is stretched, so the clamp is exercised
      // against a real layout rather than a degenerate one.
      return (real ?? const GalTvUpNextMedia()).withSummary(_longPreviewSummary);
  }
}

/// Which of the empty conditions stopped the preview from drawing a slate.
///
/// Kept distinct so the empty state can name the real cause instead of a generic
/// "nothing to show" — this is a developer tool, and the difference between
/// "you are not signed in" and "this channel has no next programme" is the whole
/// diagnosis.
enum _PreviewEmpty { disconnected, noChannel, nothingScheduled }

/// A developer preview of the player's **Up next** break slate.
///
/// Renders the real [GalTvUpNextOverlay] — the same widget the player mounts —
/// over the tuned channel's genuine next programme, with a scenario switcher on
/// top so every artwork case (with artwork, without a logo, without any Plex
/// metadata, with an over-long synopsis) can be eyeballed on demand instead of
/// waiting for a live break to produce one.
///
/// The slate is full-bleed and the bar floats over it, so the preview occupies
/// the screen exactly the way the player's slate does; a bar that ate its own
/// height would hide the very layout being checked.
class GalTvUpNextPreviewScreen extends StatefulWidget {
  const GalTvUpNextPreviewScreen({super.key});

  @override
  State<GalTvUpNextPreviewScreen> createState() => _GalTvUpNextPreviewScreenState();
}

class _GalTvUpNextPreviewScreenState extends State<GalTvUpNextPreviewScreen> {
  bool _loading = true;
  _PreviewEmpty? _empty;

  GalTvUpNext? _upNext;
  String? _channelLabel;
  String? _channelLogoUrl;
  Map<String, String>? _logoHeaders;

  /// Channels and their guide rows, kept so stepping and the guide are instant:
  /// one lineup window covers every channel, so changing channel here needs no
  /// network at all — and this screen deliberately never spends the
  /// `native-playback` read the real player uses.
  List<TunarrChannel> _channels = const <TunarrChannel>[];
  List<GalTvGuideRow> _rows = const <GalTvGuideRow>[];
  String? _activeChannelId;
  String? _galtvBaseUrl;
  bool _guideVisible = false;

  MediaServerClient? _plex;

  GalTvUpNextPreviewScenario _scenario = GalTvUpNextPreviewScenario.live;

  /// The **real** Plex fetch per rating key, cached so flipping scenarios does
  /// not re-request the item the slate is already showing — the scenarios only
  /// reshape what came back, they are not different items.
  final _mediaCache = <String, GalTvUpNextMedia?>{};

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  /// Resolve everything once: the Tunarr client, the tuned channel, and that
  /// channel's next programme.
  ///
  /// The window and the comparison both use `DateTime.now().toUtc()`. That is
  /// *only* acceptable because this is a debug screen: the real player path
  /// latches Tunarr's clock from `native-playback.serverTimeMs`, and that read
  /// is a **write** — it records a play-history row for the filler it predicts,
  /// which is what starves a live break (see `GalTvTuneResult`). A preview must
  /// never spend one, so it uses the device clock and does not care that a
  /// skewed TV would pick a different programme.
  Future<void> _resolve() async {
    final account = context.read<TunarrAccountProvider>();
    final tunarr = account.client;
    if (tunarr == null) {
      if (mounted) setState(() { _loading = false; _empty = _PreviewEmpty.disconnected; });
      return;
    }

    // Plex artwork comes from the app's normal pipeline; a preview is still
    // worth drawing without it, so a missing Plex client is not fatal.
    MediaServerClient? plex;
    try {
      plex = context.getPlexClientWithFallback(null);
    } catch (_) {
      plex = null;
    }

    try {
      final channels = await GalTvTuner(client: tunarr).loadChannels();
      final remembered = SettingsService.instance.read(SettingsService.galtvLastChannelId);
      final channel = GalTvTuner.pickInitialChannel(channels, remembered);
      if (channel == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _empty = _PreviewEmpty.noChannel;
            _plex = plex;
          });
        }
        return;
      }

      // One window for every channel, so stepping and the guide need no further
      // reads.
      final nowUtc = DateTime.now().toUtc();
      final from = nowUtc.subtract(const Duration(minutes: 30));
      final to = nowUtc.add(const Duration(hours: 12));
      final lineups = await tunarr.fetchLineups(from: from, to: to);
      // The same provenance half of the filler rule the player and Home run, or a
      // channel whose programming *is* `Other Videos` clips would preview as
      // "nothing to name" while the live player names the next clip.
      final ownOtherVideoIds = await GalTvTuner(client: tunarr).ownOtherVideoIdsByChannel(lineups);
      final token = await account.resolvePlexToken();

      if (!mounted) return;
      setState(() {
        _loading = false;
        _plex = plex;
        _channels = GalTvTuner.sortedByNumber(channels);
        _rows = galTvGuideRows(
          channels: lineups,
          windowStart: from,
          windowEnd: to,
          ownOtherVideoIdsByChannel: ownOtherVideoIds,
        );
        _galtvBaseUrl = tunarr.http.baseUrl;
        if (token != null && token.isNotEmpty) _logoHeaders = {'X-Plex-Token': token};
        _applyChannel(channel, nowUtc);
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _empty = _PreviewEmpty.nothingScheduled; });
    }
  }

  void _selectScenario(GalTvUpNextPreviewScenario scenario) {
    if (scenario == _scenario) return;
    setState(() => _scenario = scenario);
  }

  /// Point the preview at [channel] using the rows already in hand.
  ///
  /// Deliberately does not call `setState`: every caller is already inside one, so
  /// the slate and the guide always move on the same frame.
  void _applyChannel(TunarrChannel channel, DateTime nowUtc) {
    _activeChannelId = channel.id;
    _upNext = galTvUpNext(_rows, channel.id, nowUtc);
    _empty = _upNext == null ? _PreviewEmpty.nothingScheduled : null;
    _channelLabel = 'CH ${channel.number} · ${channel.name}';
    _channelLogoUrl = resolveTunarrIconUrl(channel.iconPath, _galtvBaseUrl);
  }

  /// Step the channel exactly as the player's CH−/CH+ do — surf order, clamped at
  /// both ends, never wrapping — so the slate can be checked across a few channels
  /// in a row without leaving the preview.
  void _stepChannel(int delta) {
    final target = GalTvTuner.neighbour(_channels, _activeChannelId, delta);
    if (target == null) return;
    setState(() => _applyChannel(target, DateTime.now().toUtc()));
  }

  void _selectChannelFromGuide(String channelId) {
    final target = GalTvTuner.channelById(_channels, channelId);
    setState(() {
      if (target != null) _applyChannel(target, DateTime.now().toUtc());
      _guideVisible = false;
    });
  }

  void _openGuide() => setState(() => _guideVisible = true);
  void _closeGuide() => setState(() => _guideVisible = false);

  /// The overlay's test seam: fetch the real item once, then let the scenario
  /// reshape it.
  Future<GalTvUpNextMedia?> _resolveMedia(String ratingKey) async {
    final real = await _fetchReal(ratingKey);
    return previewMediaFor(_scenario, real);
  }

  Future<GalTvUpNextMedia?> _fetchReal(String ratingKey) async {
    if (_mediaCache.containsKey(ratingKey)) return _mediaCache[ratingKey];
    final client = _plex;
    if (client == null) return null;
    final item = await client.fetchItem(ratingKey);
    final media = item == null ? null : GalTvUpNextMedia.fromItem(item);
    _mediaCache[ratingKey] = media;
    return media;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildSlate(context)),
          Positioned(top: 0, left: 0, right: 0, child: _buildBar(context)),
          // Above the bar, exactly as in the player: the guide owns the screen
          // while it is open.
          if (_guideVisible) Positioned.fill(child: _buildGuide(context)),
        ],
      ),
    );
  }

  Widget _buildSlate(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final empty = _empty;
    if (empty != null) {
      return Center(child: _buildEmpty(context, empty));
    }

    // `noMedia` passes no client and no resolver at all, so nothing is fetched
    // and the slate draws the plain title card — the exact path a Plex-less
    // setup takes.
    final noMedia = _scenario == GalTvUpNextPreviewScenario.noMedia;

    return GalTvUpNextOverlay(
      // A fresh state per scenario: the overlay resolves its artwork once, so
      // reusing the state would leave the previous scenario's payload on screen.
      key: ValueKey(_scenario),
      upNext: _upNext!,
      channelLabel: _channelLabel,
      channelLogoUrl: _channelLogoUrl,
      logoHeaders: _logoHeaders,
      // Player parity: the player has no channel list to open, so neither does
      // its preview — it carries the player's channel and guide affordances
      // instead, so the row can be judged here.
      onBrowseChannels: null,
      onChannelStep: _stepChannel,
      onOpenGuide: _openGuide,
      client: noMedia ? null : _plex,
      mediaResolver: noMedia ? null : _resolveMedia,
    );
  }

  /// The real guide, mounted over the real slate — the pairing the player
  /// produces, and the reason this screen exists: the layout *in between* the two
  /// is otherwise only visible on a live break.
  Widget _buildGuide(BuildContext context) {
    return GalTvGuideOverlay(
      rows: _rows,
      isLoading: false,
      error: null,
      currentChannelId: _activeChannelId,
      channelLabel: _channelLabel,
      channelLogoUrl: _channelLogoUrl,
      logoHeaders: _logoHeaders,
      client: _plex,
      isSwitching: false,
      onSelectChannel: _selectChannelFromGuide,
      onClose: _closeGuide,
      // The preview's rows are fetched once, so a retry is simply the whole
      // resolve again — the same thing entering the screen does.
      onRetry: () => unawaited(_resolve()),
    );
  }

  Widget _buildEmpty(BuildContext context, _PreviewEmpty empty) {
    final t = Translations.of(context);
    switch (empty) {
      case _PreviewEmpty.disconnected:
        return EmptyStateWidget(icon: Symbols.tv_off_rounded, message: t.services.notConnected);
      case _PreviewEmpty.noChannel:
        return EmptyStateWidget(
          icon: Symbols.tv_rounded,
          message: t.galtv.emptyTitle,
          subtitle: t.galtv.emptyBody,
        );
      case _PreviewEmpty.nothingScheduled:
        return EmptyStateWidget(icon: Symbols.schedule_rounded, message: t.galtv.nothingPlaying);
    }
  }

  Widget _buildBar(BuildContext context) {
    final t = Translations.of(context);
    final theme = Theme.of(context);
    final labels = <GalTvUpNextPreviewScenario, String>{
      GalTvUpNextPreviewScenario.live: t.galtv.preview.live,
      GalTvUpNextPreviewScenario.noLogo: t.galtv.preview.noLogo,
      GalTvUpNextPreviewScenario.noMedia: t.galtv.preview.noMedia,
      GalTvUpNextPreviewScenario.long: t.galtv.preview.long,
    };

    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const AppIcon(Symbols.arrow_back_rounded),
                    color: Colors.white,
                    tooltip: t.common.back,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    t.galtv.preview.title,
                    style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in labels.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: entry.key == _scenario,
                            onSelected: (_) => _selectScenario(entry.key),
                            // Chips are focusable by default, so the row is
                            // D-pad navigable without extra plumbing; the
                            // selected one takes focus on entry.
                            autofocus: entry.key == _scenario,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  t.galtv.preview.intro,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
