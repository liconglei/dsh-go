import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import '../ssh/ssh_host_config.dart';

/// A full `dsh web` URL typed by the person. Credentials must never be part of
/// the URL: they would land in plain-text preferences, and the client refuses
/// URLs with userinfo anyway. Cleartext HTTP is limited to loopback / private
/// hosts because Basic is only base64, not encryption.
bool isValidBasicUrl(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  if (host.startsWith('10.') || host.startsWith('192.168.')) return true;
  if (host.endsWith('.local') || host.endsWith('.test')) return true;
  final parts = host.split('.');
  if (parts.length == 4 && parts[0] == '172') {
    final second = int.tryParse(parts[1]);
    if (second != null && second >= 16 && second <= 31) return true;
  }
  return false;
}

/// A remote `dsh web` reached directly over HTTP(S) with a pre-emptive Basic
/// Authorization header, with no SSH tunnel and no relay.
///
/// The transport is HTTP: it dials [address] itself and takes the account from
/// [loadPassword], so nothing here knows about SSH, tunnels or host keys. The
/// saved config is still an [SshHostConfig] with [SshDshMode.httpDirect],
/// because that record is the app's *identity* for a self-hosted host (which is
/// what host switching, persistence and diagnostics key on) — not a statement
/// about the wire. Splitting the identity would touch every `HostKind` branch
/// and the stored `HostRef` for no behaviour gain.
class HttpHostLink implements HostLink {
  HttpHostLink({
    required this.config,
    required this.loadPassword,
    Stream<void>? kicks,
    Backoff? backoff,
  }) : _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  final SshHostConfig config;

  /// The account's password, read from secure storage on each attempt so a
  /// changed password applies on the next reconnect without a restart.
  final Future<String?> Function() loadPassword;
  final Backoff _backoff;

  /// The Host's own address: the full URL the person typed.
  Uri get address => Uri.parse(config.host.trim());

  /// The account the Host's password belongs to.
  String get user => config.user;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _published = false;

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  void _emit(HostLinkStatus next) {
    if (_closed) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open({bool force = false}) {
    if (_closed) return Future.error(StateError('link closed'));
    if (!force) {
      final client = currentClient;
      if (client != null) return Future.value(client);
    }
    return _opening ??= _run().whenComplete(() => _opening = null);
  }

  Future<DshClient> _run() async {
    _backoff.reset();
    var last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
    while (!_closed) {
      try {
        return await _connectOnce();
      } on HostLinkError catch (e) {
        last = e;
      } catch (e) {
        // A 401 means the stored password is wrong. Stop retrying: editing the
        // host and tapping retry re-reads the secret from the store.
        final badCredentials = e is DshHttpException && e.isUnauthorized;
        last = HostLinkError(
          badCredentials ? HostLinkErrorKind.authFailed : HostLinkErrorKind.other,
          badCredentials ? appL10n.remoteErrUsernamePassword : appL10n.commonConnectionFailed,
          detail: badCredentials ? null : e.runtimeType.toString(),
          retryable: !badCredentials,
        );
      }
      if (_closed || !last.retryable || _backoff.exhausted) break;
      final delay = _backoff.next();
      // A retry running behind a working client is invisible: the app is still
      // talking to the Host, so it must not read 重新连接中 on screen.
      if (_client == null) {
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
      }
      await _delay.wait(delay);
    }
    // Out of retries with a client that still works: keep it instead of
    // reporting a failure the person cannot see.
    final existing = _client;
    if (existing != null) return existing;
    _emit(HostLinkStatus(HostLinkPhase.failed, error: last));
    throw last;
  }

  Future<DshClient> _connectOnce() async {
    // Same rule as the login step: never regress a working link to 连接中.
    if (_client == null) _emit(_status.withStep(HostLinkStep.connect));
    final password = await loadPassword();
    if (password == null || password.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteSshPasswordRequired);
    }
    if (!isValidBasicUrl(config.host)) {
      throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteHttpDirectUrlInvalid);
    }
    final base = address;
    // Direct HTTP(S) reaches the real host name, so keep the natural Host
    // header. Overriding it to loopback (needed only for an SSH tunnel, where
    // the socket lands on 127.0.0.1) makes a reverse proxy route to the wrong
    // backend — e.g. Host: 127.0.0.1:22 returns 502 from an nginx basic-auth
    // proxy. The upstream dsh host must trust this name (--trusted-host) for
    // its own Host fence; that is a server-side setting.
    final header = 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
    // A client that still serves the app is only replaced after the new one is
    // ready. Reporting 'connecting / login' while the old one works is what
    // left the header on 「登录…」 with a perfectly usable session behind it.
    final previous = _client;
    if (previous == null) _emit(_status.withStep(HostLinkStep.login));
    // A Basic proxy usually logs in to the Host on our behalf: `GET /` answers
    // 303 with `Set-Cookie: dsh-auth-…`. The Host still fences its own routes
    // (notably `/api/remote.mux`) on that cookie, so sending only the Basic
    // header yields a 401 that reads like a rejected password. Fetch the cookie
    // and carry both: the proxy keeps asking for Basic on every request, the
    // Host needs the cookie next to it.
    final cookie = await _fetchAuthCookie(base, header);
    final client = await DshClient.connect(
      baseUri: base,
      authorization: header,
      cookie: cookie,
    );
    if (_closed) {
      await client.close();
      throw StateError('link closed');
    }
    _client = client;
    if (previous != null) unawaited(previous.close().catchError((_) {}));
    _emit(HostLinkStatus(HostLinkPhase.connected, completed: HostLinkStep.values.toSet()));
    if (_published) _clients.add(client);
    _published = true;
    return client;
  }

  /// Exchanges the Basic credential for the Host's own session cookie.
  ///
  /// Returns null when the deployment needs no cookie: a plain `dsh web` behind
  /// a Basic proxy that injects its launch token already answers without one.
  Future<DshCookie?> _fetchAuthCookie(Uri base, String authorization) async {
    final http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 5);
    try {
      final request = await http.getUrl(base);
      // The cookie rides on the redirect itself; following it would land on the
      // Host's HTML shell instead.
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
      final response = await request.close().timeout(const Duration(seconds: 20));
      await response.drain<void>();
      if (response.statusCode == HttpStatus.unauthorized) {
        throw const DshHttpException(HttpStatus.unauthorized, 'basic authorization rejected');
      }
      for (final raw in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
        final cookie = _parseAuthCookie(raw, base.authority);
        if (cookie != null) return cookie;
      }
      return null;
    } finally {
      http.close(force: true);
    }
  }

  /// `dsh-auth-<hash>=v1.<payload>.<signature>; Max-Age=…; Path=/; HttpOnly…`
  static DshCookie? _parseAuthCookie(String raw, String authority) {
    final parts = raw.split(';');
    final pair = parts.first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) return null;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (!name.startsWith('dsh-auth-') || value.isEmpty) return null;
    DateTime? expiresAt;
    for (final attribute in parts.skip(1)) {
      final text = attribute.trim();
      if (text.toLowerCase().startsWith('max-age=')) {
        final seconds = int.tryParse(text.substring('max-age='.length).trim());
        if (seconds != null) expiresAt = DateTime.now().add(Duration(seconds: seconds));
      }
    }
    return DshCookie(name: name, value: value, authority: authority, expiresAt: expiresAt);
  }

  @override
  void kick() {
    if (_status.phase == HostLinkPhase.reconnecting) {
      _delay.skip();
      return;
    }
    if (_status.phase == HostLinkPhase.failed && (_status.error?.retryable ?? false)) retry();
  }

  @override
  void retry() {
    if (_closed || _status.isBusy) return;
    // Keep the current client until its replacement is ready: dropping it here
    // is what made a manual/automatic retry look like a dead link.
    unawaited(open(force: true).then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
