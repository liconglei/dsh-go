// A webview_flutter platform implementation backed by Edge WebView2 on Windows.
//
// Why this exists: webview_flutter 4.x builds entirely on the public
// webview_flutter_platform_interface. Android/iOS/macOS ship an implementation;
// Windows does not. The app's nine WebView business files all construct a plain
// `WebViewController()` with no explicit platform, so registering this one
// implementation globally makes them work on Windows with zero upstream edits.
//
// Only files under lib/desktop/ are new, so a git rebase of upstream mobile
// changes never conflicts with this file. See main_desktop.dart for registration.
//
// The underlying package `webview_flutter_windows` exposes its own independent
// API (WebviewController / Webview widget). This adapter translates the
// webview_flutter platform calls into that API.

// The app only depends on webview_flutter; the platform interface is transitive.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart' as win;

/// Register in the desktop entry point before runApp:
/// `WebViewPlatform.instance = WindowsWebViewPlatform();`
class WindowsWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      WindowsWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      WindowsNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      WindowsWebViewWidget(params);
}

/// Translates webview_flutter controller calls into a WebView2 controller.
///
/// Creation is lazy: the native controller is initialized once, on the first
/// call that needs it, and every call awaits that same future. This matches
/// webview_flutter's contract where a freshly built controller is usable
/// immediately and initializing happens underneath.
class WindowsWebViewController extends PlatformWebViewController {
  WindowsWebViewController(super.params) : super.implementation();

  final win.WebviewController _native = win.WebviewController();
  Future<void>? _initializing;

  /// The native controller, exposed only to [WindowsWebViewWidget].
  win.WebviewController get native => _native;

  WindowsNavigationDelegate? _delegate;
  String? _currentUrl;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// Credentials the app offered through `onHttpAuthRequest`.
  ///
  /// webview_flutter_windows has no BasicAuthenticationRequested hook, so a
  /// WebView2 401 used to end as `validAuthenticationCredentialsRequired`.
  /// Replay the app's answer as URL user info on the navigation itself.
  WebViewCredential? _basicCredential;
  String? _basicCredentialHost;

  Future<void> get _ready => _initializing ??= _native.initialize();

  /// Called by the widget on first build so initialization always starts,
  /// even if the business code only called no-op setters before loading.
  void startInitialization() => _ready;

  /// Wires native streams into the webview_flutter navigation callbacks.
  /// Called once by [setPlatformNavigationDelegate] after the delegate exists.
  void _bindDelegate() {
    final delegate = _delegate;
    if (delegate == null || _bound) return;
    _bound = true;

    _native.url.listen((rawUrl) {
      // Basic credentials are replayed in the URL (see [_withBasicAuth]).
      // Never hand them back to business code or the "open in browser" button.
      final url = _withoutUserInfo(rawUrl);
      _currentUrl = url;
      delegate.onUrlChange?.call(UrlChange(url: url));
    });
    _native.loadingState.listen((state) {
      switch (state) {
        case win.LoadingState.loading:
          final url = _currentUrl ?? '';
          delegate.onPageStarted?.call(url);
          delegate.onProgress?.call(10);
        case win.LoadingState.navigationCompleted:
          final url = _currentUrl ?? '';
          delegate.onProgress?.call(100);
          delegate.onPageFinished?.call(url);
        case win.LoadingState.none:
          break;
      }
    });
    _native.onLoadError.listen((status) {
      // A navigation we prevented ourselves (e.g. a link opened externally)
      // is not a load failure.
      if (status == win.WebErrorStatus.operationCanceled) return;
      delegate.onWebResourceError?.call(
        WebResourceError(
          errorCode: status.index,
          description: _describe(status),
          errorType: _errorType(status),
          isForMainFrame: true,
          url: _currentUrl,
        ),
      );
    });
    _native.historyChanged.listen((history) {
      _canGoBack = history.canGoBack;
      _canGoForward = history.canGoForward;
    });
  }

  bool _bound = false;

  /// Replays the app's HTTP Basic answer on the navigation URL.
  ///
  /// Business code supplies credentials through `onHttpAuthRequest`, which
  /// WebView2 never fires here: the underlying package has no
  /// BasicAuthenticationRequested hook. A synthetic request asks the same
  /// callback for its answer before the first load, and Chromium turns the
  /// URL's user info into the Basic Authorization header. The original URL is
  /// left untouched everywhere else, including JS `location`.
  void _askForBasicCredentials(Uri uri) {
    final callback = _delegate?.onHttpAuthRequest;
    if (callback == null || uri.userInfo.isNotEmpty) return;
    WebViewCredential? answer;
    try {
      callback(
        HttpAuthRequest(
          onProceed: (credential) => answer = credential,
          onCancel: () {},
          host: uri.host,
        ),
      );
    } catch (_) {
      // A callback that needs native challenge fields cannot answer here.
    }
    if (answer case final credential?) {
      if (credential.user.isNotEmpty || credential.password.isNotEmpty) {
        _basicCredential = credential;
        _basicCredentialHost = uri.host;
      } else {
        _basicCredential = null;
        _basicCredentialHost = null;
      }
    }
  }

  Uri _withBasicAuth(Uri uri) {
    final credential = _basicCredential;
    final host = _basicCredentialHost;
    if (credential == null || host != uri.host || uri.userInfo.isNotEmpty) return uri;
    return uri.replace(
      userInfo: '${Uri.encodeComponent(credential.user)}:${Uri.encodeComponent(credential.password)}',
    );
  }

  static String _withoutUserInfo(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.userInfo.isEmpty) return raw;
    return uri.replace(userInfo: '').toString();
  }

  static WebResourceErrorType _errorType(win.WebErrorStatus status) => switch (status) {
    win.WebErrorStatus.validAuthenticationCredentialsRequired => WebResourceErrorType.authentication,
    win.WebErrorStatus.validProxyAuthenticationRequired => WebResourceErrorType.proxyAuthentication,
    win.WebErrorStatus.hostNameNotResolved => WebResourceErrorType.hostLookup,
    win.WebErrorStatus.timeout => WebResourceErrorType.timeout,
    win.WebErrorStatus.redirectFailed => WebResourceErrorType.redirectLoop,
    win.WebErrorStatus.certificateCommonNameIsIncorrect ||
    win.WebErrorStatus.certificateExpired ||
    win.WebErrorStatus.clientCertificateContainsErrors ||
    win.WebErrorStatus.certificateRevoked ||
    win.WebErrorStatus.certificateIsInvalid => WebResourceErrorType.failedSslHandshake,
    _ => WebResourceErrorType.unknown,
  };

  static String _describe(win.WebErrorStatus status) => switch (status) {
    win.WebErrorStatus.validAuthenticationCredentialsRequired =>
      'HTTP Basic authentication is required. Check the saved account/password for this host.',
    win.WebErrorStatus.validProxyAuthenticationRequired => 'Proxy authentication is required.',
    win.WebErrorStatus.hostNameNotResolved => 'The host name could not be resolved.',
    win.WebErrorStatus.serverUnreachable || win.WebErrorStatus.cannotConnect => 'The server could not be reached.',
    win.WebErrorStatus.timeout => 'The connection timed out.',
    win.WebErrorStatus.connectionAborted ||
    win.WebErrorStatus.connectionReset ||
    win.WebErrorStatus.disconnected => 'The connection was interrupted.',
    win.WebErrorStatus.errorHttpInvalidServerResponse => 'The server returned an invalid response.',
    win.WebErrorStatus.redirectFailed => 'Too many redirects.',
    win.WebErrorStatus.certificateCommonNameIsIncorrect ||
    win.WebErrorStatus.certificateExpired ||
    win.WebErrorStatus.clientCertificateContainsErrors ||
    win.WebErrorStatus.certificateRevoked ||
    win.WebErrorStatus.certificateIsInvalid => 'The site certificate is invalid.',
    _ => status.name,
  };

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {
    _delegate = handler as WindowsNavigationDelegate;
    _bindDelegate();
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _askForBasicCredentials(params.uri);
    await _ready;
    // WebView2's loadUrl issues a GET. The app's page loads are all GETs; a
    // POST with a body is not expressible through this API and is ignored.
    await _native.loadUrl(_withBasicAuth(params.uri).toString());
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    await _ready;
    await _native.loadStringContent(html);
  }

  @override
  Future<String?> currentUrl() async => _currentUrl;

  @override
  Future<bool> canGoBack() async => _canGoBack;

  @override
  Future<bool> canGoForward() async => _canGoForward;

  @override
  Future<void> goBack() async => _native.goBack();

  @override
  Future<void> goForward() async => _native.goForward();

  @override
  Future<void> reload() async => _native.reload();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {
    // WebView2 enables JavaScript by default; the app always wants it on.
    // There is no per-controller disable in this API, so this is a no-op.
  }

  @override
  Future<void> setBackgroundColor(Color color) async {
    await _ready;
    await _native.setBackgroundColor(color);
  }

  @override
  Future<void> setUserAgent(String? userAgent) async {
    if (userAgent == null) return;
    await _ready;
    await _native.setUserAgent(userAgent);
  }

  /// webview_flutter calls this synchronously from the WebViewController
  /// constructor when the app passes `onPermissionRequest`. Without an
  /// override the base class throws UnimplementedError and construction crashes.
  /// WebView2 requests permissions natively; accept the callback but let the
  /// platform handle it (the app's callers deny by default anyway).
  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {
    await _ready;
    await _native.executeScript(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    await _ready;
    final value = await _native.executeScript(javaScript);
    // Match webview_flutter's platform contract: numbers and booleans pass
    // through, everything else is JSON-encoded text. The Windows plugin has
    // already jsonDecode'd the channel reply, so re-encode strings here (they
    // must come back quoted, as on Android) and use jsonEncode for collections
    // instead of Dart's toString (which is not JSON).
    if (value == null) return 'null';
    if (value is num || value is bool) return value;
    return jsonEncode(value);
  }

  final Map<String, JavaScriptChannelParams> _channels = {};

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    _channels[params.name] = params;
    await _ready;
    _ensureChannelBridge();
    final definition = _channelDefinition(params.name);
    // Register for every future document too: a channel added after the first
    // load (e.g. the companion stage) would otherwise vanish on the next
    // navigation. The definition is idempotent (`if (!window[n])`).
    await _native.addScriptToExecuteOnDocumentCreated(definition);
    // And define it in the already-loaded document.
    await _native.executeScript(definition);
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {
    _channels.remove(javaScriptChannelName);
  }

  bool _bridgeInstalled = false;

  /// Routes messages from WebView2's `window.chrome.webview.postMessage` back
  /// to the matching JavaScriptChannelParams. The per-channel `window.<name>` shim
  /// is registered separately by [addJavaScriptChannel] for each new document.
  Future<void> _ensureChannelBridge() async {
    if (_bridgeInstalled) return;
    _bridgeInstalled = true;

    _native.webMessage.listen((message) {
      if (message is! Map) return;
      final name = message['__dshChannel'];
      if (name is! String) return;
      final channel = _channels[name];
      if (channel == null) return;
      final body = message['message'];
      channel.onMessageReceived(JavaScriptMessage(message: body?.toString() ?? ''));
    });
  }

  static String _channelDefinition(String name) => '''
(function() {
  var n = ${_jsString(name)};
  if (!window[n]) {
    window[n] = { postMessage: function(m) {
      window.chrome.webview.postMessage(JSON.stringify({__dshChannel: n, message: m}));
    }};
  }
})();''';

  static String _jsString(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}

/// Holds the navigation callbacks the business code registers, so the
/// controller can fire them when the native WebView2 emits matching events.
class WindowsNavigationDelegate extends PlatformNavigationDelegate {
  WindowsNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  ProgressCallback? onProgress;
  WebResourceErrorCallback? onWebResourceError;
  UrlChangeCallback? onUrlChange;
  NavigationRequestCallback? onNavigationRequest;
  HttpAuthRequestCallback? onHttpAuthRequest;

  // webview_flutter calls these synchronously from the NavigationDelegate
  // constructor for whichever callbacks the app supplied. Without overrides the
  // base class throws UnimplementedError and the delegate construction crashes.
  // WebView2 has no pre-navigation interception or HTTP-auth challenge hook in
  // this package, so they are stored but not fired: links open inside the
  // WebView instead of the system browser, and Basic auth must be satisfied by
  // the app's cookie/token flow rather than a native challenge dialog.
  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async =>
      onNavigationRequest = callback;

  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback callback) async =>
      onHttpAuthRequest = callback;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback callback) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async =>
      onPageStarted = callback;

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      onPageFinished = callback;

  @override
  Future<void> setOnProgress(ProgressCallback callback) async =>
      onProgress = callback;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      onWebResourceError = callback;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async =>
      onUrlChange = callback;

  // These have no WebView2 equivalent in this package. Leaving the base
  // no-op/unimplemented behaviour is safe: the business code registers them
  // defensively and does not depend on the callbacks firing on desktop.
}

/// Renders the WebView2 texture in place of webview_flutter's WebViewWidget.
class WindowsWebViewWidget extends PlatformWebViewWidget {
  WindowsWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    final controller = params.controller as WindowsWebViewController;
    final native = controller.native;
    // Kick off native creation on first build; all later builds are no-ops.
    controller.startInitialization();
    // The native WebView2 controller is a ValueNotifier whose isInitialized
    // flips asynchronously. Webview() renders an empty box until then and does
    // not listen for the flip itself, so rebuild when it becomes ready.
    return ValueListenableBuilder<win.WebviewValue>(
      valueListenable: native,
      builder: (context, value, _) =>
          value.isInitialized ? win.Webview(native, key: params.key) : const SizedBox.expand(),
    );
  }
}
