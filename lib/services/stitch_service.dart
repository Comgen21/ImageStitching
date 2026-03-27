import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'native_stitch_service.dart';
import 'professional_stitch_isolate.dart';
import 'stitch_api_service.dart';
import 'video_stitch_isolate.dart';

class StitchService {
  /// Stitches [imagePaths] using the best available pipeline:
  ///   1. Native NDK (C++ OpenCV via MethodChannel) — fastest, highest quality
  ///   2. Backend API (Python FastAPI server) — if reachable on LAN
  ///   3. On-device Dart/OpenCV isolate — universal fallback
  ///
  /// Returns the local file path of the stitched panorama.
  static Future<String> stitch(List<String> imagePaths) async {
    // 1. Try native NDK stitcher first
    if (await NativeStitchService.isAvailable()) {
      try {
        debugPrint('StitchService: using native NDK stitcher');
        final dir = await getApplicationDocumentsDirectory();
        return await NativeStitchService.stitch(imagePaths, dir.path);
      } catch (e) {
        debugPrint('StitchService: native stitcher failed ($e) — trying API');
      }
    }

    // 2. Try backend API
    if (await StitchApiService.isReachable()) {
      try {
        debugPrint('StitchService: using backend API stitcher');
        return await _stitchViaApi(imagePaths);
      } catch (e) {
        debugPrint('StitchService: API stitcher failed ($e) — falling back to on-device');
      }
    }

    // 3. On-device Dart/OpenCV isolate fallback
    debugPrint('StitchService: using on-device isolate stitcher');
    return _stitchOnDevice(imagePaths);
  }

  static Future<String> _stitchViaApi(List<String> imagePaths) async {
    final result = await StitchApiService.stitch(imagePaths);
    return _downloadImage(result.imageUrl);
  }

  static Future<String> _stitchOnDevice(List<String> imagePaths) async {
    final dir = await getApplicationDocumentsDirectory();
    final result = await compute(ProfessionalStitchIsolate.run, {
      'imagePaths': imagePaths,
      'outputDir': dir.path,
    });
    if (!(result['success'] as bool)) throw Exception(result['error']);
    return result['filePath'] as String;
  }

  /// Downloads [url] to local storage and returns the local file path.
  static Future<String> _downloadImage(String url) async {
    final dir = await getApplicationDocumentsDirectory();
    final dest = File(
        '${dir.path}/panorama_${DateTime.now().millisecondsSinceEpoch}.jpg');
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Failed to download panorama (HTTP ${resp.statusCode})');
    }
    await dest.writeAsBytes(resp.bodyBytes);
    return dest.path;
  }

  /// Extracts frames from a video and stitches using on-device pipeline.
  static Future<String> stitchVideo(String videoPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final result = await compute(VideoStitchIsolate.run, {
      'videoPath': videoPath,
      'outputDir': dir.path,
    });
    if (!(result['success'] as bool)) throw Exception(result['error']);
    return result['filePath'] as String;
  }
}
