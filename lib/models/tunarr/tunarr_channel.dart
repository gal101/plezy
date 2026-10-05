import 'dart:convert';

/// A channel as returned by the gate's proxied `GET /api/channels`.
///
/// The wire body is `{"number":1,"name":"…","id":"4c3a112a-…","icon":{…},
/// "programCount":6,…}`. [number] stays a [String] because the field is a
/// number on the wire today but the two Tunarr surfaces (channels vs. lineups)
/// disagree, and a channel number is an identifier, never arithmetic. [icon]
/// is a nested object on the wire; only its `path` is kept.
class TunarrChannel {
  final String id;
  final String name;

  /// Channel number, coerced to text — the API sends a number but the wire may
  /// be either.
  final String number;

  /// Path part of the nested `icon` object, when present.
  final String? iconPath;

  final int programCount;

  const TunarrChannel({
    required this.id,
    required this.name,
    required this.number,
    this.iconPath,
    this.programCount = 0,
  });

  /// Reads the wire shape (camelCase) and, for [decode] round-trips, the
  /// persisted shape (snake_case).
  ///
  /// Defensive by design: [number] accepts an `int` **or** a `String`, and the
  /// icon accepts either a nested `{path}` object or a bare string.
  factory TunarrChannel.fromJson(Map<String, Object?> json) => TunarrChannel(
    id: json['id']?.toString() ?? '',
    name: json['name'] as String? ?? '',
    number: json['number']?.toString() ?? '',
    iconPath: readTunarrIconPath(json['icon']) ?? (json['icon_path'] as String?),
    programCount: ((json['programCount'] ?? json['program_count']) as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'number': number,
    'icon_path': iconPath,
    'program_count': programCount,
  };

  String encode() => jsonEncode(toJson());

  static TunarrChannel decode(String raw) =>
      TunarrChannel.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}

/// The `path` inside Tunarr's nested `icon` object, or null when there is none.
///
/// Defensive by design: the icon arrives as either `{path: "…"}` or a bare
/// string, and every channel surface (`/api/channels`, `/api/guide/channels`,
/// `/api/channels/all/lineups`) uses the same shape.
String? readTunarrIconPath(Object? icon) {
  if (icon is String) return icon.isEmpty ? null : icon;
  if (icon is Map) {
    final path = icon['path'];
    if (path is String && path.isNotEmpty) return path;
  }
  return null;
}

/// Turns a channel's `icon.path` into a URL the client can actually load.
///
/// Tunarr stores a pasted image URL verbatim and an uploaded file as an absolute
/// URL under its own `/images/uploads/…` path (`server/src/util/iconUtil.ts`).
/// Only the gate is reachable from the client, so any `/images/…` path is
/// re-pointed at the gate ([baseUrl]); a third-party URL is used as-is. Returns
/// null when there is no icon — the UI then keeps its plain channel label.
String? resolveTunarrIconUrl(String? iconPath, String? baseUrl) {
  final raw = iconPath?.trim();
  if (raw == null || raw.isEmpty) return null;

  final Uri parsed;
  try {
    parsed = Uri.parse(raw);
  } on FormatException {
    return null;
  }

  final base = baseUrl?.trim().replaceAll(RegExp(r'/+$'), '') ?? '';
  if (parsed.path.startsWith('/images/')) {
    if (base.isEmpty) return null;
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    return '$base${parsed.path}$query';
  }
  // An externally hosted logo (what the Tunarr UI calls "provide a URL").
  if (parsed.hasScheme) return raw;
  if (base.isEmpty) return null;
  return '$base$raw';
}
