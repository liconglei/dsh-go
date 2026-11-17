// Windows desktop notifications. The mobile [NotifyChannel] talks to the
// `dsh/notify` MethodChannel, which has no Windows side; this subclass is
// injected via `notifyChannelProvider` in main_desktop.dart instead, so the
// shared notify_state.dart / chat_alert_host.dart need no changes at all.
//
// Contract it must honour (see notify/notify_channel.dart):
//  - status().native == true, otherwise ChatAlertHost never activates the
//    controller or subscribes to taps;
//  - show/tryShow post a NotifyPost and taps emits a NotifyTap when clicked,
//    which is how a tap opens the matching conversation;
//  - cancel* remove a posted notification by group/key.
//
// Group and key are carried in a synthetic identifier. local_notifier has no
// group concept, so posted notifications are tracked in one map keyed by it;
// cancel closes the matching notification for real.

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

import '../notify/notify_channel.dart';

/// A [NotifyChannel] backed by Windows local notifications instead of the
/// Android/HarmonyOS MethodChannel. Only constructed on the desktop entry point.
class DesktopNotifyChannel extends NotifyChannel {
  DesktopNotifyChannel({ValueNotifier<bool>? visibility})
    : visibility = visibility ?? ValueNotifier<bool>(true),
      super();

  /// 与托盘共享的窗口可见性；点击通知唤起窗口时同步更新，避免 tap 仍被判成前台。
  final ValueNotifier<bool> visibility;

  /// local_notifier identifiers -> the live notification and what a tap opens.
  final Map<String, ({LocalNotification notification, NotifyTap tap})> _posted = {};
  final StreamController<NotifyTap> _tapController = StreamController<NotifyTap>.broadcast(sync: true);

  static const _appName = 'DSH Go';

  /// Must be called once from main before runApp. Creates the Windows shortcut
  /// so toast notifications can be attributed to the app.
  Future<void> setup() => localNotifier.setup(appName: _appName);

  @override
  Future<NotifySystemStatus> status() async => const NotifySystemStatus();

  @override
  Future<void> show(NotifyPost post) async {
    await _post(_idOf(post.group, post.key), post);
  }

  @override
  Future<bool> tryShow(NotifyPost post, {bool Function()? stillCurrent}) async {
    if (stillCurrent?.call() == false) return false;
    return _post(_idOf(post.group, post.key), post);
  }

  /// Returns whether the native post was accepted, so callers can fall back.
  Future<bool> _post(String id, NotifyPost post) async {
    final notification = LocalNotification(
      identifier: id,
      title: post.title,
      body: post.text,
    );
    final tap = NotifyTap(
      host: post.host,
      sessionId: post.sessionId,
      kind: post.kind,
      eventId: post.eventId,
    );
    notification.onClick = () => unawaited(() async {
      debugPrint('desktop notify: tapped $id');
      // A tapped toast is done; don't keep its notification/tap in the map
      // forever (Windows gives no callback for a toast cleared by the user).
      _posted.remove(id);
      // The window is hidden in the tray when a toast arrives. Bring it back
      // FIRST, then route the tap: doing both in parallel let the conversation
      // open behind a still-hidden window and looked like nothing happened.
      visibility.value = true;
      await _revealWindow();
      if (!_tapController.isClosed) _tapController.add(tap);
    }());
    _posted[id] = (notification: notification, tap: tap);
    try {
      await notification.show();
      return true;
    } catch (e) {
      // A toast registration/policy failure must not surface as an unhandled
      // Future error from the alert controller's unawaited show().
      _posted.remove(id);
      debugPrint('desktop notify: show failed: $e');
      return false;
    }
  }

  /// Windows toast activation can arrive while the window is still hidden.
  /// `show()` alone is occasionally ignored right at activation time, so retry
  /// briefly and keep the tap route waiting until the window is really back.
  Future<void> _revealWindow() async {
    visibility.value = true;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await windowManager.isVisible()) {
          await windowManager.focus();
          break;
        }
        await windowManager.show();
        await windowManager.focus();
      } catch (e) {
        debugPrint('desktop notify: reveal attempt $attempt failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  @override
  Future<void> cancel(String group, String key) async {
    final id = _idOf(group, key);
    final posted = _posted.remove(id);
    await posted?.notification.close();
  }

  @override
  Future<void> cancelGroup(String group) async {
    final ids = [for (final entry in _posted.entries) if (entry.key.startsWith('$group|')) entry.key];
    for (final id in ids) {
      await _posted.remove(id)?.notification.close();
    }
  }

  @override
  Future<void> cancelAll() async {
    for (final posted in _posted.values) {
      await posted.notification.close();
    }
    _posted.clear();
  }

  @override
  Stream<NotifyTap> get taps => _tapController.stream;

  /// Desktop needs no permission prompt and no settings page; notifications
  /// are controlled by the app's own [NotifyPrefs] switches.
  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> openSettings({String? channel}) async => false;

  /// Live activities are a phone-only feature; leave the base no-op behaviour.

  static String _idOf(String group, String key) => '$group|$key';
}
