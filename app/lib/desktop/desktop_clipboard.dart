// Windows desktop clipboard images. Flutter's `onContentInserted` is Android
// only, so the native runner answers `dsh/clipboard` with PNG bytes instead.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dsh/clipboard');

/// Absolute paths of files copied in Explorer (e.g. an image file Ctrl+C),
/// or empty when the clipboard holds no files. Images copied as pixels come
/// through [readClipboardImage] instead.
Future<List<String>> readClipboardFiles() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return const [];
  try {
    final paths = await _channel.invokeListMethod<String>('filePaths');
    return paths ?? const [];
  } on MissingPluginException {
    return const [];
  } catch (_) {
    return const [];
  }
}

/// The clipboard's image as PNG, or null when it holds none (text, files).
Future<Uint8List?> readClipboardImage() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
  try {
    final bytes = await _channel.invokeMethod<Uint8List>('imagePng');
    if (bytes != null && bytes.isNotEmpty) return bytes;
  } on MissingPluginException {
    // Runners before the clipboard channel: plain paste still works.
  } catch (_) {}
  return null;
}

/// Saves PNG bytes under Pictures/DSH Go and returns the absolute path.
Future<String?> saveImageToPictures(Uint8List bytes, {String? name}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
  try {
    return await _channel.invokeMethod<String>('saveImagePng', {
      'bytes': bytes,
      'name': ?name,
    });
  } on MissingPluginException {
    return null;
  } catch (_) {
    return null;
  }
}
