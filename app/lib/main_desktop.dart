import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart' as win_webview;

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'desktop/desktop_notify_channel.dart';
import 'desktop/desktop_tray.dart';
import 'desktop/windows_webview_platform.dart';
import 'launch/launch_state.dart';
import 'links/page_links.dart' show registerPageLink, tavernPageLink;
import 'runtime/local_paths.dart';
import 'state/locale_state.dart';
import 'state/notify_state.dart' show appForegroundProvider, notifyChannelProvider;
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/tavern/tavern_home_page.dart';
import 'ui/theme/theme.dart' show SteadyFrameBinding;

/// Windows 桌面入口：只连远程 `dsh web`，不启动本机引擎。
///
/// 与 main.dart 的差别都在 runApp 前，全是注入 Windows 平台实现：
///  1. 把「本机引擎已拒绝」和「API Key 稍后设置」写进偏好 —— root_gate 读到
///     localDeclined 后跳过引擎安装/引导直达首页；
///  2. 用 [DesktopNotifyChannel] 替换没有 Windows 实现的通知 MethodChannel；
///  3. 用 [WindowsWebViewPlatform] 让网页模式在没有官方实现时走 WebView2；
///  4. 安装系统托盘（关闭最小化到托盘，菜单退出才结束进程）。
///
/// 用户在「远程主机」里填自己的 HTTP(S) 地址与账号即可连接。服务器地址和
/// 凭据不进代码、不进仓库：它们由用户经现有表单存入系统凭据库。
@pragma('vm:entry-point')
Future<void> main() => runWithFrameProbe(_startDesktop);

/// Runs one startup step without letting a partial failure kill the shell.
Future<void> _guardStartup<T>(String label, Future<T> Function() step) async {
  try {
    await step();
  } catch (e) {
    debugPrint('main_desktop: $label failed: $e');
  }
}

Future<void> _startDesktop() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();

  // Recent WebView2/Chromium runtimes ignore HTTP challenges unless the
  // origin is on the auth allowlist. A desktop client talks to arbitrary
  // user-configured hosts, so allow all here; credentials are only ever
  // replayed for the host the user saved (see WindowsWebViewPlatform).
  try {
    await win_webview.WebviewController.initializeEnvironment(
      additionalArguments: '--auth-server-allowlist=*',
    );
  } catch (_) {
    // Older runtimes ignore the flag; startup must not depend on it.
  }

  // Windows has no webview_flutter platform. Register the WebView2-backed
  // shim before runApp so every plain `WebViewController()` in the app works.
  WebViewPlatform.instance = WindowsWebViewPlatform();

  // The keys mirror OnboardingPrefsController's private constants. Writing them
  // before runApp means the controller's _load() sees them on its first build.
  // A broken preference store must not block the whole desktop shell: the app
  // still starts and simply shows onboarding instead of the remote home.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_local_declined', true);
    await prefs.setBool('onboarding_key_skipped', true);
  } catch (e) {
    debugPrint('main_desktop: onboarding prefs unavailable: $e');
  }

  await Future.wait([
    _guardStartup('language load', AppLanguageController.load),
    _guardStartup('launch state', LaunchController.begin),
    _guardStartup('local paths', LocalPaths.load),
  ]);
  registerThirdPartyLicenses();
  registerFontLicenses();
  registerPageLink(tavernPageLink, () => const TavernHomePage());

  // Hiding to the tray does not reliably change Flutter's lifecycle state on
  // Windows. Tray and notification taps share one visibility flag so alerts
  // become system notifications while the window is hidden.
  final visibility = ValueNotifier<bool>(true);

  // Windows has no `dsh/notify` native plugin. Supply a local-notifier-backed
  // channel so the shared notification controller (and tap-to-open-chat) works.
  final notifyChannel = DesktopNotifyChannel(visibility: visibility);
  try {
    await notifyChannel.setup();
  } catch (e) {
    // Windows toast registration can fail (policy, shortcut permissions).
    // Notifications are optional; the app must still start.
    debugPrint('main_desktop: desktop notify setup failed: $e');
  }

  // System tray. Failure must never block startup (e.g. a non-Windows machine
  // accidentally using this entrypoint), so errors are caught here.
  final tray = DesktopTray(visibility: visibility);
  try {
    await tray.install();
  } catch (_) {
    // Tray is optional; the app still works with the plain window.
  }

  // A container outside runApp lets tray/notification callbacks update the
  // same provider tree the UI reads, even before the first frame.
  final container = ProviderContainer(
    overrides: [notifyChannelProvider.overrideWithValue(notifyChannel)],
  );
  visibility.addListener(() {
    container.read(appForegroundProvider.notifier).set(visibility.value);
  });

  runApp(UncontrolledProviderScope(container: container, child: const DshApp()));
}
