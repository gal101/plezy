import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';

/// How the server is delivering the item being played, as a compact tag for the
/// player's button row: a status dot plus `Direct Play` or `Transcoding`.
///
/// The one thing a viewer otherwise cannot see about a session, and the fastest
/// way to confirm a GalTV tune really is a Plex Direct Play rather than a
/// transcode (the Plex dashboard cannot show it — watch reporting is suppressed,
/// see `plezy-tunarr/client-integration.md` §4.3).
///
/// Two states, deliberately: it mirrors [PlaybackSession.isTranscoding], and the
/// server's own `playMethod` string only ever reads `DirectPlay` or `Transcode`
/// in this codebase — a Jellyfin direct *stream* reports as Direct Play.
class PlayMethodTag extends StatelessWidget {
  const PlayMethodTag({super.key, required this.isTranscoding});

  final bool isTranscoding;

  @override
  Widget build(BuildContext context) {
    final color = isTranscoding ? const Color(0xFFFFCA28) : Colors.white70;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        // Flexible so the tag yields — rather than overflowing — when the button
        // row it sits in has no room to spare.
        Flexible(
          child: Text(
            isTranscoding ? t.videoControls.playMethodTranscode : t.videoControls.playMethodDirectPlay,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.2),
          ),
        ),
      ],
    );
  }
}
