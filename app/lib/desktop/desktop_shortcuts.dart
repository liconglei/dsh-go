// Desktop-only global shortcuts. Kept out of app.dart so the shared mobile
// shell is untouched; main_desktop.dart installs this around the app.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Window-level keys. Handled through HardwareKeyboard rather than a focus
/// node so they work even when the chat field owns focus; the event is still
/// reported as ignored, leaving the field's Ctrl+Enter/Ctrl+V intact.
class DesktopShortcuts extends StatefulWidget {
  const DesktopShortcuts({
    super.key,
    required this.child,
    required this.onHide,
    required this.onQuit,
  });

  final Widget child;
  final Future<void> Function() onHide;
  final Future<void> Function() onQuit;

  @override
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  bool _handling = false;

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyW) {
      _run(widget.onHide);
      return true;
    }
    if (key == LogicalKeyboardKey.keyQ) {
      _run(widget.onQuit);
      return true;
    }
    return false;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_handling) return;
    _handling = true;
    try {
      await action();
    } catch (_) {
      // Shortcuts must never crash the shell.
    } finally {
      _handling = false;
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
