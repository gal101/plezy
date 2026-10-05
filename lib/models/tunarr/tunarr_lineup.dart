import 'dart:convert';

import 'tunarr_channel.dart';

/// A channel from `GET /api/channels/all/lineups`, carrying its time slots.
///
/// The wire key for the slot list is `programs`; it is exposed as [slots] and
/// [fromJson] also accepts `slots` so [decode] round-trips its own output.
class TunarrLineupChannel {
  final String id;
  final String name;
  final String number;

  /// Path part of the nested `icon` object, when present — the channel logo.
  final String? iconPath;

  final List<TunarrLineupSlot> slots;

  const TunarrLineupChannel({
    required this.id,
    required this.name,
    required this.number,
    this.iconPath,
    this.slots = const <TunarrLineupSlot>[],
  });

  factory TunarrLineupChannel.fromJson(Map<String, Object?> json) {
    final raw = json['slots'] ?? json['programs'];
    return TunarrLineupChannel(
      id: json['id']?.toString() ?? '',
      name: json['name'] as String? ?? '',
      number: json['number']?.toString() ?? '',
      iconPath: readTunarrIconPath(json['icon']) ?? (json['icon_path'] as String?),
      slots: raw is List
          ? raw.whereType<Map>().map((e) => TunarrLineupSlot.fromJson(e.cast<String, Object?>())).toList()
          : const <TunarrLineupSlot>[],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'number': number,
    'icon_path': iconPath,
    'slots': slots.map((s) => s.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  static TunarrLineupChannel decode(String raw) =>
      TunarrLineupChannel.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}

/// One scheduled slot on a lineup channel.
///
/// The program body is **nested** under `program` on the wire — reading it
/// flat returns null, which is the exact failure `.program.externalId` guards
/// against.
class TunarrLineupSlot {
  final String id;
  final int start;
  final int stop;
  final int duration;
  final String type;
  final TunarrProgram? program;

  const TunarrLineupSlot({
    required this.id,
    required this.start,
    required this.stop,
    required this.duration,
    required this.type,
    this.program,
  });

  /// True only for real launchable content — never for `redirect`/`flex`.
  bool get isPlayable => type == 'content' || type == 'custom';

  factory TunarrLineupSlot.fromJson(Map<String, Object?> json) => TunarrLineupSlot(
    id: json['id']?.toString() ?? '',
    start: (json['start'] as num?)?.toInt() ?? 0,
    stop: (json['stop'] as num?)?.toInt() ?? 0,
    duration: (json['duration'] as num?)?.toInt() ?? 0,
    type: json['type'] as String? ?? '',
    program: TunarrProgram.tryParse(json['program']),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'start': start,
    'stop': stop,
    'duration': duration,
    'type': type,
    'program': program?.toJson(),
  };
}

/// The `TerminalProgram` body nested under a slot's `program`.
///
/// [externalId] is the Plex rating key as a string (e.g. `"466"`), the value
/// the native-playback resolve step needs.
class TunarrProgram {
  final String? title;
  final String? externalId;
  final String? summary;
  final String? type;
  final int? year;
  final int? durationMs;

  const TunarrProgram({
    this.title,
    this.externalId,
    this.summary,
    this.type,
    this.year,
    this.durationMs,
  });

  static TunarrProgram? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, Object?>();
    return TunarrProgram(
      title: json['title'] as String?,
      externalId: json['externalId']?.toString() ?? (json['external_id']?.toString()),
      summary: json['summary'] as String?,
      type: json['type'] as String?,
      year: (json['year'] as num?)?.toInt(),
      durationMs: ((json['durationMs'] ?? json['duration_ms']) as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'external_id': externalId,
    'summary': summary,
    'type': type,
    'year': year,
    'duration_ms': durationMs,
  };
}
