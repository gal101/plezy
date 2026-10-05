import 'package:flutter/material.dart';

/// A channel's logo, or nothing when it cannot be loaded.
///
/// Tunarr serves the icon through the gate, and the gate authenticates **every**
/// proxied path — images included — so [headers] must carry the Plex token. A
/// channel without a logo, or one whose URL fails, paints a sized gap rather
/// than a broken tile.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.url, required this.size, this.headers});

  final String url;
  final double size;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        headers: headers,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => SizedBox(width: size, height: size),
      ),
    );
  }
}
