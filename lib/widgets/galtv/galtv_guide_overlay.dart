import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../models/galtv/galtv_guide.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_image_helper.dart';
import '../optimized_media_image.dart';
import '../video_controls/widgets/channel_logo.dart';

/// Programme cell metrics. A cell's *pitch* — the box it occupies in the strip —
/// is exactly its duration at the shared time scale: no minimum, no maximum, and
/// no gap between boxes. That is what keeps the ruler above the grid honest: a
/// cell's left edge then lands exactly on its start time, so a tick and the cell
/// that begins at that time share an `x`. The visual gutter between cards lives
/// *inside* the box ([_cellGap]), so separating them cannot shift the time axis.

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

/// The gutter between two cards, carried as a right inset *inside* each cell's
/// box so the box pitch stays exactly the cell's duration.
const double _cellGap = 6;

/// Everything between the panel edge and the cells: the rows list's padding, the
/// row's border, and the strip's own padding — on both sides.
const double _horizontalInset = 2 * (_rowsListPadding + _rowBorderWidth + _stripPadding);

/// Where the ruler sits so it spans exactly the horizontal strips below it: past
/// the channel column, the rows list's padding and the row's border — the same
/// edges a strip spans. The painter then adds [_stripPadding], so ruler `x = 0` is
/// the window start, matching a row's cell coordinates.
const double _stripViewportLeftInset = _channelColumnWidth + _rowsListPadding + _rowBorderWidth;
const double _stripViewportRightInset = _rowsListPadding + _rowBorderWidth;

/// How far a row's leading gap (a schedule hole at the window start) pushes its
/// first cell. Part of the row's width, so the time scale accounts for it.
double _leadingWidthFor(GalTvGuideRow row, double pixelsPerMinute) => row.leadingMs / 60000 * pixelsPerMinute;

/// The pitch [entry] occupies at [pixelsPerMinute]: its duration at the shared
/// time scale. Shared with the row, which sums it to decide whether its strip
/// actually overflows.
double _entryPitchFor(GalTvGuideEntry entry, double pixelsPerMinute) => entry.duration.inSeconds / 60 * pixelsPerMinute;

/// The width a row's *cells* occupy at [pixelsPerMinute], including its leading
/// gap. This is the row's true time span in pixels, so the fitted scale and the
/// ruler's ticks agree with it.
double _rowWidthAt(GalTvGuideRow row, double pixelsPerMinute) {
  var width = _leadingWidthFor(row, pixelsPerMinute);
  for (final entry in row.entries) {
    width += _entryPitchFor(entry, pixelsPerMinute);
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
    this.summaryProvider,
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

  /// Resolves a programme's synopsis from its Plex `ratingKey` — the text the
  /// rest of the app shows on an item's detail page.
  ///
  /// When null the overlay uses the ordinary route through [client]
  /// (`fetchItem`, i.e. `/library/metadata/{ratingKey}`); the seam exists so a
  /// caller with no client to hand can still supply descriptions. Only the row
  /// the viewer has focused is ever asked, so a guide of twenty channels costs
  /// one description, not twenty.
  final Future<String?> Function(String ratingKey)? summaryProvider;

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

  /// One horizontal offset for the whole grid. Each row owns its own controller
  /// (the vertical list recycles rows, and a re-attached position would restart
  /// at 0) and reports its scrolls here; every other row follows. Without this the
  /// rows scrolled independently and the ruler above them could not stay true.
  final ValueNotifier<double> _horizontalOffset = ValueNotifier<double>(0);

  /// Programme synopses by Plex `ratingKey`. Filled on demand — only the row the
  /// viewer has focused asks for one — and kept for the layer's lifetime so
  /// walking the grid back and forth does not refetch.
  final Map<String, Future<String?>> _summaries = {};

  /// The resolver the rows get, or null when this session cannot fetch a
  /// synopsis at all (no client and no injected provider) — the rows then never
  /// reserve space for one.
  Future<String?> Function(String ratingKey)? get _summaryResolver =>
      (widget.summaryProvider == null && widget.client == null) ? null : _loadSummary;

  Future<String?> _loadSummary(String ratingKey) {
    return _summaries.putIfAbsent(ratingKey, () async {
      final provider = widget.summaryProvider;
      if (provider != null) return _nonEmptySummary(await provider(ratingKey));
      final client = widget.client;
      if (client == null) return null;
      try {
        // The app's normal route to an item's description — the same call the
        // detail screen makes, so an episode shows the episode's own synopsis.
        return _nonEmptySummary((await client.fetchItem(ratingKey))?.summary);
      } catch (error, stackTrace) {
        appLogger.w('GalTV programme summary failed', error: error, stackTrace: stackTrace);
        return null;
      }
    });
  }

  static String? _nonEmptySummary(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

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
    _horizontalOffset.dispose();
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
    final now = DateTime.now();
    // The window the rows were clamped to. Derived rather than passed in: every
    // row records how far its first cell sits from the window start
    // (`leadingMs`), so `first.start − leadingMs` is that start back — and the
    // layer therefore needs no extra contract with the tab, which computes the
    // window when it fetches.
    final windowStart = _windowStart(rows);
    final windowEnd = _windowEnd(rows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (windowStart != null && windowEnd != null)
          _GalTvTimeRuler(
            windowStart: windowStart,
            windowEnd: windowEnd,
            pixelsPerMinute: pixelsPerMinute,
            scrollOffset: _horizontalOffset,
            tokens: tk,
          ),
        Expanded(
          child: ListView.builder(
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
                now: now,
                windowStart: windowStart,
                scrollOffset: _horizontalOffset,
                summaryFor: _summaryResolver,
                onSelect: widget.onSelectChannel,
                onClose: widget.onClose,
              );
            },
          ),
        ),
      ],
    );
  }

  /// The instant every row's `x = 0` maps to. Empty rows are skipped: they have
  /// no cells to place.
  static DateTime? _windowStart(List<GalTvGuideRow> rows) {
    DateTime? earliest;
    for (final row in rows) {
      if (row.entries.isEmpty) continue;
      final start = row.entries.first.start.subtract(Duration(milliseconds: row.leadingMs));
      if (earliest == null || start.isBefore(earliest)) earliest = start;
    }
    return earliest;
  }

  /// The far end of the fetched window: the latest cut-off any row reaches. Every
  /// row was clamped to the same window, so at least one row that ran long sits
  /// exactly on it.
  static DateTime? _windowEnd(List<GalTvGuideRow> rows) {
    DateTime? latest;
    for (final row in rows) {
      if (row.entries.isEmpty) continue;
      final stop = row.entries.last.stop;
      if (latest == null || stop.isAfter(latest)) latest = stop;
    }
    return latest;
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
    required this.now,
    required this.windowStart,
    required this.scrollOffset,
    required this.summaryFor,
    required this.onSelect,
    required this.onClose,
  });

  final GalTvGuideRow row;
  final MonoTokens tokens;
  final bool isCurrent;
  final FocusNode? focusNode;

  /// Headers the row's logo request needs — the gate authenticates images too.
  final Map<String, String>? logoHeaders;

  /// The Plex client used to paint each cell's programme backdrop.
  final MediaServerClient? client;

  /// The wall clock this frame paints against — drives the "airing now" progress
  /// and the vertical now marker.
  final DateTime now;

  /// The window start every row's `x = 0` maps to, or null when the grid has no
  /// cells at all.
  final DateTime? windowStart;

  /// The grid-wide horizontal offset; this row follows it and reports its own
  /// scrolls back into it.
  final ValueNotifier<double> scrollOffset;

  /// Resolves the synopsis of a programme by its Plex `ratingKey`. Null when the
  /// session cannot fetch one — the row then never reserves the space.
  final Future<String?> Function(String ratingKey)? summaryFor;

  /// The grid-wide time scale, fitted to the panel by the overlay.
  final double pixelsPerMinute;

  final void Function(String channelId)? onSelect;

  /// Dismisses the layer. The row that is already the channel on screen uses
  /// this instead of [onSelect]: its activation is a dismissal, never a re-tune.
  final VoidCallback onClose;

  @override
  State<_GalTvGuideRowTile> createState() => _GalTvGuideRowTileState();
}

class _GalTvGuideRowTileState extends State<_GalTvGuideRowTile> {
  static const double _rowHeight = 132.0;

  /// Extra height the focused row takes for the airing programme's synopsis. It
  /// is what makes the selected channel read as "fatter" than the others.
  static const double _descriptionHeight = 64.0;

  bool _focused = false;

  /// The synopsis currently shown, and the ratingKey it belongs to — so a stale
  /// fetch can never paint over the row that has since been focused.
  String? _summaryRatingKey;
  String? _summary;

  /// This row's own horizontal controller. The vertical list recycles rows, so a
  /// single [ScrollController] shared by every strip cannot be used: a position
  /// that re-attaches would start at 0 while its siblings sit mid-window. Each row
  /// therefore follows [widget.scrollOffset] and reports its own scrolls back.
  final ScrollController _stripController = ScrollController();

  /// Set on the first post-frame. Before that the strip's only notification is the
  /// list's initial anchor, which must not be mistaken for a user scroll.
  bool _ready = false;

  /// Cleared when this row's strip is shorter than the shared offset: it then
  /// pins at its own end instead of dragging the whole grid back to fit.
  bool _followsSharedOffset = true;

  @override
  void initState() {
    super.initState();
    _stripController.addListener(_onStripScrolled);
    widget.scrollOffset.addListener(_applySharedOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ready = true;
      _applySharedOffset();
      _syncSummary();
    });
  }

  @override
  void didUpdateWidget(covariant _GalTvGuideRowTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The clock rolls over a programme boundary while the row stays focused, so
    // the description has to be re-resolved for whatever is airing now. Deferred:
    // didUpdateWidget runs inside the parent's build.
    if (oldWidget.now != widget.now || oldWidget.row != widget.row || oldWidget.summaryFor != widget.summaryFor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSummary();
      });
    }
  }

  /// The programme this row is airing right now, by the wall clock — the same
  /// rule the cell's badge uses.
  GalTvGuideEntry? get _airingEntry {
    for (final entry in widget.row.entries) {
      if (!widget.now.isBefore(entry.start) && widget.now.isBefore(entry.stop)) return entry;
    }
    return null;
  }

  /// Whether this row takes the fatter, descriptive form: it has focus, the
  /// session can resolve a synopsis, and it is airing something with a Plex
  /// identity (a `flex` break has nothing to describe).
  bool get _describesProgramme => _focused && widget.summaryFor != null && _airingEntry?.ratingKey != null;

  /// Fetch the description for whatever this row is airing, or drop it once the
  /// row loses focus. Only one row is focused at a time, so the grid resolves at
  /// most one synopsis — the description is never fetched for rows the viewer has
  /// not looked at.
  void _syncSummary() {
    final ratingKey = _describesProgramme ? _airingEntry!.ratingKey : null;
    if (ratingKey == _summaryRatingKey) return;
    _summaryRatingKey = ratingKey;
    _summary = null;
    if (ratingKey == null) {
      if (mounted) setState(() {});
      return;
    }
    widget.summaryFor!(ratingKey).then((value) {
      if (!mounted || _summaryRatingKey != ratingKey) return;
      setState(() => _summary = value);
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.scrollOffset.removeListener(_applySharedOffset);
    _stripController.removeListener(_onStripScrolled);
    _stripController.dispose();
    super.dispose();
  }

  void _onStripScrolled() {
    if (!mounted || !_ready || !_followsSharedOffset || !_stripController.hasClients) return;
    final value = _stripController.offset;
    if ((widget.scrollOffset.value - value).abs() > 0.5) widget.scrollOffset.value = value;
  }

  /// Activate this row: the channel already playing is a dismissal, anything
  /// else tunes.
  ///
  /// Picking the channel on screen must never re-resolve it. Re-resolving reloads
  /// the very item that is playing — the picture pauses and re-seeks, and the grid
  /// loses the focus it had — which is what the owner hit. "Sync to live" is the
  /// control that exists for deliberately snapping back to the schedule.
  void _activate() {
    if (widget.isCurrent) {
      widget.onClose();
      return;
    }
    widget.onSelect?.call(widget.row.channelId);
  }

  void _applySharedOffset() {
    if (!mounted || !_followsSharedOffset || !_stripController.hasClients) return;
    final target = widget.scrollOffset.value;
    if ((_stripController.offset - target).abs() <= 0.5) return;
    _stripController.jumpTo(target);
    // A strip too short for the shared offset can never follow it; stop trying so
    // its clamp does not pull the other rows back.
    if ((_stripController.offset - target).abs() > 0.5) _followsSharedOffset = false;
  }

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
    final rowFill = selected
        ? Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: 0.18), tk.bg)
        : Colors.transparent;
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
          onTap: (interactive || selected) ? _activate : null,
          onFocusChange: (value) {
            if (_focused == value) return;
            setState(() => _focused = value);
            // Focus *is* the selection here: the row the D-pad sits on is the one
            // that grows and shows its programme's description.
            _syncSummary();
          },
          borderRadius: BorderRadius.circular(12),
          // The focused row carries the extra synopsis band; `AnimatedSize` grows
          // and clips it so the rows below slide instead of jumping, and so a
          // half-finished animation can never overflow.
          child: AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: rowFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: _rowBorderWidth),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: _rowHeight,
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
                                    color: selected ? theme.colorScheme.primary : tk.text.withValues(alpha: 0.14),
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
                                              Icon(
                                                Symbols.play_arrow_rounded,
                                                size: 13,
                                                color: theme.colorScheme.primary,
                                              ),
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
                              // The gap this channel's schedule has at the window start.
                              // Left padding is part of the row's coordinates: a cell at
                              // time T always sits at `leading + (T − windowStart)`, which
                              // is what makes one ruler correct for every channel.
                              final leadingWidth = _leadingWidthFor(widget.row, widget.pixelsPerMinute);
                              final windowStart = widget.windowStart;
                              final nowPx = windowStart == null
                                  ? null
                                  : widget.now.difference(windowStart).inMilliseconds / 60000 * widget.pixelsPerMinute;
                              return Stack(
                                children: [
                                  // No separator: a cell's box pitch is its duration, and
                                  // the visible gutter lives inside the box, so boxes stay
                                  // on the time axis.
                                  ListView.builder(
                                    controller: _stripController,
                                    scrollDirection: Axis.horizontal,
                                    padding: EdgeInsets.fromLTRB(_stripPadding + leadingWidth, 8, _stripPadding, 8),
                                    itemCount: widget.row.entries.length,
                                    itemBuilder: (context, index) => _GalTvGuideEntryTile(
                                      entry: widget.row.entries[index],
                                      tokens: tk,
                                      pixelsPerMinute: widget.pixelsPerMinute,
                                      now: widget.now,
                                      client: widget.client,
                                    ),
                                  ),
                                  // The now line runs down the whole grid at `now`'s `x`,
                                  // so a channel's position in its own schedule reads at a
                                  // glance. It is a sibling of the strip (not inside the
                                  // scroll view), so it subtracts the shared offset itself
                                  // and repaints as the grid scrolls.
                                  if (nowPx != null)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          painter: _NowLinePainter(
                                            nowPx: nowPx,
                                            stripPadding: _stripPadding,
                                            color: Theme.of(context).colorScheme.primary,
                                            offset: widget.scrollOffset,
                                          ),
                                        ),
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
                                              colors: [rowBase.withValues(alpha: 0), rowBase],
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
                  if (_describesProgramme) SizedBox(height: _descriptionHeight, child: _buildDescription(tk)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The airing programme's synopsis — the same Plex text the item's detail page
  /// shows.
  ///
  /// It is anchored under the cell of the programme it describes (and follows the
  /// grid's horizontal scroll) rather than running the whole row, so it reads as
  /// *that* programme's description; its width is capped so a wide panel does not
  /// turn it back into a full-width band. Empty while it resolves: the band keeps
  /// its height so the row cannot jump when the words land.
  Widget _buildDescription(MonoTokens tk) {
    return ValueListenableBuilder<double>(
      valueListenable: widget.scrollOffset,
      builder: (context, scroll, _) => LayoutBuilder(
        builder: (context, constraints) {
          final rowWidth = constraints.maxWidth;
          final maxWidth = (rowWidth * 0.45).clamp(240.0, 560.0);
          final leftLimit = (rowWidth - maxWidth - 16).clamp(12.0, double.infinity);
          final left = _airingCellX(scroll).clamp(12.0, leftLimit);
          final available = (rowWidth - left - 16).clamp(0.0, double.infinity);
          final width = available < maxWidth ? available : maxWidth;
          return Padding(
            padding: EdgeInsets.fromLTRB(left, 0, rowWidth - left - width, 10),
            child: Text(
              _summary ?? '',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tk.textMuted, fontSize: 13, height: 1.3),
            ),
          );
        },
      ),
    );
  }

  /// Where the airing cell's left edge sits in this card's coordinates — the same
  /// mapping the strip uses (`_stripPadding` in from the channel column, then the
  /// time offset from the window start), minus the grid's shared scroll.
  double _airingCellX(double scroll) {
    final windowStart = widget.windowStart;
    final entry = _airingEntry;
    if (windowStart == null || entry == null) return _channelColumnWidth + _stripPadding;
    final minutesFromWindowStart = entry.start.difference(windowStart).inMilliseconds / 60000;
    return _channelColumnWidth + _stripPadding + minutesFromWindowStart * widget.pixelsPerMinute - scroll;
  }
}

/// One programme cell. [GalTvGuideEntry.isCurrent] is filled with the accent and
/// carries a NOW badge and a progress bar; a non-playable entry (a Tunarr `flex`
/// break) is dimmed but still shown, so the grid keeps the schedule's shape.
///
/// "Tuned" and "airing now" are deliberately different signals: **every**
/// channel's airing cell shows how far in it is (badge, progress bar, dimmed
/// elapsed portion), but only the tuned channel's row wears the accent fill and
/// border. Tinting every airing row would read as if every channel were the one
/// on screen.
class _GalTvGuideEntryTile extends StatelessWidget {
  const _GalTvGuideEntryTile({
    required this.entry,
    required this.tokens,
    required this.pixelsPerMinute,
    required this.now,
    required this.client,
  });

  final GalTvGuideEntry entry;
  final MonoTokens tokens;
  final double pixelsPerMinute;

  /// The wall clock this frame paints against. The layer rebuilds on a timer, so
  /// the progress and the dimmed portion stay live while the guide is up.
  final DateTime now;

  /// The Plex client the cell's backdrop is fetched through; null leaves the
  /// plain cell.
  final MediaServerClient? client;

  @override
  Widget build(BuildContext context) {
    final isCurrent = entry.isCurrent;
    // The tuned channel's programme comes from the player's live identity; every
    // other channel's "now" is derived from the wall clock against the slot's own
    // bounds.
    final isAiring = isCurrent || (!now.isBefore(entry.start) && now.isBefore(entry.stop));
    final playable = entry.isPlayable;
    final theme = Theme.of(context);

    final idleFill = Color.alphaBlend(tokens.text.withValues(alpha: 0.07), tokens.bg);
    final currentFill = Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: 0.28), tokens.bg);
    final borderColor = isCurrent ? theme.colorScheme.primary : tokens.text.withValues(alpha: playable ? 0.16 : 0.08);
    final titleColor = playable ? (isCurrent ? tokens.text : tokens.text) : tokens.textMuted.withValues(alpha: 0.7);
    final pitch = _entryPitchFor(entry, pixelsPerMinute);
    // The card keeps the box's left edge — its start time — and gives up only the
    // gutter, so the tick above it stays true.
    final width = (pitch - _cellGap).clamp(1.0, double.infinity);
    final ratingKey = entry.ratingKey;
    final radius = BorderRadius.circular(tokens.radiusSm);
    final progress = _progress();

    return SizedBox(
      width: pitch,
      child: Padding(
        padding: const EdgeInsets.only(right: _cellGap),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: isCurrent ? currentFill : idleFill, borderRadius: radius),
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
              // The part of an airing programme that has already played, dimmed — so
              // "where is this channel in its film" reads without a badge. Painted
              // under the text, over the artwork.
              if (isAiring && progress > 0)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: const ColoredBox(color: Color(0x38000000)),
                  ),
                ),
              // The progress bar rides the cell's bottom edge instead of taking a row
              // from the text: a badge plus a two-line title already fills a narrow
              // cell, and squeezing that text is what used to mangle the title.
              Padding(
                padding: EdgeInsets.fromLTRB(10, 8, 10, isAiring ? 12 : 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isAiring)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                // Filled accent for the tuned channel; an accent-tinted
                                // outline for "airing elsewhere", which must not read
                                // as the channel on screen.
                                color: isCurrent
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.primary.withValues(alpha: 0.16),
                                border: isCurrent
                                    ? null
                                    : Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                t.galtv.nowBadge,
                                style: TextStyle(
                                  color: isCurrent ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
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
              if (isAiring)
                Positioned(
                  left: 9,
                  right: 9,
                  bottom: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: tokens.text.withValues(alpha: 0.15),
                      color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.75),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// How far into the programme we are, from the wall clock. The layer repaints
  /// on [_GalTvGuideOverlayState._clockTimer], so this stays live while the guide
  /// is up.
  double _progress() {
    final total = entry.duration.inMilliseconds;
    if (total <= 0) return 0;
    final elapsed = now.difference(entry.start).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}

/// The clock above the grid: a tick and its label every 30 minutes, plus the now
/// marker. It shares the rows' time scale and scroll offset, so a tick sits
/// exactly over the programme boundary it names.
///
/// It sits outside the rows' vertical list, so it stays put while they scroll.
class _GalTvTimeRuler extends StatelessWidget {
  const _GalTvTimeRuler({
    required this.windowStart,
    required this.windowEnd,
    required this.pixelsPerMinute,
    required this.scrollOffset,
    required this.tokens,
  });

  final DateTime windowStart;
  final DateTime windowEnd;
  final double pixelsPerMinute;
  final ValueListenable<double> scrollOffset;
  final MonoTokens tokens;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final ticks = _halfHourTicks(windowStart, windowEnd);
    return SizedBox(
      height: 28,
      child: Padding(
        // The ruler spans exactly the strips below it; a tick then lands on the
        // same `x` as the cell for the programme that starts at it.
        padding: const EdgeInsets.only(left: _stripViewportLeftInset, right: _stripViewportRightInset),
        child: ValueListenableBuilder<double>(
          valueListenable: scrollOffset,
          builder: (context, scroll, _) {
            final nowX = _stripPadding + _xAt(now) - scroll;
            return Stack(
              fit: StackFit.expand,
              children: [
                for (final tick in ticks)
                  Positioned(
                    left: _stripPadding + _xAt(tick) - scroll,
                    top: 0,
                    bottom: 0,
                    width: 54,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatClock(tick),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          // The hour stands out; the half hour is a quieter mark.
                          style: TextStyle(
                            color: tokens.textMuted,
                            fontSize: 12,
                            height: 1.1,
                            fontWeight: tick.minute == 0 ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                        const Spacer(),
                        Container(width: 1, height: 6, color: tokens.text.withValues(alpha: 0.25)),
                      ],
                    ),
                  ),
                Positioned(
                  left: nowX - 0.75,
                  top: 0,
                  bottom: 0,
                  width: 1.5,
                  child: ColoredBox(color: theme.colorScheme.primary),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Where [time] sits on the grid, in strip-content pixels: the same mapping a
  /// row uses for its cells, so the ruler's tick and the cell that begins at that
  /// time share an `x`.
  double _xAt(DateTime time) => time.difference(windowStart).inMilliseconds / 60000 * pixelsPerMinute;
}

/// The vertical now marker drawn down a single row's strip.
///
/// It is a sibling of the scrolling strip, so it subtracts the shared offset
/// itself and repaints as the grid scrolls — and it stays out of the content, so
/// it never triggers an artwork request.
class _NowLinePainter extends CustomPainter {
  _NowLinePainter({required this.nowPx, required this.stripPadding, required this.color, required this.offset})
    : super(repaint: offset);

  final double nowPx;
  final double stripPadding;
  final Color color;
  final ValueListenable<double> offset;

  @override
  void paint(Canvas canvas, Size size) {
    final x = stripPadding + nowPx - offset.value;
    if (x < 0 || x > size.width) return;
    canvas.drawRect(Rect.fromLTWH(x - 0.75, 0, 1.5, size.height), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _NowLinePainter oldDelegate) =>
      oldDelegate.nowPx != nowPx || oldDelegate.stripPadding != stripPadding || oldDelegate.color != color;
}

/// The wall-clock half hour at or before [local], as a local [DateTime].
DateTime _floorToHalfHour(DateTime local) =>
    DateTime(local.year, local.month, local.day, local.hour, local.minute - (local.minute % 30));

/// The next wall-clock half hour. Built from the wall clock rather than by adding
/// a duration, so a DST change cannot push the labels off the half hour.
DateTime _addHalfHour(DateTime local) => DateTime(local.year, local.month, local.day, local.hour, local.minute + 30);

/// The 30-minute boundaries the ruler labels: wall-clock halves, not
/// "windowStart + 30 min", so the labels read as times a viewer recognizes.
List<DateTime> _halfHourTicks(DateTime windowStart, DateTime windowEnd) {
  final ticks = <DateTime>[];
  var boundary = _floorToHalfHour(windowStart.toLocal());
  if (boundary.isBefore(windowStart)) boundary = _addHalfHour(boundary);
  // Bounded so a nonsensical window can never spin: 12 h is 25 ticks.
  while (!boundary.isAfter(windowEnd) && ticks.length < 200) {
    ticks.add(boundary);
    boundary = _addHalfHour(boundary);
  }
  return ticks;
}

String _formatClock(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
