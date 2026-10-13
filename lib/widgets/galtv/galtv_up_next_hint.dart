import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_server_client.dart';
import '../../models/galtv/galtv_guide.dart';
import '../optimized_media_image.dart';

/// What the channel plays next, in miniature: the programme's **`clearLogo`
/// wordmark** and the time it starts — bare over the picture, with no background
/// of its own (the owner removed the dark pill on 2026-10-09: it could only be
/// sized for one of the two lines it wrapped, and a box edge over moving video
/// reads as a stray UI element).
///
/// Pinned above the UP NEXT button for the whole of a GalTV **filler**, so the
/// answer to "what is next" is on screen continuously rather than only after
/// pressing something — the owner's ask, 2026-10-09: *"above the up next button
/// while watching ads can we add the Text Logo of the upcoming Movie/TVShow? so
/// you can always see whats next anyway but in a minimized form, with the start
/// time too"*.
///
/// Deliberately **not interactive**: the UP NEXT pill directly under it is the
/// affordance, and a second tappable layer over the picture would swallow taps
/// meant for the video surface (hence the [IgnorePointer]).
///
/// The logo comes from Plex exactly as the full slate's does ([ClearLogoImage],
/// the app's own image pipeline). A film or episode whose item has no `clearLogo`
/// — and every item in an `Other Videos` library never has one — falls back to the
/// title, so the hint is never blank.
class GalTvUpNextHint extends StatefulWidget {
  const GalTvUpNextHint({super.key, required this.upNext, this.client, this.mediaResolver});

  /// The next programme. Only [GalTvUpNext.startsAt] is used for the time line;
  /// the wordmark comes from [mediaResolver].
  final GalTvUpNext upNext;

  /// The Plex client the wordmark is fetched through. Null is supported: the hint
  /// then shows the plain title.
  final MediaServerClient? client;

  /// Test/preview seam: resolves the artwork payload for a rating key, replacing
  /// the client fetch. Mirrors `GalTvUpNextOverlay.mediaResolver`.
  final Future<GalTvUpNextMedia?> Function(String ratingKey)? mediaResolver;

  @override
  State<GalTvUpNextHint> createState() => _GalTvUpNextHintState();
}

class _GalTvUpNextHintState extends State<GalTvUpNextHint> {
  /// Wordmark slot. Big enough to read at TV distance now that nothing else
  /// frames it: with the pill gone the logo *is* the hint, so it is sized to the
  /// UP NEXT button under it (40 px against the button's ~40) rather than to a
  /// chip's inner line.
  static const double _logoWidth = 240;
  static const double _logoHeight = 40;

  GalTvUpNextMedia? _media;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMedia());
  }

  @override
  void didUpdateWidget(covariant GalTvUpNextHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.upNext.ratingKey != widget.upNext.ratingKey ||
        oldWidget.mediaResolver != widget.mediaResolver ||
        oldWidget.client != widget.client) {
      _media = null;
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

  @override
  Widget build(BuildContext context) {
    final media = _media;
    // The payload's own title is the fallback until (or unless) Plex answers —
    // `GalTvUpNext.title` is already what the schedule said.
    final title = (media?.title ?? '').trim().isNotEmpty ? media!.title! : widget.upNext.title;

    return IgnorePointer(
      // No ground of its own: the owner's call, 2026-10-09 — *"remove the
      // background of that small preview … cause the background isnt even well
      // sized"*. A painted pill can only be right for one of the two things it
      // wraps (the wordmark and the time line are different widths), and this one
      // rides over moving video where a box edge reads as a stray UI element
      // rather than as contrast. The content is right-aligned to the same edge as
      // the UP NEXT button under it, so the two read as one column.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ClearLogoImage(
            client: widget.client,
            logoPath: media?.logoPath,
            width: _logoWidth,
            height: _logoHeight,
            fallbackWidth: _logoWidth,
            alignment: Alignment.centerRight,
            fallbackBuilder: (context) => Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.2),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            // Same phrasing the full slate uses for the same fact; a second
            // key for one line of text would only invite them to drift.
            t.galtv.startsAt(
              time: MaterialLocalizations.of(context).formatTimeOfDay(
                TimeOfDay.fromDateTime(widget.upNext.startsAt.toLocal()),
                alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
              ),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.2),
          ),
        ],
      ),
    );
  }
}
