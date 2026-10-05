import 'dart:convert';

/// An authenticated Tunarr-gate session for one profile: the gate base URL,
/// the account it mapped to, and the libraries that account can see.
///
/// **The Plex token is deliberately never stored here.** Sign-in exchanges a
/// Plex account token for a gate session, but the token itself is read live
/// from the profile's connection at request time and replayed as the
/// `X-Plex-Token` header — exactly the way [SeerrSession] reads its Plex token
/// at re-auth time and never copies it into the session. Persisting it would
/// put a long-lived Plex credential in the plaintext preference store for no
/// gain: losing the session only costs one re-sign-in, and the profile's
/// connection still owns the token.
class TunarrSession {
  final String baseUrl;

  /// Whether the gate granted access. Always true for a session produced by a
  /// successful sign-in; carried so a stored session self-describes.
  final bool granted;
  final String username;
  final String email;

  /// Plex account id the gate mapped the token to.
  final int plexId;

  /// Library sections the account can see (Plex section titles).
  final List<String> sections;

  /// Instance `applicationTitle`-style label; the gate currently sends none,
  /// so this is empty and exists for forward compatibility.
  final String instanceLabel;

  /// Unix seconds, matching `SeerrSession.createdAt`.
  final int createdAt;

  const TunarrSession({
    required this.baseUrl,
    required this.granted,
    required this.username,
    required this.email,
    required this.plexId,
    required this.sections,
    this.instanceLabel = '',
    required this.createdAt,
  });

  /// Builds a session from the gate's `POST /api/v1/auth/plex` success body
  /// (`{"granted":true,"username":…,"email":…,"plexId":…,"sections":[…]}`).
  ///
  /// The wire body uses camelCase `plexId`; the persisted JSON below uses
  /// snake_case, so this factory is the only place that reads the wire shape.
  /// The Plex token is never read from [json] — see the class note.
  factory TunarrSession.fromSignIn({
    required String baseUrl,
    required Map<String, dynamic> json,
    required int createdAt,
  }) => TunarrSession(
    baseUrl: baseUrl,
    granted: json['granted'] == true,
    username: json['username'] as String? ?? '',
    email: json['email'] as String? ?? '',
    plexId: (json['plexId'] as num?)?.toInt() ?? 0,
    sections: (json['sections'] as List?)?.cast<String>() ?? const <String>[],
    createdAt: createdAt,
  );

  TunarrSession copyWith({
    bool? granted,
    String? username,
    String? email,
    int? plexId,
    List<String>? sections,
    String? instanceLabel,
  }) => TunarrSession(
    baseUrl: baseUrl,
    granted: granted ?? this.granted,
    username: username ?? this.username,
    email: email ?? this.email,
    plexId: plexId ?? this.plexId,
    sections: sections ?? this.sections,
    instanceLabel: instanceLabel ?? this.instanceLabel,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'base_url': baseUrl,
    'granted': granted,
    'username': username,
    'email': email,
    'plex_id': plexId,
    'sections': sections,
    'instance_label': instanceLabel,
    'created_at': createdAt,
  };

  factory TunarrSession.fromJson(Map<String, Object?> json) => TunarrSession(
    baseUrl: json['base_url'] as String,
    granted: json['granted'] as bool? ?? false,
    username: json['username'] as String? ?? '',
    email: json['email'] as String? ?? '',
    plexId: (json['plex_id'] as num?)?.toInt() ?? 0,
    sections: (json['sections'] as List?)?.cast<String>() ?? const <String>[],
    instanceLabel: json['instance_label'] as String? ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );

  String encode() => jsonEncode(toJson());

  static TunarrSession decode(String raw) =>
      TunarrSession.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}
