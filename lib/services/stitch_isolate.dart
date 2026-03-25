import 'package:opencv_dart/opencv.dart';

/// Custom stitching isolate with improved OpenCV Stitcher configuration.
/// Runs synchronously — call via compute() from StitchService.
class StitchIsolate {
  static Map<String, dynamic> run(Map<String, dynamic> params) {
    final List<String> imagePaths = params['imagePaths'] as List<String>;
    final String outputDir = params['outputDir'] as String;

    try {
      // Load and validate images
      final List<Mat> images = [];
      for (final path in imagePaths) {
        final img = imread(path);
        if (!img.isEmpty && img.rows > 100 && img.cols > 100) {
          images.add(img);
        } else {
          img.dispose();
        }
      }

      if (images.length < 2) {
        for (final m in images) m.dispose();
        return {
          'success': false,
          'error': 'Only ${images.length} valid image(s) loaded. Need at least 2.',
        };
      }

      // Configure stitcher for best quality
      final stitcher = Stitcher.create(mode: StitcherMode.PANORAMA);
      stitcher.registrationResol = 0.6;    // Feature detection resolution
      stitcher.seamEstimationResol = 0.1;  // Seam blending resolution
      stitcher.waveCorrection = true;       // Correct wave distortion
      stitcher.panoConfidenceThresh = 1.0; // Only accept high-confidence stitches

      final (status, dst) = stitcher.stitch(images.cvd);
      for (final m in images) m.dispose();

      if (status != StitcherStatus.OK) {
        dst.dispose();
        final msg = _statusMessage(status, imagePaths.length);
        return {'success': false, 'error': msg};
      }

      final outputPath =
          '$outputDir/panorama_${DateTime.now().millisecondsSinceEpoch}.jpeg';
      imwrite(outputPath, dst);
      dst.dispose();

      return {'success': true, 'filePath': outputPath};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  static String _statusMessage(StitcherStatus status, int frameCount) {
    switch (status) {
      case StitcherStatus.ERR_NEED_MORE_IMGS:
        return 'Not enough overlapping features. '
            'Capture more frames with ~30% overlap between shots.';
      case StitcherStatus.ERR_HOMOGRAPHY_EST_FAIL:
        return 'Could not match frames. '
            'Make sure consecutive shots overlap by at least 30%.';
      case StitcherStatus.ERR_CAMERA_PARAMS_ADJUST_FAIL:
        return 'Camera calibration failed. '
            'Try capturing frames at a steadier pace.';
      default:
        return 'Stitching failed (status $status) with $frameCount frames.';
    }
  }
}
