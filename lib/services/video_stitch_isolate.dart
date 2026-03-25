import 'package:opencv_dart/opencv.dart';

/// Extracts keyframes from a video and stitches them into a panorama.
/// Runs synchronously — call via compute() from StitchService.
class VideoStitchIsolate {
  // Target number of frames to stitch (balance quality vs speed)
  static const int _targetFrames = 22;

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
        return {'success': false, 'error': 'Video too short (only $totalFrames frames)'};
      }

      // Skip first/last 8% to avoid camera shake at start and stop
      final skipStart = (totalFrames * 0.08).toInt();
      final skipEnd = (totalFrames * 0.08).toInt();
      final usableFrames = totalFrames - skipStart - skipEnd;

      if (usableFrames < 10) {
        cap.release();
        return {'success': false, 'error': 'Video too short after trimming edges'};
      }

      // Sample interval to hit target frame count
      final step = (usableFrames ~/ _targetFrames).clamp(1, usableFrames);

      final List<Mat> frames = [];
      int idx = 0;

      while (frames.length < _targetFrames) {
        final (success, frame) = cap.read();
        if (!success) break;

        if (idx >= skipStart) {
          final usableIdx = idx - skipStart;
          if (usableIdx % step == 0) {
            frames.add(frame.clone());
          }
        }
        frame.dispose();
        idx++;
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

      // Stitch with optimised settings
      final stitcher = Stitcher.create(mode: StitcherMode.PANORAMA);
      stitcher.registrationResol = 0.6;
      stitcher.seamEstimationResol = 0.1;
      stitcher.waveCorrection = true;
      stitcher.panoConfidenceThresh = 1.0;

      final (status, dst) = stitcher.stitch(frames.cvd);
      for (final f in frames) f.dispose();

      if (status != StitcherStatus.OK) {
        dst.dispose();
        return {'success': false, 'error': _statusMessage(status)};
      }

      final outputPath =
          '$outputDir/panorama_${DateTime.now().millisecondsSinceEpoch}.jpeg';
      imwrite(outputPath, dst);
      dst.dispose();

      return {
        'success': true,
        'filePath': outputPath,
        'framesUsed': frames.length,
        'totalFrames': totalFrames,
        'fps': fps,
      };
    } catch (e) {
      cap?.release();
      return {'success': false, 'error': e.toString()};
    }
  }

  static String _statusMessage(StitcherStatus status) {
    switch (status) {
      case StitcherStatus.ERR_NEED_MORE_IMGS:
        return 'Not enough overlapping frames. '
            'Pan the shelf more slowly so frames overlap.';
      case StitcherStatus.ERR_HOMOGRAPHY_EST_FAIL:
        return 'Cannot match frames. '
            'Keep the camera steady at shelf height and pan slowly.';
      case StitcherStatus.ERR_CAMERA_PARAMS_ADJUST_FAIL:
        return 'Camera calibration failed. '
            'Try recording again with a steadier hand.';
      default:
        return 'Stitching failed ($status). '
            'Try panning more slowly with good shelf lighting.';
    }
  }
}
