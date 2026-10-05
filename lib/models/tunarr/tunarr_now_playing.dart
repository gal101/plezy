import 'dart:convert';

/// The gate's answer to `GET /api/channels/{id}/native-playback`:
/// `{"serverTimeMs":…,"current":{…}|null,"next":{…}|null}`.
///
/// There is deliberately no `externalId` here — the Plex rating key lives on
/// the program endpoint and is resolved separately by
/// `TunarrClient.fetchPlexRatingKey`.
class TunarrNowPlaying {
  final int serverTimeMs;
  final TunarrPlaybackItem? current;
  final TunarrPlaybackItem? next;

  const TunarrNowPlaying({
    required this.serverTimeMs,
    this.current,
    this.next,
  });

  factory TunarrNowPlaying.fromJson(Map<String, Object?> json) => TunarrNowPlaying(
    serverTimeMs: (json['serverTimeMs'] as num?)?.toInt() ?? 0,
    current: TunarrPlaybackItem.tryParse(json['current']),
    next: TunarrPlaybackItem.tryParse(json['next']),
  );

  Map<String, Object?> toJson() => {
    'server_time_ms': serverTimeMs,
    'current': current?.toJson(),
    'next': next?.toJson(),
  };

  String encode() => jsonEncode(toJson());

  static TunarrNowPlaying decode(String raw) =>
      TunarrNowPlaying.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}

/// One side (`current` or `next`) of a native-playback answer.
///
/// `redirect` and `flex` are Tunarr's non-content filler types: nothing to
/// launch, so [isPlayable] is false for them even though the slot exists.
class TunarrPlaybackItem {
  final String programId;
  final int seekOffsetMs;
  final int remainingMs;
  final int itemStartedAtMs;
  final String? title;
  final String? summary;
  final String type;

  const TunarrPlaybackItem({
    required this.programId,
    required this.seekOffsetMs,
    required this.remainingMs,
    required this.itemStartedAtMs,
    this.title,
    this.summary,
    required this.type,
  });

  /// True only for real launchable content — never for `redirect`/`flex`.
  bool get isPlayable => type == 'content' || type == 'custom';

  static TunarrPlaybackItem? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, Object?>();
    return TunarrPlaybackItem(
      programId: json['programId']?.toString() ?? '',
      seekOffsetMs: (json['seekOffsetMs'] as num?)?.toInt() ?? 0,
      remainingMs: (json['remainingMs'] as num?)?.toInt() ?? 0,
      itemStartedAtMs: (json['itemStartedAtMs'] as num?)?.toInt() ?? 0,
      title: json['title'] as String?,
      summary: json['summary'] as String?,
      type: json['type'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'program_id': programId,
    'seek_offset_ms': seekOffsetMs,
    'remaining_ms': remainingMs,
    'item_started_at_ms': itemStartedAtMs,
    'title': title,
    'summary': summary,
    'type': type,
  };
}
