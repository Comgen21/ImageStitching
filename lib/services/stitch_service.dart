import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'stitch_isolate.dart';
import 'video_stitch_isolate.dart';

class StitchService {
  /// Stitches image files into a panorama using OpenCV.
  static Future<String> stitch(List<String> imagePaths) async {
    final dir = await getApplicationDocumentsDirectory();
    final result = await compute(StitchIsolate.run, {
      'imagePaths': imagePaths,
      'outputDir': dir.path,
    });
    if (!(result['success'] as bool)) throw Exception(result['error']);
    return result['filePath'] as String;
  }

  /// Extracts frames from a video file and stitches them into a panorama.
  /// Returns the output file path on success, throws on failure.
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
