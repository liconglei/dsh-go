import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// A document chooser belongs to the document that requested it. Navigation,
/// a renderer loss or disposal retires it even if Android returns a file later.
/// The platform returns temporary content URIs (on HarmonyOS the system
/// picker's `file://docs/…` and `file://media/…`), without copying file contents
/// into Dart or granting the page access to app-private filesystem paths.
class WebFileChooser {
  WebFileChooser({
    MethodChannel? channel,
    bool? ohos,
    bool? windows,
    this._canChoose,
    Future<List<Uri>> Function(FileSelectorParams params)? pickFiles,
  }) : _channel = channel ?? const MethodChannel('dsh/web-files'),
       _ohos = ohos ?? Platform.operatingSystem == 'ohos',
       _windows = windows ?? Platform.isWindows,
       _pickFiles = pickFiles ?? _pickFileUris;

  final MethodChannel _channel;
  final bool _ohos;
  final bool _windows;
  final Future<List<Uri>> Function(FileSelectorParams params) _pickFiles;
  final bool Function()? _canChoose;
  int _generation = 0;
  bool _disposed = false;
  bool _busy = false;
  String? _owner;

  /// The desktop dialog answers absolute paths; only the Windows branch below
  /// ever calls this, so phones never open a picker twice.
  static Future<List<Uri>> _pickFileUris(FileSelectorParams params) async {
    final filter = pickerFilter(params.acceptTypes);
    final files = await FilePicker.pickFiles(
      type: filter.type,
      allowedExtensions: filter.extensions,
      // WebView2 is parented to a message-only window in this plugin, so a
      // dialog without an owner can come up behind the app and look dead.
      // windows_file_picker then shows the shell dialog owned by the
      // foreground window (FilePickerWindowsOptions.parentWindowHandle null).
      windowsOptions: const WindowsOptions(lockParentWindow: true),
    );
    return files.map((file) => file.uri).toList();
  }

  Future<void> attach(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setOnShowFileSelector(
        (params) => choose(params, webViewId: platform.webViewIdentifier, currentUrl: controller.currentUrl),
      );
    } else if (_ohos) {
      // oh-flutter's controller has the same method and fields, but its package
      // is only in the HarmonyOS build.
      final dynamic ohos = platform;
      await ohos.setOnShowFileSelector(
        (dynamic params) => choose(
          FileSelectorParams(
            isCaptureEnabled: params.isCaptureEnabled as bool,
            acceptTypes: List<String>.from(params.acceptTypes as List),
            filenameHint: params.filenameHint as String?,
            mode: FileSelectorMode.values.byName((params.mode as Enum).name),
          ),
          webViewId: ohos.webViewIdentifier as int,
          currentUrl: controller.currentUrl,
        ),
      );
    } else if (_windows) {
      // The Windows adapter exposes a matching method but lives under
      // lib/desktop/; dynamic keeps this shared file free of that dependency.
      final dynamic windows = platform;
      await windows.setOnShowFileSelector(
        (dynamic params) => chooseWindows(
          params as FileSelectorParams,
          currentUrl: controller.currentUrl,
        ),
      );
    }
  }

  /// Windows file picker: paths are absolute local files, not content URIs,
  /// so the grant check in [choose] does not apply. The same generation guard
  /// drops a late result after navigation.
  Future<List<String>> chooseWindows(
    FileSelectorParams params, {
    required Future<String?> Function() currentUrl,
  }) async {
    if (_disposed || _busy || _canChoose?.call() == false ||
        params.mode == FileSelectorMode.save) {
      return const [];
    }
    _busy = true;
    final generation = _generation;
    bool current() => !_disposed && generation == _generation && _canChoose?.call() != false;
    try {
      final uri = Uri.tryParse(await currentUrl() ?? '');
      if (!current() || uri == null || !['http', 'https'].contains(uri.scheme)) {
        return const [];
      }
      final picked = await _pickFiles(params);
      if (!current()) return const [];
      // Only this Windows branch ever runs, so ask for Windows separators
      // explicitly: the platform default would follow the host the tests run
      // on and turn these into /C:/… on a Linux runner.
      final paths = picked
          .where((uri) => uri.scheme == 'file')
          .map((uri) => uri.toFilePath(windows: true))
          .toList();
      // The Windows dialog is always multi-select — windows_file_picker offers
      // no single-file mode through FilePicker.pickFiles — so a single-file
      // input keeps the first choice instead of throwing the pick away.
      if (params.mode == FileSelectorMode.open) return paths.take(1).toList();
      return paths;
    } catch (_) {
      return const [];
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  Future<List<String>> choose(
    FileSelectorParams params, {
    required int webViewId,
    required Future<String?> Function() currentUrl,
  }) async {
    // A file upload never creates/overwrites a local file. Capture is a hint:
    // use the system document UI without silently acquiring camera/mic access.
    if (_disposed || _busy || _canChoose?.call() == false || params.mode == FileSelectorMode.save) return const [];
    _busy = true;
    final generation = _generation;
    final owner = '$webViewId:$generation';
    bool current() => !_disposed && generation == _generation && _canChoose?.call() != false;
    try {
      final url = await currentUrl();
      final uri = Uri.tryParse(url ?? '');
      if (!current() || uri == null || !['http', 'https'].contains(uri.scheme)) {
        return const [];
      }
      _owner = owner;
      final files = await _channel.invokeListMethod<String>('pick', {
        'owner': owner,
        'webViewId': webViewId,
        'url': url,
        'acceptTypes': params.acceptTypes,
        'multiple': params.mode == FileSelectorMode.openMultiple,
      });
      if (!current()) return const [];
      final after = await currentUrl();
      if (!current() || after != url) return const [];
      if (files == null || files.isEmpty) return const [];
      // Native also validates grants/providers. Never hand an app-private path
      // or a malformed plugin response to the WebView.
      if (!files.every(_grantedUri)) return const [];
      if (params.mode == FileSelectorMode.open && files.length != 1) return const [];
      return files;
    } on Object {
      // The WebChromeClient must always receive an answer, including when a
      // renderer/platform disappears while either URL or chooser is pending.
      return const [];
    } finally {
      if (_owner == owner) _owner = null;
      _busy = false;
    }
  }

  bool _grantedUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (_ohos) return uri.scheme == 'file' && const {'docs', 'media'}.contains(uri.authority);
    return uri.scheme == 'content' && uri.authority.isNotEmpty;
  }

  void invalidate() {
    _generation++;
    final owner = _owner;
    _owner = null;
    if (owner != null && !_windows) {
      unawaited(_channel.invokeMethod<void>('cancel', {'owner': owner}).catchError((Object _) {}));
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}

final _extensionPattern = RegExp(r'^[a-z0-9][a-z0-9._+-]*$');

/// The dialog filter for an `<input accept>` list.
///
/// Chromium filters its own dialog. On Windows `windows_file_picker` builds a
/// single filter spec with no "all files" entry, so a filter we cannot express
/// exactly would hide files the page itself would have taken; anything
/// unrecognised therefore means no filter at all.
@visibleForTesting
({FileType type, List<String>? extensions}) pickerFilter(List<String> accept) {
  const noFilter = (type: FileType.any, extensions: null);
  final extensions = <String>[];
  for (final token in accept.map((value) => value.trim().toLowerCase())) {
    if (token.isEmpty || token == '*/*') return noFilter;
    if (token.startsWith('.')) {
      final extension = token.substring(1);
      if (!_extensionPattern.hasMatch(extension)) return noFilter;
      extensions.add(extension);
      continue;
    }
    final mapped = _extensionsFor(token);
    if (mapped == null) return noFilter;
    extensions.addAll(mapped);
  }
  if (extensions.isEmpty) return noFilter;
  return (type: FileType.custom, extensions: extensions.toSet().toList());
}

List<String>? _extensionsFor(String mime) {
  final exact = _mimeExtensions[mime];
  if (exact != null) return exact;
  final slash = mime.indexOf('/');
  if (slash <= 0) return null;
  return _mimeExtensions['${mime.substring(0, slash)}/*'];
}

/// Extensions a browser would accept for these types. Deliberately generous:
/// a missing entry makes a file unselectable, an extra one costs nothing.
const Map<String, List<String>> _mimeExtensions = {
  'image/*': ['png', 'jpg', 'jpeg', 'jfif', 'gif', 'webp', 'bmp', 'svg', 'ico', 'tif', 'tiff', 'avif', 'heic', 'heif'],
  'video/*': ['mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv', 'mpg', 'mpeg', 'ogv', '3gp'],
  'audio/*': ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'weba', 'mid', 'midi'],
  'text/*': ['txt', 'text', 'md', 'markdown', 'csv', 'tsv', 'log', 'json', 'xml', 'yaml', 'yml', 'html', 'htm', 'css', 'js'],
  'image/png': ['png'],
  'image/jpeg': ['jpg', 'jpeg', 'jfif'],
  'image/gif': ['gif'],
  'image/webp': ['webp'],
  'image/svg+xml': ['svg'],
  'image/bmp': ['bmp'],
  'image/avif': ['avif'],
  'image/heic': ['heic', 'heif'],
  'image/tiff': ['tif', 'tiff'],
  'video/mp4': ['mp4', 'm4v'],
  'video/webm': ['webm'],
  'video/quicktime': ['mov'],
  'video/x-matroska': ['mkv'],
  'audio/mpeg': ['mp3'],
  'audio/wav': ['wav'],
  'audio/x-wav': ['wav'],
  'audio/ogg': ['ogg', 'oga'],
  'audio/mp4': ['m4a'],
  'audio/flac': ['flac'],
  'text/plain': ['txt', 'text', 'log'],
  'text/csv': ['csv'],
  'text/markdown': ['md', 'markdown'],
  'text/html': ['html', 'htm'],
  'text/css': ['css'],
  'text/javascript': ['js'],
  'application/json': ['json'],
  'application/xml': ['xml'],
  'application/pdf': ['pdf'],
  'application/zip': ['zip'],
  'application/x-zip-compressed': ['zip'],
  'application/msword': ['doc'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': ['docx'],
  'application/vnd.ms-excel': ['xls'],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['xlsx'],
  'application/vnd.ms-powerpoint': ['ppt'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': ['pptx'],
};
