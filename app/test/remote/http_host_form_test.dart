// The HTTP host kind: its own entry, its own page, and a password that never
// lands in preferences.

import 'dart:convert';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_gate.dart';
import 'package:dsh_app/ui/remote/http_host_form.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';

const _httpHost = SshHostConfig(
  id: 'ssh-http1',
  name: 'nas-dsh',
  host: 'https://dsh.example.com',
  user: 'lcl',
  auth: SshAuthMethod.password,
  dshMode: SshDshMode.httpDirect,
);

const _sshHost = SshHostConfig(id: 'ssh-lab', name: '实验室服务器', host: 'lab.example.com', user: 'root');

void main() {
  late MemorySecretStore secrets;
  late FakeRelayBackend relay;

  setUp(() {
    secrets = MemorySecretStore();
    relay = FakeRelayBackend();
    // Old builds kept HTTP hosts in the SSH list; loading must move them.
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([_sshHost.toJson(), _httpHost.toJson()]),
    });
  });

  List<Override> overrides() => [
    secretStoreProvider.overrideWithValue(secrets),
    networkKicksProvider.overrideWithValue(const Stream.empty()),
    relayBackendProvider.overrideWithValue(relay),
  ];

  Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> frames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> settleHosts(WidgetTester tester, ProviderContainer container) async {
    for (var i = 0; i < 60; i++) {
      if (container.read(hostsProvider).loaded) return;
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  test('HTTP 主机的标题写 HTTP，不再写 SSH', () {
    expect(hostLabel(HostKind.http, 'nas-dsh'), 'nas-dsh · HTTP');
    expect(hostLabel(HostKind.ssh, 'nas-dsh'), 'nas-dsh · SSH');
  });

  test('一条存储两个视图：SSH 主机与 HTTP 主机不会互相串台', () async {
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    await container.read(hostsProvider.notifier).ready;
    final state = container.read(hostsProvider);
    expect(state.sshHosts.map((h) => h.id), ['ssh-lab']);
    expect(state.httpHosts.map((h) => h.id), ['ssh-http1']);
    expect(state.httpById('ssh-http1')?.name, 'nas-dsh');
    expect(state.sshById('ssh-http1'), isNull);
    expect(state.byRef(const HostRef.http('ssh-http1'))?.id, 'ssh-http1');
    expect(state.byRef(const HostRef.ssh('ssh-http1')), isNull);
  });

  test('旧 active_host（kind ssh）指向 HTTP 主机时，恢复后升级成 http', () async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([_httpHost.toJson()]),
      ActiveHostController.prefsKey: const HostRef.ssh('ssh-http1').encode(),
    });
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    await container.read(activeHostProvider.notifier).ready;
    expect(container.read(activeHostProvider), const HostRef.http('ssh-http1'));
  });

  test('HostRef 往返：http 是一种独立的主机身份', () {
    const ref = HostRef.http('abc');
    expect(HostRef.decode(ref.encode()), ref);
    expect(HostRef.decode(ref.encode()).kind, HostKind.http);
  });

  testWidgets('网页模式：HTTP 主机用自己的地址，不需要隧道端口', (tester) async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([_sshHost.toJson(), _httpHost.toJson()]),
      ActiveHostController.prefsKey: const HostRef.http('ssh-http1').encode(),
    });
    final container = await pump(tester, const SizedBox());
    await settleHosts(tester, container);
    for (var i = 0; i < 40 && container.read(activeHostProvider).isLocal; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(container.read(activeHostProvider), const HostRef.http('ssh-http1'));
    final access = container.read(dshWebAccessProvider);
    expect(access, isA<HttpDshWeb>());
    final web = access as HttpDshWeb;
    expect(web.url, Uri.parse('https://dsh.example.com'));
    expect(web.hostId, _httpHost.id);
    // The island loads from the same address; only SSH hosts need a tunnel.
    expect(container.read(islandHostUrlProvider(const HostRef.http('ssh-http1'))), Uri.parse('https://dsh.example.com'));
  });

  testWidgets('HTTP 主机单独成段，不和 SSH 主机混在一起', (tester) async {
    final container = await pump(tester, const RemoteScreen());
    await settleHosts(tester, container);
    await frames(tester, 3);
    expect(find.text('SSH 主机'), findsOneWidget);
    // The HTTP section sits below the SSH one; the list builds lazily.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await frames(tester);
    expect(find.text('HTTP 主机'), findsOneWidget);
    expect(find.text('添加 HTTP 主机'), findsOneWidget);
    expect(find.text('nas-dsh'), findsOneWidget);
  });

  testWidgets('保存 HTTP 主机：进自己的列表，密码进安全存储', (tester) async {
    final c = await pump(tester, const HttpHostFormPage());
    await settleHosts(tester, c);
    await tester.enterText(find.byType(TextField).at(0), '办公网关');
    await tester.enterText(find.byType(TextField).at(1), 'https://dsh.example.com');
    await tester.enterText(find.byType(TextField).at(2), 'lcl');
    await tester.enterText(find.byType(TextField).at(3), '4bab-9aab');
    await frames(tester);
    await tester.tap(find.text('保存'));
    await frames(tester);
    final state = c.read(hostsProvider);
    final saved = state.httpHosts.firstWhere((h) => h.name == '办公网关');
    expect(state.sshHosts.where((h) => h.name == '办公网关'), isEmpty);
    expect(saved.host, 'https://dsh.example.com');
    expect(saved.user, 'lcl');
    expect(saved.auth, SshAuthMethod.password);
    expect(secrets.values[SshSecrets.passwordKey(saved.id)], '4bab-9aab');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(HostsController.prefsKey), isNot(contains('4bab-9aab')));
  });

  testWidgets('网址不是完整 URL 时给出提示，且不保存', (tester) async {
    final c = await pump(tester, const HttpHostFormPage());
    await settleHosts(tester, c);
    await tester.enterText(find.byType(TextField).at(1), 'dsh.example.com');
    await tester.enterText(find.byType(TextField).at(2), 'lcl');
    await tester.enterText(find.byType(TextField).at(3), 'pw');
    await frames(tester);
    await tester.tap(find.text('保存'));
    await frames(tester);
    expect(find.textContaining('请填写完整的 https:// 地址'), findsOneWidget);
  });

  testWidgets('编辑 HTTP 主机：页面回填网址与账号，密码从安全存储读回', (tester) async {
    secrets.values[SshSecrets.passwordKey(_httpHost.id)] = 'stored-pw';
    final c = await pump(tester, const HttpHostFormPage(existing: _httpHost));
    await settleHosts(tester, c);
    await frames(tester, 4);
    // Assert on the controllers: the hint keeps the same string in the tree.
    String textAt(int index) => tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;
    expect(textAt(1), 'https://dsh.example.com');
    expect(textAt(2), 'lcl');
    expect(textAt(3), 'stored-pw');
  });
}
