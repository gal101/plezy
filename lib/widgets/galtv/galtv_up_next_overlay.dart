import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../utils/media_image_helper.dart';
import '../app_icon.dart';
import '../optimized_media_image.dart';
import '../video_controls/widgets/channel_logo.dart';

/// The "Up next" slate: what the player shows while the schedule has nothing
/// playable — a break whose filler lists had no clip that fit, or a break the
/// viewer asked to skip with **Hide ads** — and, since 2026-10-08, what a GalTV
/// viewer can raise over the **credits**, replacing a skip prompt that means
/// nothing on a live channel (see [onDismiss] for why only that one can be
/// closed).
///
/// Deliberately a *state of the player route*, not a separate screen. The route
/// stays mounted (the video surface is simply parked), so when the next
/// programme's plan arrives the player reloads in place and this layer
/// disappears — no navigation, and therefore no "start the player again"
/// problem.
///
/// It paints the programme it is about, not just its name: the film's own Plex
/// backdrop behind everything, the film's `clearLogo` wordmark (or its title
/// when Plex has none), `S01E01` plus the episode title for a TV show, the
/// synopsis, and the time it starts. The channel identity stays on it, because
/// the slate is the only thing on screen and a viewer who surfed here needs to
/// know where "here" is.
///
/// [upNext] must already be resolved (see `galTvUpNext`). Artwork and synopsis
/// come from [client] through the app's normal Plex image pipeline, resolved
/// once per payload and cached by [OptimizedMediaImage] itself.
class GalTvUpNextOverlay extends StatefulWidget {
  const GalTvUpNextOverlay({
    super.key,
    required this.upNext,
    this.channelLabel,
    this.channelLogoUrl,
    this.logoHeaders,
    this.onBrowseChannels,
    this.onChannelStep,
    this.onOpenGuide,
    this.onDismiss,
    this.client,
    this.mediaResolver,
    this.guideVisible,
  });

  final GalTvUpNext upNext;

  /// "CH 1 · Tom Cruise", when the session knows it.
  final String? channelLabel;

  final String? channelLogoUrl;

  /// The logo goes through the gate, which authenticates images too — see
  /// [ChannelLogo].
  final Map<String, String>? logoHeaders;

  /// Opens the channel list, when the host has one to open.
  ///
  /// Null in the player, which already has the guide as its own layer; the tab
  /// passes it so a viewer waiting on a break is not stuck on a card with no way
  /// to reach another channel until the next programme starts.
  final VoidCallback? onBrowseChannels;

  /// Steps the tuned channel by [delta] (−1 / +1).
  ///
  /// The remote's own CH+/CH− keys are handled as shortcuts and already work
  /// with the slate up, because key dispatch never goes through this layer. These
  /// buttons exist for the case those keys cannot cover: the player's chrome —
  /// including its TV Guide and channel buttons — is painted *underneath* this
  /// slate, so on a TV, where there is no `I` key to press, the on-screen
  /// affordances would otherwise be unreachable.
  final void Function(int delta)? onChannelStep;

  /// Opens the channel guide.
  final VoidCallback? onOpenGuide;

  /// Closes the slate, when closing it is a real choice.
  ///
  /// The host decides: a slate raised over the *credits* sits on top of something
  /// still playing, so the viewer can wave it away and go back to the film. A
  /// slate filling a *gap* is what the channel has instead of a picture, so its
  /// host passes nothing and no close button is drawn at all — there is nowhere
  /// to go back to.
  final VoidCallback? onDismiss;

  /// The Plex client the artwork and synopsis come from.
  ///
  /// Null is a supported state, not a bug: the slate then draws the plain title
  /// card it drew before there was any artwork. Nothing here reaches Tunarr — a
  /// slate must not spend a `native-playback` read (see [GalTvTuneResult]).
  final MediaServerClient? client;

  /// Test/preview seam: resolves the artwork payload for a rating key.
  ///
  /// Defaults to [client]'s `/library/metadata/{ratingKey}` fetch. Supplying it
  /// lets a widget test (or the settings preview screen) drive every artwork
  /// case — logo, no logo, no artwork at all — with no server and no network.
  final Future<GalTvUpNextMedia?> Function(String ratingKey)? mediaResolver;

  /// The GalTV guide layer's visibility, when this session has a guide.
  ///
  /// The guide draws *over* this slate and holds the ring while it is up. When it
  /// closes, the ring goes with it and this layer is left on screen with no focus
  /// at all — no arrows, nothing highlighted. Nothing else re-claims it: the
  /// slate only takes the ring on mount and when its payload changes, and picking
  /// the *same* channel in the guide never changes it.
  ///
  /// The owner's report, 2026-10-09: *"watching ad -> up next screen -> guide
  /// button -> select same channel -> guide closes -> still on Up Next screen, no
  /// more dpad, no more highlighted button"*.
  final ValueListenable<bool>? guideVisible;

  @override
  State<GalTvUpNextOverlay> createState() => _GalTvUpNextOverlayState();
}

class _GalTvUpNextOverlayState extends State<GalTvUpNextOverlay> {
  GalTvUpNextMedia? _media;

  /// The layer's own focus scope. **This is what keeps the D-pad on the slate.**
  ///
  /// Without it, directional traversal runs out of the action row and walks into
  /// the player chrome underneath — which is held visible for the slate's whole
  /// life — where left/right seek the picture. The owner, 2026-10-08: *"another
  /// left keypress … the highlight disappears instead of going to the next button
  /// to the left (ch -) it goes to the player behind and my left and right arrows
  /// start seeking. you need to fix upnext screen taking over control"*. Inside a
  /// scope the traversal simply finds no candidate and the ring stays put. The
  /// guide overlay has used exactly this since it was written.
  final FocusScopeNode _scopeFocusNode = FocusScopeNode(debugLabel: 'GalTvUpNext');

  /// One node per action, so an arrow press between siblings is real traversal and
  /// the ring can start on the *first* button rather than a hard-coded one.
  final FocusNode _prevChannelFocus = FocusNode(debugLabel: 'galtv-slate-prev-channel');
  final FocusNode _nextChannelFocus = FocusNode(debugLabel: 'galtv-slate-next-channel');
  final FocusNode _guideFocus = FocusNode(debugLabel: 'galtv-slate-guide');
  final FocusNode _browseFocus = FocusNode(debugLabel: 'galtv-slate-browse');

  bool _claimedFocus = false;

  /// The action the ring starts on: **TV Guide** when this slate has one.
  ///
  /// It is the one thing a viewer on a break cannot reach any other way on a TV,
  /// and the owner asked for it explicitly (2026-10-09: *"when opening the up next
  /// screen, automatically select the guide button first instead of the ch −"*).
  /// CH − is the fallback, then Browse, so a slate with no guide still opens with
  /// the ring somewhere real. Whatever it starts on, the scope below keeps the
  /// arrows inside the row.
  FocusNode? get _entryFocus => switch (widget) {
    GalTvUpNextOverlay(onOpenGuide: != null) => _guideFocus,
    GalTvUpNextOverlay(onChannelStep: != null) => _prevChannelFocus,
    GalTvUpNextOverlay(onBrowseChannels: != null) => _browseFocus,
    _ => null,
  };

  /// Arrows move the ring between this layer's own buttons instead of reaching the
  /// player underneath.
  ///
  /// The player binds left/right to *seek*, and that binding is an **ancestor** of
  /// this layer. Key events walk the focus chain outwards from whatever is focused,
  /// so a nearer binding wins — which is the whole fix. Without it the slate drew
  /// its buttons and left the arrows seeking the picture: the owner's report,
  /// 2026-10-08, *"pressing arrows on my keyboard seeks the credits +10 instead of
  /// navigating the up next buttons"*. Declaring them here makes the buttons
  /// reachable on every platform, whatever the "Video Player Navigation"
  /// preference says — on desktop that preference defaults to *off*, so relying on
  /// the app default would have left the arrows seeking forever.
  static const Map<ShortcutActivator, Intent> _slateShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(TraversalDirection.left),
    SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(TraversalDirection.right),
    SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
    SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
  };

  /// Whether the guide was up at the last reading of [GalTvUpNextOverlay.guideVisible].
  ///
  /// Only the up→down **edge** matters: that is the moment the guide hands the
  /// ring back, and it hands it to nobody in particular.
  bool _guideWasUp = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMedia());
    _claimFocus();
    _guideWasUp = widget.guideVisible?.value ?? false;
    widget.guideVisible?.addListener(_handleGuideVisibilityChanged);
  }

  /// The guide just closed over this slate: take the ring back.
  ///
  /// Without this the viewer is stranded — the guide's scope node held the ring
  /// and went away with it, the chrome underneath is held *visible* but is not
  /// focused, and nothing else re-claims: [_claimFocus] runs on mount and on a new
  /// payload, and picking the same channel in the guide changes no payload.
  void _handleGuideVisibilityChanged() {
    final guideUp = widget.guideVisible?.value ?? false;
    if (guideUp == _guideWasUp) return;
    _guideWasUp = guideUp;
    if (guideUp || !mounted) return;
    _claimedFocus = false;
    _claimFocus();
  }

  @override
  void dispose() {
    widget.guideVisible?.removeListener(_handleGuideVisibilityChanged);
    _scopeFocusNode.dispose();
    _prevChannelFocus.dispose();
    _nextChannelFocus.dispose();
    _guideFocus.dispose();
    _browseFocus.dispose();
    super.dispose();
  }

  /// Take the ring when the slate appears.
  ///
  /// Two attempts on consecutive frames, because the player can land its own focus
  /// request in the very frame this layer is first built (showing the chrome does
  /// exactly that) — and losing that race leaves the slate drawn but unreachable.
  /// Once the ring is ours it is never taken back: a viewer who moves off it stayed
  /// off it on purpose.
  void _claimFocus() {
    if (_claimedFocus) return;
    void attempt(int retriesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = _entryFocus;
        if (target == null) {
          _claimedFocus = true;
          return;
        }
        if (target.hasFocus) {
          _claimedFocus = true;
          return;
        }
        if (target.context == null) {
          if (retriesLeft > 0) attempt(retriesLeft - 1);
          return;
        }
        target.requestFocus();
        _claimedFocus = true;
      });
    }

    attempt(1);
  }

  @override
  void didUpdateWidget(covariant GalTvUpNextOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guideVisible != widget.guideVisible) {
      oldWidget.guideVisible?.removeListener(_handleGuideVisibilityChanged);
      _guideWasUp = widget.guideVisible?.value ?? false;
      widget.guideVisible?.addListener(_handleGuideVisibilityChanged);
    }
    final movedOn = oldWidget.upNext.ratingKey != widget.upNext.ratingKey ||
        oldWidget.upNext.channelId != widget.upNext.channelId;
    if (movedOn || oldWidget.mediaResolver != widget.mediaResolver || oldWidget.client != widget.client) {
      _media = null;
      if (movedOn) {
        // A new payload is a new slate: claim the ring again, since the viewer
        // has not seen these buttons before.
        _claimedFocus = false;
        _claimFocus();
      }
      unawaited(_loadMedia());
    }
  }

  Future<void> _loadMedia() async {
    final ratingKey = widget.upNext.ratingKey;
    final resolver = widget.mediaResolver ?? _resolveFromClient;
    if (ratingKey == null || ratingKey.isEmpty) return;

    GalTvUpNextMedia? media;
    try {
      media = await resolver(ratingKey);
    } catch (_) {
      // A slate is never worth failing over: no artwork simply means the plain
      // title card, which is the same thing every Other Videos item shows.
      media = null;
    }
    if (!mounted) return;
    setState(() => _media = media);
  }

  Future<GalTvUpNextMedia?> _resolveFromClient(String ratingKey) async {
    final client = widget.client;
    if (client == null) return null;
    final item = await client.fetchItem(ratingKey);
    if (item == null) return null;
    return GalTvUpNextMedia.fromItem(item);
  }

  /// The layer owns the arrow keys while it is up — see [_slateShortcuts] — and
  /// owns its own focus scope, so traversal cannot escape into the player
  /// chrome underneath.
  @override
  Widget build(BuildContext context) => FocusScope(
    node: _scopeFocusNode,
    child: Shortcuts(
      shortcuts: _slateShortcuts,
      child: FocusTraversalGroup(child: _buildSlate(context)),
    ),
  );

  Widget _buildSlate(BuildContext context) {
    final theme = Theme.of(context);
    final media = _media;
    final title = (media?.title ?? '').trim().isNotEmpty ? media!.title! : widget.upNext.title;
    final episodeLine = [media?.episodeLabel, media?.subtitle]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join('  ·  ');
    final meta = _metaLine(media);
    final summary = (media?.summary ?? '').trim();
    final startsAtLabel = t.galtv.startsAt(
      time: MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(widget.upNext.startsAt.toLocal()),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        _SlateBackdrop(client: widget.client, artPath: media?.artPath),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(56, 40, 56, 48),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_hasChannelIdentity) _channelRow(theme),
                      const SizedBox(height: 26),
                      Text(
                        t.galtv.upNext,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white60,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ClearLogoImage(
                        client: widget.client,
                        logoPath: media?.logoPath,
                        width: 420,
                        height: 96,
                        fallbackWidth:
                            ClearLogoImage.fallbackWidthFor(logoWidth: 420, available: constraints.maxWidth),
                        alignment: Alignment.centerLeft,
                        fadeInDuration: const Duration(milliseconds: 400),
                        fallbackBuilder: (context) => Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.displaySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            height: 1.05,
                          ),
                        ),
                      ),
                      if (episodeLine.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          episodeLine,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (meta != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          meta,
                          style: theme.textTheme.titleSmall?.copyWith(color: Colors.white60, letterSpacing: 0.6),
                        ),
                      ],
                      if (summary.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          summary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70, height: 1.35),
                        ),
                      ],
                      const SizedBox(height: 26),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _SpinningHourglass(),
                          const SizedBox(width: 14),
                          Text(
                            startsAtLabel,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      if (_hasActions) ...[
                        const SizedBox(height: 26),
                        FocusTraversalGroup(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              if (widget.onChannelStep != null) ...[
                                _SlateAction(
                                  icon: Symbols.keyboard_double_arrow_left_rounded,
                                  label: t.galtv.previousChannel,
                                  onPressed: () => widget.onChannelStep!(-1),
                                  focusNode: _prevChannelFocus,
                                  debugLabel: 'galtv-slate-prev-channel',
                                ),
                                _SlateAction(
                                  icon: Symbols.keyboard_double_arrow_right_rounded,
                                  label: t.galtv.nextChannel,
                                  onPressed: () => widget.onChannelStep!(1),
                                  focusNode: _nextChannelFocus,
                                  debugLabel: 'galtv-slate-next-channel',
                                ),
                              ],
                              if (widget.onOpenGuide != null)
                                _SlateAction(
                                  icon: Symbols.tv_rounded,
                                  label: t.galtv.guide,
                                  onPressed: widget.onOpenGuide!,
                                  focusNode: _guideFocus,
                                  debugLabel: 'galtv-slate-guide',
                                ),
                              if (widget.onBrowseChannels != null)
                                _SlateAction(
                                  icon: Symbols.grid_view_rounded,
                                  label: t.galtv.browseChannels,
                                  onPressed: widget.onBrowseChannels!,
                                  focusNode: _browseFocus,
                                  debugLabel: 'galtv-slate-browse',
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Deliberately outside the content column and outside the autofocus
        // order: the ring starts on an action, and the close button is one D-pad
        // step away for a viewer who only opened this to look.
        if (widget.onDismiss != null)
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: IconButton(
                  onPressed: widget.onDismiss,
                  tooltip: t.common.close,
                  icon: const AppIcon(Symbols.close_rounded, size: 30),
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool get _hasChannelIdentity =>
      (widget.channelLabel ?? '').isNotEmpty || (widget.channelLogoUrl ?? '').isNotEmpty;

  bool get _hasActions =>
      widget.onChannelStep != null || widget.onOpenGuide != null || widget.onBrowseChannels != null;

  Widget _channelRow(ThemeData theme) {
    final logoUrl = widget.channelLogoUrl;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if ((logoUrl ?? '').isNotEmpty) ...[
          ChannelLogo(url: logoUrl!, size: 34, headers: widget.logoHeaders),
          const SizedBox(width: 12),
        ],
        if ((widget.channelLabel ?? '').isNotEmpty)
          Text(
            widget.channelLabel!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
      ],
    );
  }

  /// "2008 · PG-13 · 1h 52m" — only the parts Plex actually gave us.
  static String? _metaLine(GalTvUpNextMedia? media) {
    if (media == null) return null;
    final parts = <String>[
      if (media.year != null) '${media.year}',
      if ((media.contentRating ?? '').isNotEmpty) media.contentRating!,
      if (media.duration != null && media.duration! > Duration.zero) _formatRuntime(media.duration!),
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  static String _formatRuntime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return hours > 0 ? '${hours}h ${minutes.toString().padLeft(2, '0')}m' : '${minutes}m';
  }
}

/// One affordance on the slate.
///
/// Outlined rather than filled so the row reads as secondary to the programme
/// artwork, and sized for a D-pad ring to sit on it comfortably from a sofa.
class _SlateAction extends StatelessWidget {
  const _SlateAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.debugLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// The action's own node, so an arrow press between siblings is ordinary
  /// traversal and the layer can start the ring on the leftmost one.
  final FocusNode? focusNode;

  /// Makes the ring's position legible to tests; never shown.
  final String? debugLabel;

  @override
  Widget build(BuildContext context) {
    // The ring has to be unmistakable: this layer draws over a picture that is
    // still playing, and its buttons sit on top of a backdrop whose brightness
    // the app does not control. A thin white hairline (the original styling) read
    // as "is anything selected?" — the owner asked for it to be obvious. The
    // focused button fills in white with black text, which no artwork can blend
    // away, plus a wider border for the shapes' edge.
    return OutlinedButton.icon(
      key: debugLabel == null ? null : ValueKey<String>(debugLabel!),
      focusNode: focusNode,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused) ? Colors.black : Colors.white,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused) ? Colors.white : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? const BorderSide(color: Colors.white, width: 3)
              : BorderSide(color: Colors.white.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}

/// The programme's backdrop, drifting slowly.
///
/// A still frame behind a two-minute slate reads as a hung app; a 7 % scale over
/// half a minute reads as television. The transform is the only thing animating
/// — the image itself is decoded once — so it costs a compositor pass, not a
/// repaint.
///
/// Honours [MediaQueryData.disableAnimations], the platform's own reduce-motion
/// switch (the same one `CyclingMediaBackdrop` reads): a viewer who asked for no
/// motion gets a still backdrop rather than an endless Ken Burns.
class _SlateBackdrop extends StatefulWidget {
  const _SlateBackdrop({this.client, this.artPath});

  final MediaServerClient? client;
  final String? artPath;

  @override
  State<_SlateBackdrop> createState() => _SlateBackdropState();
}

class _SlateBackdropState extends State<_SlateBackdrop> with SingleTickerProviderStateMixin {
  static const _drift = Duration(seconds: 26);

  late final AnimationController _controller = AnimationController(vsync: this, duration: _drift);
  late final Animation<double> _scale = Tween<double>(begin: 1, end: 1.07).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final art = widget.artPath;
    return ColoredBox(
      // The parked video surface is still behind this layer; black keeps the
      // slate from ever showing a stray frame of it.
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if ((art ?? '').isNotEmpty)
            AnimatedBuilder(
              animation: _scale,
              builder: (context, child) => Transform.scale(scale: _scale.value, child: child),
              child: OptimizedMediaImage(
                client: widget.client,
                imagePath: art,
                fit: BoxFit.cover,
                imageType: ImageType.art,
                placeholder: (context, _) => const SizedBox.shrink(),
                errorWidget: (context, _, _) => const SizedBox.shrink(),
              ),
            ),
          // Vertical scrim: dark at the top so a channel strip reads, near-solid
          // at the bottom where the text column sits.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x99000000), Color(0x66000000), Color(0xCC000000), Color(0xF2000000)],
                stops: [0, 0.32, 0.74, 1],
              ),
            ),
          ),
          // Horizontal wash so the same column keeps its contrast on a backdrop
          // that is bright exactly where the text is.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xD9000000), Color(0x73000000), Color(0x00000000)],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An hourglass that turns over on a loop, and whose sand runs out between
/// turns.
///
/// **Deliberately not a countdown.** The owner asked for the *motion* — an
/// object that flips, settles, and flips again — not for a number ticking down,
/// so the cycle is a fixed clock (one turn, then a five-second hold) and the
/// sand is driven by that cycle rather than by the schedule. Nothing here
/// encodes how long the break has left, which is why the slate prints only the
/// hour it starts at.
///
/// The rhythm is the point: a continuous spinner reads as "working", and a
/// still image reads as "stuck". Turn, hold, turn reads as a wait with an end.
///
/// Honours [MediaQueryData.disableAnimations]: a viewer who asked for no motion
/// gets a still glass.
class _SpinningHourglass extends StatefulWidget {
  const _SpinningHourglass();

  static const double size = 30;

  @override
  State<_SpinningHourglass> createState() => _SpinningHourglassState();
}

class _SpinningHourglassState extends State<_SpinningHourglass> with SingleTickerProviderStateMixin {
  /// One turn plus its hold. 0.9 s of movement, 5.1 s of stillness — the
  /// stillness is what makes the turn say something.
  static const _cycle = Duration(seconds: 6);
  static const _turnShare = 0.15;

  late final AnimationController _controller = AnimationController(vsync: this, duration: _cycle);
  late final Animation<double> _turns = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: Curves.easeInOutCubic)),
      weight: _turnShare * 100,
    ),
    // A constant 1.0 turn is the same angle as 0.0, so the loop restarts with no
    // visible snap — the glass simply holds until the next turn.
    TweenSequenceItem(tween: ConstantTween<double>(1), weight: (1 - _turnShare) * 100),
  ]).animate(_controller);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _SpinningHourglass.size,
      height: _SpinningHourglass.size * 1.3,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => RotationTransition(
          turns: _turns,
          // The sand is fullest at the moment of the turn — the glass has just
          // been righted — and empties across the hold.
          child: CustomPaint(painter: _HourglassPainter(fill: 1 - _controller.value)),
        ),
      ),
    );
  }
}

class _HourglassPainter extends CustomPainter {
  const _HourglassPainter({required this.fill});

  /// Sand left in the upper bulb: 1 right after a turn, 0 when it has run out.
  final double fill;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final midY = h / 2;
    final rim = w * 0.45;
    final neck = w * 0.13;
    const inset = 1.5;
    final shoulder = midY * 0.5;

    // Two mirrored bulbs with curved shoulders, so the glass reads as glass
    // rather than as a pair of triangles.
    final upper = Path()
      ..moveTo(cx - rim, inset)
      ..quadraticBezierTo(cx - rim, shoulder, cx - neck, midY - inset)
      ..lineTo(cx + neck, midY - inset)
      ..quadraticBezierTo(cx + rim, shoulder, cx + rim, inset)
      ..close();

    final lower = Path()
      ..moveTo(cx - neck, midY + inset)
      ..quadraticBezierTo(cx - rim, h - shoulder, cx - rim, h - inset)
      ..lineTo(cx + rim, h - inset)
      ..quadraticBezierTo(cx + rim, h - shoulder, cx + neck, midY + inset)
      ..close();

    final body = Paint()..color = Colors.white.withValues(alpha: 0.07);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.55);
    for (final path in [upper, lower]) {
      canvas.drawPath(path, body);
      canvas.drawPath(path, edge);
    }

    // End caps.
    final cap = Paint()
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.7);
    canvas.drawLine(Offset(cx - rim, inset), Offset(cx + rim, inset), cap);
    canvas.drawLine(Offset(cx - rim, h - inset), Offset(cx + rim, h - inset), cap);

    final sand = Paint()..color = Colors.white.withValues(alpha: 0.82);
    final lowerSurface = h - (h - midY) * (1 - fill);

    if (fill > 0) {
      canvas.save();
      canvas.clipPath(upper);
      // The upper sand rests on the neck and its surface falls as it drains.
      canvas.drawRect(Rect.fromLTRB(0, midY - (midY - inset) * fill, w, midY), sand);
      canvas.restore();
    }
    if (fill < 1) {
      canvas.save();
      canvas.clipPath(lower);
      canvas.drawRect(Rect.fromLTRB(0, lowerSurface, w, h), sand);
      canvas.restore();
    }
    if (fill > 0 && fill < 1) {
      canvas.drawRect(
        Rect.fromLTRB(cx - 0.9, midY, cx + 0.9, lowerSurface),
        Paint()..color = Colors.white.withValues(alpha: 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(_HourglassPainter oldDelegate) => oldDelegate.fill != fill;
}
