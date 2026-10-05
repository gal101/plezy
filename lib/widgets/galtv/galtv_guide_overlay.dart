import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/media_image_helper.dart';
import '../optimized_media_image.dart';
import '../video_controls/widgets/channel_logo.dart';

/// Programme cell metrics. Cells are sized by *duration*, not evenly: a
/// 10-minute break must not look like a two-hour feature, and the width is the
/// only clock the grid has. There is deliberately **no maximum width** — a cap
/// would break the grid's proportionality and leave a dead band at the right of
/// the row.
const double _minEntryWidth = 96;

/// The time scale. The overlay solves for the scale that makes the fetched
/// window fill the panel exactly, so a wide screen shows more hours rather than
/// bigger boxes. Clamped so cells stay readable on a narrow window; when even
/// the floor overflows, the row scrolls and the fade marks it.
const double _minPixelsPerMinute = 3.4;
const double _maxPixelsPerMinute = 9.0;

/// Fixed channel-name column; the programme strips share the rest of the panel.
const double _channelColumnWidth = 164.0;

/// The channel logo, stacked above the channel name.
const double _logoSize = 44.0;

/// The horizontal insets between the panel edge and the cells. Kept here so the
/// fitted time scale ([_buildBody]) and the widgets that apply them cannot drift
/// apart — the first fit ignored them and clipped the last cell by 4 px.
const double _rowsListPadding = 8;
const double _rowBorderWidth = 2;
const double _stripPadding = 6;
const double _cellGap = 6;

/// Everything between the panel edge and the cells: the rows list's padding, the
/// row's border, and the strip's own padding — on both sides.
const double _horizontalInset = 2 * (_rowsListPadding + _rowBorderWidth + _stripPadding);

/// Laid-out width of [entry]'s cell at [pixelsPerMinute]. Shared with the row,
/// which sums it to decide whether its strip actually overflows.
double _entryWidthFor(GalTvGuideEntry entry, double pixelsPerMinute) =>
    (entry.duration.inSeconds / 60 * pixelsPerMinute).clamp(_minEntryWidth, double.infinity);

/// The width a row's *cells and gaps* occupy at [pixelsPerMinute]. The strip's
/// own padding is left out on purpose: [_horizontalInset] already accounts for
/// it, and counting it twice left the last cell 12 px short of the panel edge.
double _rowWidthAt(GalTvGuideRow row, double pixelsPerMinute) {
  var width = 0.0;
  for (var i = 0; i < row.entries.length; i++) {
    width += _entryWidthFor(row.entries[i], pixelsPerMinute);
    if (i != row.entries.length - 1) width += _cellGap;
  }
  return width;
}

/// Solve for the time scale that makes the widest row fill [budget] exactly.
///
/// `_rowWidthAt` rises monotonically with the scale, so a bisection converges on
/// the fill point. Clamped at both ends: below the floor the guide would become
/// unreadable (so it scrolls instead), above the ceiling the fetched window is
/// simply too short to fill the panel (so a dead band is unavoidable).
double _fitPixelsPerMinute(List<GalTvGuideRow> rows, double budget) {
  double widestAt(double scale) {
    var widest = 0.0;
    for (final row in rows) {
      if (row.entries.isEmpty) continue;
      final width = _rowWidthAt(row, scale);
      if (width > widest) widest = width;
    }
    return widest;
  }

  if (widestAt(_minPixelsPerMinute) >= budget) return _minPixelsPerMinute;
  if (widestAt(_maxPixelsPerMinute) <= budget) return _maxPixelsPerMinute;

  var low = _minPixelsPerMinute;
  var high = _maxPixelsPerMinute;
  for (var i = 0; i < 24; i++) {
    final mid = (low + high) / 2;
    if (widestAt(mid) < budget) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return low;
}

/// The GalTV guide as a layer over the still-playing video.
///
/// Pure chrome: it draws [rows] (or the loading/empty/error state), highlights
/// the current channel and programme, and reports a channel tap back to the
/// player. It never talks to Tunarr — the player owns the fetch through
/// `GalTvSessionArgs.guideProvider` and hands the model down — and it stays
/// ignorant of the chrome controller, which the player drives while this layer is
/// up.
///
/// The player owns the route and the video keeps decoding underneath, so the
/// layer is anchored to one side, leaving the picture visible. It takes focus
/// while mounted so a remote drives the guide rather than the transport controls
/// underneath. See `plezy-tunarr/client-integration.md` §3.2.
class GalTvGuideOverlay extends StatefulWidget {
  const GalTvGuideOverlay({
    super.key,
    required this.rows,
    required this.isLoading,
    required this.error,
    required this.currentChannelId,
    required this.channelLabel,
    this.channelLogoUrl,
    this.logoHeaders,
    this.client,
    required this.isSwitching,
    required this.onSelectChannel,
    required this.onClose,
    required this.onRetry,
  });

  /// Cached channel rows; null until the first successful fetch.
  final List<GalTvGuideRow>? rows;

  final bool isLoading;

  /// User-facing load failure, or null.
  final String? error;

  /// The channel on screen, highlighted in the grid and autofocused.
  final String? currentChannelId;

  /// "CH 2 · Comedy" for the header, or null while unknown.
  final String? channelLabel;

  /// Logo of the tuned channel, shown in the header in place of the TV glyph.
  final String? channelLogoUrl;

  /// Headers every logo request needs — the gate authenticates images too.
  final Map<String, String>? logoHeaders;

  /// The Plex client for the playing item's server. Programme backdrops are
  /// fetched through the app's normal Plex image pipeline
  /// ([OptimizedMediaImage] → `/library/metadata/{ratingKey}/art`, sized and
  /// disk-cached), never through Tunarr. Null disables the artwork.
  final MediaServerClient? client;

  /// A channel switch is in flight; the grid dims and the header shows progress.
  final bool isSwitching;

  /// Tune the tapped channel. Null when the session cannot switch (the grid stays
  /// readable but inert).
  final void Function(String channelId)? onSelectChannel;

  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  State<GalTvGuideOverlay> createState() => _GalTvGuideOverlayState();
}

class _GalTvGuideOverlayState extends State<GalTvGuideOverlay> {
  final FocusScopeNode _scopeFocusNode = FocusScopeNode(debugLabel: 'GalTvGuide');
  final FocusNode _closeFocusNode = FocusNode(debugLabel: 'GalTvGuideClose');

  /// One focus node **per channel id**, owned here and never moved between rows.
  /// A single shared node that migrated to whichever row was tuned used to carry
  /// its focus with it, leaving the previous row's ring lit.
  final Map<String, FocusNode> _rowFocusNodes = {};

  /// Repaints the clock and the current programme's progress. The layer is only
  /// mounted while it is up, so the tick is bounded by its lifetime.
  Timer? _clockTimer;

  FocusNode _rowFocusNode(String channelId) =>
      _rowFocusNodes.putIfAbsent(channelId, () => FocusNode(debugLabel: 'GalTvGuideRow:$channelId'));

  /// Whether the tuned row has already been given focus. Once it has, the layer
  /// never steals focus back — the viewer may be walking the grid.
  bool _rowFocusApplied = false;

  /// Focus the tuned channel's row on open — never the close button, which is
  /// only the fallback.
  ///
  /// The grid is fetched asynchronously, so on the frame the layer opens there
  /// may be no row to focus yet: the rows land a moment later. Close holds the
  /// ring in the meantime so a remote still drives the layer, and this runs
  /// again on the update that delivers the rows until one of them takes focus —
  /// which is the owner's report, opening the guide always left the ring on the
  /// panel's X.
  void _applyAutofocus() {
    if (!mounted || _rowFocusApplied) return;
    final channelId = widget.currentChannelId;
    final node = channelId == null ? null : _rowFocusNodes[channelId];
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
      _rowFocusApplied = true;
      return;
    }
    // No focusable row yet (still loading, or a session with no channel
    // switcher): keep the ring on Close rather than nowhere.
    _closeFocusNode.requestFocus();
  }

  void _scheduleAutofocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyAutofocus());
  }

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
    // Own focus, so a remote drives the layer rather than the transport controls
    // underneath. The tuned channel's row is the entry point; Close is the
    // fallback when there is no row yet.
    _scheduleAutofocus();
  }

  @override
  void didUpdateWidget(covariant GalTvGuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final channelChanged = widget.currentChannelId != oldWidget.currentChannelId;
    if (channelChanged) {
      // A switch moved the picture: the ring follows it, even if the viewer had
      // walked to another row.
      _rowFocusApplied = false;
    }
    final rowsArrived = (oldWidget.rows?.isNotEmpty ?? false) == false && (widget.rows?.isNotEmpty ?? false);
    // Retry while the tuned row has not taken focus yet — this is the update that
    // first delivers the rows.
    if (channelChanged || rowsArrived || !_rowFocusApplied) {
      _scheduleAutofocus();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _closeFocusNode.dispose();
    for (final node in _rowFocusNodes.values) {
      node.dispose();
    }
    _rowFocusNodes.clear();
    _scopeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final media = MediaQuery.of(context);
    // Anchored panel: the guide takes almost the whole screen so several hours of
    // schedule are visible at once, leaving only a strip of picture on the right
    // (a phone keeps a proportionally smaller strip).
    final uncovered = (media.size.width * 0.08).clamp(48.0, 180.0);
    final panelWidth = media.size.width - uncovered;
    return FocusScope(
      node: _scopeFocusNode,
      child: FocusTraversalGroup(
        child: Stack(
          children: [
            // Dim the picture so the guide reads without hiding it.
            Positioned.fill(
              child: IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: 0.45))),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: panelWidth,
              child: Material(
                color: tk.bg.withValues(alpha: 0.98),
                child: SafeArea(
                  right: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(context, tk),
                      if (widget.isSwitching)
                        LinearProgressIndicator(minHeight: 2, color: Theme.of(context).colorScheme.primary)
                      else
                        Divider(height: 1, color: tk.text.withValues(alpha: 0.12)),
                      Expanded(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: widget.isSwitching ? 0.55 : 1,
                          child: _buildBody(context, tk, panelWidth),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, MonoTokens tk) {
    final label = widget.channelLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          if (widget.channelLogoUrl != null)
            ChannelLogo(url: widget.channelLogoUrl!, size: 26, headers: widget.logoHeaders)
          else
            Icon(Symbols.tv_rounded, color: tk.text, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.liveTv.guide,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tk.text, fontSize: 19, fontWeight: FontWeight.w600),
                ),
                if (label != null)
                  Text(
                    widget.isSwitching ? t.galtv.tuning : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tk.textMuted, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
          IconButton(
            focusNode: _closeFocusNode,
            onPressed: widget.onClose,
            tooltip: t.common.close,
            icon: const Icon(Symbols.close_rounded),
            color: tk.text,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, MonoTokens tk, double panelWidth) {
    final rows = widget.rows;
    if (widget.error != null) {
      return _buildMessage(
        context,
        tk,
        icon: Symbols.error_rounded,
        message: widget.error!,
        actionLabel: t.common.retry,
        onAction: widget.onRetry,
      );
    }
    if (rows == null) {
      return _buildMessage(context, tk, message: t.common.loading, loading: true);
    }
    if (rows.isEmpty) {
      return _buildMessage(context, tk, icon: Symbols.tv_off_rounded, message: t.galtv.emptyTitle);
    }

    // One time scale for the whole grid: rows must stay comparable, so the scale
    // is solved against the widest channel's row, not chosen per row. Everything
    // fetched is rendered and only the fill is solved for — a screen wide enough
    // to show all 12 h shows all 12 h, a narrow one scrolls.
    final budget = panelWidth - _channelColumnWidth - _horizontalInset;
    final pixelsPerMinute = _fitPixelsPerMinute(rows, budget);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: _rowsListPadding),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final isCurrent = widget.currentChannelId != null && row.channelId == widget.currentChannelId;
        return _GalTvGuideRowTile(
          row: row,
          tokens: tk,
          isCurrent: isCurrent,
          focusNode: _rowFocusNode(row.channelId),
          pixelsPerMinute: pixelsPerMinute,
          logoHeaders: widget.logoHeaders,
          client: widget.client,
          onSelect: widget.onSelectChannel,
        );
      },
    );
  }

  Widget _buildMessage(
    BuildContext context,
    MonoTokens tk, {
    required String message,
    IconData? icon,
    bool loading = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const CircularProgressIndicator()
            else if (icon != null)
              Icon(icon, color: tk.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: tk.text, fontSize: 15),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(foregroundColor: tk.text),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One channel line: a fixed channel column and a horizontally scrolling
/// programme row. The whole line is the tap target — selecting a channel means
/// "tune it now", whatever programme is under the finger.
class _GalTvGuideRowTile extends StatefulWidget {
  const _GalTvGuideRowTile({
    required this.row,
    required this.tokens,
    required this.isCurrent,
    required this.focusNode,
    required this.pixelsPerMinute,
    required this.logoHeaders,
    required this.client,
    required this.onSelect,
  });

  final GalTvGuideRow row;
  final MonoTokens tokens;
  final bool isCurrent;
  final FocusNode? focusNode;

  /// Headers the row's logo request needs — the gate authenticates images too.
  final Map<String, String>? logoHeaders;

  /// The Plex client used to paint each cell's programme backdrop.
  final MediaServerClient? client;

  /// The grid-wide time scale, fitted to the panel by the overlay.
  final double pixelsPerMinute;

  final void Function(String channelId)? onSelect;

  @override
  State<_GalTvGuideRowTile> createState() => _GalTvGuideRowTileState();
}

class _GalTvGuideRowTileState extends State<_GalTvGuideRowTile> {
  static const double _rowHeight = 132.0;

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tk = widget.tokens;
    final theme = Theme.of(context);
    final interactive = widget.onSelect != null;
    final selected = widget.isCurrent;

    // Only the *tuned* row may carry the primary colour. Focus is a neutral ring
    // and nothing else, so a ring that lingers on some other row can never be
    // read as "this is the channel on screen" — which is exactly how a shared
    // focus node made channel 2 look selected after tuning back to channel 1.
    final rowFill = selected ? Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: 0.18), tk.bg) : Colors.transparent;
    final borderColor = selected
        ? theme.colorScheme.primary.withValues(alpha: _focused ? 1 : 0.75)
        : (_focused ? tk.text.withValues(alpha: 0.7) : Colors.transparent);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          focusNode: widget.focusNode,
          canRequestFocus: interactive,
          onTap: interactive ? () => widget.onSelect!(widget.row.channelId) : null,
          onFocusChange: (value) {
            if (_focused != value) setState(() => _focused = value);
          },
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: _rowHeight,
            decoration: BoxDecoration(
              color: rowFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: _rowBorderWidth),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _channelColumnWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: Row(
                      children: [
                        // The channel number reads as a badge, not a whisper.
                        Container(
                          constraints: const BoxConstraints(minWidth: 30),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: selected
                                ? theme.colorScheme.primary
                                : tk.text.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(tk.radiusSm),
                          ),
                          child: Text(
                            widget.row.channelNumber,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? theme.colorScheme.onPrimary : tk.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Logo stacked over the name: the name then gets the full
                        // column width, so a long channel name fits on one line,
                        // and the logo can be big enough to actually read.
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.row.logoUrl != null) ...[
                                ChannelLogo(
                                  url: widget.row.logoUrl!,
                                  size: _logoSize,
                                  headers: widget.logoHeaders,
                                ),
                                const SizedBox(height: 6),
                              ],
                              Text(
                                widget.row.channelName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tk.text,
                                  fontSize: 15,
                                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                              // The status line is reserved on every row, so the
                              // channel names line up across the grid instead of
                              // drifting by a line height on the tuned row.
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  children: [
                                    if (selected) ...[
                                      Icon(Symbols.play_arrow_rounded, size: 13, color: theme.colorScheme.primary),
                                      const SizedBox(width: 2),
                                    ],
                                    Flexible(
                                      child: Text(
                                        selected ? t.galtv.watching : '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: theme.colorScheme.primary,
                                          fontSize: 11,
                                          height: 1.2,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The fade only earns its place when the strip really
                      // overflows; on a full-width panel the whole window fits and
                      // a permanent gradient would just dim the last cell.
                      final contentWidth = _rowWidthAt(widget.row, widget.pixelsPerMinute);
                      final scrollable = contentWidth > constraints.maxWidth - 2 * _stripPadding + 1;
                      final rowBase = Color.alphaBlend(rowFill, tk.bg);
                      return Stack(
                        children: [
                          ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: _stripPadding, vertical: 8),
                            itemCount: widget.row.entries.length,
                            separatorBuilder: (_, _) => const SizedBox(width: _cellGap),
                            itemBuilder: (context, index) => _GalTvGuideEntryTile(
                              entry: widget.row.entries[index],
                              tokens: tk,
                              pixelsPerMinute: widget.pixelsPerMinute,
                              client: widget.client,
                            ),
                          ),
                          // A thin fade marks the strip as scrollable, so a title
                          // cut off at the panel edge reads as "more to the right"
                          // rather than as broken text.
                          if (scrollable)
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              width: 26,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        rowBase.withValues(alpha: 0),
                                        rowBase,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One programme cell. [GalTvGuideEntry.isCurrent] is filled with the accent and
/// carries a NOW badge and a progress bar; a non-playable entry (a Tunarr `flex`
/// break) is dimmed but still shown, so the grid keeps the schedule's shape.
class _GalTvGuideEntryTile extends StatelessWidget {
  const _GalTvGuideEntryTile({
    required this.entry,
    required this.tokens,
    required this.pixelsPerMinute,
    required this.client,
  });

  final GalTvGuideEntry entry;
  final MonoTokens tokens;
  final double pixelsPerMinute;

  /// The Plex client the cell's backdrop is fetched through; null leaves the
  /// plain cell.
  final MediaServerClient? client;

  @override
  Widget build(BuildContext context) {
    final isCurrent = entry.isCurrent;
    final playable = entry.isPlayable;
    final theme = Theme.of(context);

    final idleFill = Color.alphaBlend(tokens.text.withValues(alpha: 0.07), tokens.bg);
    final currentFill = Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: 0.28), tokens.bg);
    final borderColor = isCurrent
        ? theme.colorScheme.primary
        : tokens.text.withValues(alpha: playable ? 0.16 : 0.08);
    final titleColor = playable
        ? (isCurrent ? tokens.text : tokens.text)
        : tokens.textMuted.withValues(alpha: 0.7);
    final width = _entryWidthFor(entry, pixelsPerMinute);
    final ratingKey = entry.ratingKey;
    final radius = BorderRadius.circular(tokens.radiusSm);

    return Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isCurrent ? currentFill : idleFill,
        borderRadius: radius,
      ),
      // Painted above the artwork so the focus/current ring is never buried.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: borderColor, width: isCurrent ? 2 : 1),
      ),
      child: Stack(
        children: [
          // The item's own Plex backdrop, fetched the way the rest of the app
          // fetches artwork (sized `/photo/:/transcode`, disk-cached, token
          // included). A missing backdrop, or no client, simply shows the cell
          // fill underneath — never a broken tile.
          if (ratingKey != null)
            Positioned.fill(
              child: OptimizedMediaImage(
                client: client,
                imagePath: '/library/metadata/$ratingKey/art',
                width: width,
                fit: BoxFit.cover,
                imageType: ImageType.art,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          // A scrim, because artwork can be bright exactly where the white title
          // sits. Denser at the bottom, where the times are.
          if (ratingKey != null)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x59000000), Color(0xB8000000)],
                  ),
                ),
              ),
            ),
          // The progress bar rides the cell's bottom edge instead of taking a row
          // from the text: a badge plus a two-line title already fills a narrow
          // cell, and squeezing that text is what used to mangle the title.
          Padding(
            padding: EdgeInsets.fromLTRB(10, 8, 10, isCurrent ? 12 : 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isCurrent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            t.galtv.nowBadge,
                            style: TextStyle(
                              color: theme.colorScheme.onPrimary,
                              fontSize: 9,
                              // Every line height is pinned so the cell's budget
                              // does not depend on the active font's metrics.
                              height: 1.2,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Natural height, capped at two lines. A squeezed [Expanded] used
                // to hand the title less than two lines of room, and [Text] does
                // not clip its overflow: the second line painted down over the
                // time row. That was the "weird text". Any shortfall must now be a
                // loud layout overflow (the widget test pins that), never silent
                // overlap.
                Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 14,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                    height: 1.1,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_formatClock(entry.start)} – ${_formatClock(entry.stop)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tokens.textMuted, fontSize: 12, height: 1.2),
                ),
              ],
            ),
          ),
          if (isCurrent)
            Positioned(
              left: 9,
              right: 9,
              bottom: 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: _currentProgress(),
                  minHeight: 3,
                  backgroundColor: tokens.text.withValues(alpha: 0.15),
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// How far into the current programme we are, from the wall clock. The layer
  /// repaints on [_GalTvGuideOverlayState._clockTimer], so this stays live while
  /// the guide is up.
  double _currentProgress() {
    final total = entry.duration.inMilliseconds;
    if (total <= 0) return 0;
    final elapsed = DateTime.now().difference(entry.start).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  String _formatClock(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
