import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 系统托盘（右下角图标 + 右键菜单）。
///
/// 完全独立于上游业务代码：只依赖 tray_manager / window_manager，不 import
/// app/lib 下任何文件。行为：
///  * 点关闭按钮 -> 隐藏到托盘，而不是退出；
///  * 托盘左键或菜单「显示窗口」-> 唤起并聚焦主窗口；
///  * 菜单「退出」-> 才真正结束进程。
class DesktopTray with TrayListener, WindowListener {
  static const _showKey = 'show_window';
  static const _exitKey = 'exit_app';

  DesktopTray({ValueNotifier<bool>? visibility})
    : visibility = visibility ?? ValueNotifier<bool>(true);

  /// 主窗口是否可见。桌面端 hide 到托盘不会改变 Flutter 的 AppLifecycleState，
  /// 所以用这个显式驱动 appForegroundProvider，会话完成才会走系统通知而不是
  /// 不可见窗口里的 banner。
  final ValueNotifier<bool> visibility;

  bool _installed = false;

  /// 安装托盘。任何失败都应被吞掉，不能阻止应用启动（例如误在非 Windows 上入口）。
  Future<void> install() async {
    if (_installed) return;
    _installed = true;

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    final icon = await _findIcon();
    if (icon != null) await trayManager.setIcon(icon.path);
    await trayManager.setToolTip('dsh');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _showKey, label: '显示窗口'),
          MenuItem.separator(),
          MenuItem(key: _exitKey, label: '退出'),
        ],
      ),
    );
    trayManager.addListener(this);
  }

  /// runner/resources 在 `flutter run`、exe 运行和安装版里的位置都不同，逐个试。
  /// 以 exe 所在目录为基准最可靠：快捷方式的「起始位置」可以指向任意目录，
  /// 纯相对路径会找不到 CMake 复制到 exe 旁边的 resources/app_icon.ico。
  Future<File?> _findIcon() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final path in [
      '$exeDir${Platform.pathSeparator}resources${Platform.pathSeparator}app_icon.ico',
      'resources/app_icon.ico',
      'windows/runner/resources/app_icon.ico',
    ]) {
      final file = File(path);
      if (await file.exists()) return file.absolute;
    }
    return null;
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
    visibility.value = true;
  }

  /// Ctrl+W: same path as the close button — hide to tray, not quit.
  Future<void> hideWindow() async {
    await windowManager.hide();
    visibility.value = false;
  }

  Future<void> exitApp() async {
    // A remote-only client keeps live WebSocket/long-poll connections and
    // timers alive, so destroying the window alone leaves the Dart VM running
    // and the app appears to hang. Close the window for instant visual feedback,
    // then terminate outright: all session state lives on the server and
    // credentials live in the OS store, so there is nothing to flush locally.
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      // Still terminate below even if the window teardown fails.
    }
    exit(0);
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _showKey:
        unawaited(showWindow());
      case _exitKey:
        unawaited(exitApp());
    }
  }

  /// 关闭按钮：隐藏到托盘而不是退出，并把前台标记同步为 false。
  @override
  void onWindowClose() => unawaited(() async {
    await windowManager.hide();
    visibility.value = false;
  }());
}
