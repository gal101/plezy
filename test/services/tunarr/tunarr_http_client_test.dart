import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/tunarr/tunarr_http_client.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('TunarrHttpClient', () {
    test('normalizes whitespace and trailing slashes off the base URL', () {
      expect(TunarrHttpClient.normalizeBaseUrl(' https://gate.example.com// '), 'https://gate.example.com');
    });

    test('sends X-Plex-Token and never a Cookie', () async {
      late http.Request seen;
      final client = TunarrHttpClient(
        baseUrl: 'https://gate.example.com',
        plexToken: 'plex-token',
        httpClient: MockClient((request) async {
          seen = request;
          return _json({'ok': true});
        }),
      );

      await client.send('GET', '/api/channels', apiScoped: false);

      expect(seen.headers['X-Plex-Token'], 'plex-token');
      expect(seen.headers.containsKey('Cookie'), isFalse);
      expect(seen.url.toString(), 'https://gate.example.com/api/channels');
      client.dispose();
    });

    test('does not send a token on unauthenticated requests', () async {
      late http.Request seen;
      final client = TunarrHttpClient(
        baseUrl: 'https://gate.example.com',
        plexToken: 'plex-token',
        httpClient: MockClient((request) async {
          seen = request;
          return _json({});
        }),
      );

      await client.send('POST', '/auth/plex', body: {'authToken': 'plex-token'}, authenticated: false);
      expect(seen.url.toString(), 'https://gate.example.com/api/v1/auth/plex');
      expect(seen.headers.containsKey('X-Plex-Token'), isFalse);
      expect(seen.headers['Content-Type'], 'application/json');
      client.dispose();
    });

    test('classifies a JSON 401 as the gate and a non-JSON 401 as an intermediary', () {
      final gate = TunarrResponse(http.Response(jsonEncode({'error': 'plex-401'}), 401), {'error': 'plex-401'});
      final proxy = TunarrResponse(http.Response('<html>login</html>', 401), null);

      expect(TunarrHttpClient.classify(gate), TunarrRejection.gate);
      expect(TunarrHttpClient.classify(proxy), TunarrRejection.intermediary);
    });

    test('consults the token supplier per request and picks up a changed token', () async {
      var calls = 0;
      final tokens = <String>['token-one', 'token-two'];
      final seen = <String?>[];
      final client = TunarrHttpClient(
        baseUrl: 'https://gate.example.com',
        plexTokenSupplier: () async {
          final token = tokens[calls.clamp(0, tokens.length - 1)];
          calls++;
          return token;
        },
        httpClient: MockClient((request) async {
          seen.add(request.headers['X-Plex-Token']);
          return _json({});
        }),
      );

      await client.send('GET', '/api/channels', apiScoped: false);
      await client.send('GET', '/api/channels', apiScoped: false);

      expect(calls, 2, reason: 'supplier is consulted once per request');
      expect(seen, ['token-one', 'token-two']);
      client.dispose();
    });

    test('an explicit plexToken wins over the supplier', () async {
      var supplierCalls = 0;
      late http.Request seen;
      final client = TunarrHttpClient(
        baseUrl: 'https://gate.example.com',
        plexToken: 'explicit',
        plexTokenSupplier: () async {
          supplierCalls++;
          return 'supplied';
        },
        httpClient: MockClient((request) async {
          seen = request;
          return _json({});
        }),
      );

      await client.send('GET', '/api/channels', apiScoped: false);

      expect(seen.headers['X-Plex-Token'], 'explicit');
      expect(supplierCalls, 0);
      client.dispose();
    });

    test('a null supplier means no X-Plex-Token header rather than a crash', () async {
      late http.Request seen;
      final client = TunarrHttpClient(
        baseUrl: 'https://gate.example.com',
        httpClient: MockClient((request) async {
          seen = request;
          return _json({});
        }),
      );

      await client.send('GET', '/api/channels', apiScoped: false);

      expect(seen.headers.containsKey('X-Plex-Token'), isFalse);
      client.dispose();
    });
  });
}
