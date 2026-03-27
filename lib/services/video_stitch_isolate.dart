import 'package:opencv_dart/opencv.dart';
import 'professional_stitch_isolate.dart';

/// Extracts keyframes from a video and stitches them into a panorama
/// using the cylindrical-warp + SIFT + affine pipeline.
/// Runs synchronously — call via compute() from StitchService.
class VideoStitchIsolate {
  static const int _targetFrames = 16;

  static Map<String, dynamic> run(Map<String, dynamic> params) {
    final String videoPath = params['videoPath'] as String;
    final String outputDir = params['outputDir'] as String;

    VideoCapture? cap;
    try {
      cap = VideoCapture.fromFile(videoPath);
      if (!cap.isOpened) {
        return {'success': false, 'error': 'Cannot open video file'};
      }

      final totalFrames = cap.get(CAP_PROP_FRAME_COUNT).toInt();
      final fps = cap.get(CAP_PROP_FPS);

      if (totalFrames < 10) {
        cap.release();
        return {
          'success': false,
          'error': 'Video too short ($totalFrames frames)',
        };
      }

      // Skip first/last 8% to avoid shake at start and stop
      final skipStart = (totalFrames * 0.08).toInt();
      final usableFrames =
          totalFrames - skipStart - (totalFrames * 0.08).toInt();

      if (usableFrames < 10) {
        cap.release();
        return {
          'success': false,
          'error': 'Video too short after trimming edges',
        };
      }

      // Compute evenly-spaced seek positions
      final step = usableFrames / _targetFrames;
      final List<Mat> frames = [];

      for (int i = 0; i < _targetFrames; i++) {
        final frameIdx = skipStart + (i * step).round();
        cap.set(CAP_PROP_POS_FRAMES, frameIdx.toDouble());
        final (success, frame) = cap.read();
        if (!success || frame.isEmpty) {
          frame.dispose();
          continue;
        }
        frames.add(frame.clone());
        frame.dispose();
      }
      cap.release();

      if (frames.length < 2) {
        for (final f in frames) f.dispose();
        return {
          'success': false,
          'error': 'Only ${frames.length} frame(s) extracted. '
              'Record a longer video.',
        };
      }

      // Cylindrical warp + SIFT + affine stitching
      final result = ProfessionalStitchIsolate.runFrames(frames, outputDir);
      for (final f in frames) f.dispose();

      // Append video metadata to result
      if (result['success'] == true) {
        return {
          ...result,
          'totalFrames': totalFrames,
          'fps': fps,
        };
      }
      return result;
    } catch (e) {
      cap?.release();
      return {'success': false, 'error': e.toString()};
    }
  }
}
