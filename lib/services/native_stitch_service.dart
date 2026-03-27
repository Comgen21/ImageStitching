import 'package:flutter/services.dart';

/// Dart-side client for the native NDK stitcher exposed via MethodChannel.
///
/// The native implementation lives in:
///   android/app/src/main/cpp/stitcher.cpp  (C++ OpenCV pipeline)
///   android/app/src/main/kotlin/.../NativeStitcher.kt  (JNI wrapper)
///   android/app/src/main/kotlin/.../MainActivity.kt    (MethodChannel handler)
class NativeStitchService {
  static const MethodChannel _channel =
      MethodChannel('com.simplr.shelf_monitor_app/stitch');

  /// Stitches [imagePaths] on the native side and returns the local file path
  /// of the resulting panorama JPEG.
  ///
  /// [imagePaths] must contain at least 2 absolute local file paths.
  /// [outputDir]  is the directory where the result file will be written.
  ///
  /// Throws [Exception] on failure (native error, platform exception, etc.).
  static Future<String> stitch(
    List<String> imagePaths,
    String outputDir,
  ) async {
    try {
      final String? result = await _channel.invokeMethod<String>(
        'stitchImages',
        {
          'paths': imagePaths,
          'outputDir': outputDir,
        },
      );

      if (result == null || result.isEmpty) {
        throw Exception('Native stitcher returned an empty result.');
      }

      return result;
    } on PlatformException catch (e) {
      throw Exception(
        'NativeStitchService: platform error [${e.code}]: ${e.message}',
      );
    }
  }

  /// Returns `true` if the native stitcher channel is reachable on this device.
  ///
  /// Performs a dummy invocation and interprets [MissingPluginException] as
  /// "not available" (e.g., running on iOS or the .so was not compiled in).
  static Future<bool> isAvailable() async {
    try {
      // We call with an intentionally invalid argument so the method handler
      // returns an error — but NOT a MissingPluginException — meaning the
      // channel itself is registered and the native library is loaded.
      await _channel.invokeMethod<String>(
        'stitchImages',
        {'paths': <String>[], 'outputDir': ''},
      );
      // If it somehow succeeds (shouldn't with empty paths), channel is available.
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // Channel exists and native code replied with an error → available.
      return true;
    } catch (_) {
      return false;
    }
  }
}
