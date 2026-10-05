import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/tunarr/tunarr_auth_service.dart';
import 'package:plezy/services/tunarr/tunarr_exceptions.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

TunarrAuthService _auth(http.Response Function(http.Request) handler) =>
    TunarrAuthService(httpClientFactory: () => MockClient((request) async => handler(request)));

void main() {
  group('TunarrAuthService.signIn', () {
    test('parses granted/username/sections from the gate body', () async {
      late http.Request seen;
      final auth = _auth((request) {
        seen = request;
        return _json({
          'granted': true,
          'username': 'alice',
          'email': 'alice@example.com',
          'plexId': 123,
          'sections': ['Movies', 'TV Shows'],
        });
      });

      final session = await auth.signIn(baseUrl: ' https://gate.example.com// ', plexToken: 'plex-token');

      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://gate.example.com/api/v1/auth/plex');
      expect(jsonDecode(seen.body), {'authToken': 'plex-token'});
      expect(session.baseUrl, 'https://gate.example.com');
      expect(session.granted, isTrue);
      expect(session.username, 'alice');
      expect(session.email, 'alice@example.com');
      expect(session.plexId, 123);
      expect(session.sections, ['Movies', 'TV Shows']);
      expect(session.createdAt, greaterThan(0));
    });

    test('401 plex-401 maps to TunarrAuthException with the token-rejected text', () async {
      final auth = _auth((_) => _json({'error': 'plex-401'}, status: 401));

      await expectLater(
        auth.signIn(baseUrl: 'https://gate.example.com', plexToken: 'stale'),
        throwsA(isA<TunarrAuthException>().having((e) => e.display, 'display', contains('rejected'))),
      );
    });

    test('no-libraries maps distinctly from plex-401', () async {
      final auth = _auth((_) => _json({'error': 'no-libraries'}, status: 401));

      late TunarrAuthException failure;
      try {
        await auth.signIn(baseUrl: 'https://gate.example.com', plexToken: 'tok');
        fail('expected a TunarrAuthException');
      } on TunarrAuthException catch (e) {
        failure = e;
      }

      expect(failure.display, isNotNull);
      expect(failure.display, contains('No library'));
      expect(failure.message, contains('No libraries'));
    });

    test('502 tunarr-unreachable maps to TunarrProxyException', () async {
      final auth = _auth((_) => _json({'error': 'tunarr-unreachable'}, status: 502));

      await expectLater(
        auth.signIn(baseUrl: 'https://gate.example.com', plexToken: 'tok'),
        throwsA(isA<TunarrProxyException>()),
      );
    });

    test('an unrecognized non-200 maps to TunarrApiException', () async {
      final auth = _auth((_) => _json({'error': 'something-else'}, status: 500));

      await expectLater(
        auth.signIn(baseUrl: 'https://gate.example.com', plexToken: 'tok'),
        throwsA(isA<TunarrApiException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('an empty token is rejected before any request', () async {
      var called = false;
      final auth = _auth((_) {
        called = true;
        return _json({});
      });

      await expectLater(
        auth.signIn(baseUrl: 'https://gate.example.com', plexToken: '  '),
        throwsA(isA<TunarrAuthException>()),
      );
      expect(called, isFalse);
    });
  });
}
