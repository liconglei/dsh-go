import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('pre-emptive Authorization reaches every HTTP path', () async {
    const authHeader = 'Basic dXNlcjpwYXNz';
    final seen = <String, String?>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((request) async {
      seen[request.uri.path] = request.headers.value(HttpHeaders.authorizationHeader);
      request.response.statusCode = request.uri.path == '/api/remote.mux' ? 401 : 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
    final client = await DshClient.connect(baseUri: base, authorization: authHeader, startMux: false);
    addTearDown(() async {
      await client.close();
      await sub.cancel();
      await server.close(force: true);
    });

    await client.connection.get('/probe');
    await client.connection.postJson('/api/x', const {'a': 1});
    await client.connection.getBounded('/binary', maxBytes: 1024);
    await expectLater(client.connection.connectWebSocket('/api/remote.mux'), throwsA(isA<DshException>()));

    expect(seen['/probe'], authHeader);
    expect(seen['/api/x'], authHeader);
    expect(seen['/binary'], authHeader);
    expect(seen['/api/remote.mux'], authHeader);
  });

  test('a host without authorization still needs a token or cookie', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
    await expectLater(
      DshClient.connect(baseUri: base, startMux: false),
      throwsA(isA<ArgumentError>()),
    );
  });
}
