import 'package:opencv_dart/opencv.dart';

/// Runs in a compute() isolate — analyses a newly captured frame for:
///   1. Blur (Laplacian variance < threshold → frame is blurry)
///   2. Overlap with the previous frame (via ORB feature matching)
class FrameAnalysisIsolate {
  // A Laplacian variance below this means the frame is blurry.
  // Typical sharp indoor photo: 200–800. Motion-blurred: < 80.
  static const double _blurThreshold = 80.0;

  static Map<String, dynamic> run(Map<String, dynamic> params) {
    final String newPath = params['newPath'] as String;
    final String? prevPath = params['prevPath'] as String?;

    final blurScore = _blurScore(newPath);
    final isBlurry = blurScore < _blurThreshold;

    double? overlapPercent;
    if (prevPath != null && !isBlurry) {
      overlapPercent = _overlapPercent(prevPath, newPath);
    }

    return {
      'isBlurry': isBlurry,
      'blurScore': blurScore,
      'overlapPercent': overlapPercent,
    };
  }

  // ── Blur detection ────────────────────────────────────────────────────────

  /// Variance of the Laplacian — higher = sharper.
  static double _blurScore(String imagePath) {
    final img = imread(imagePath);
    if (img.isEmpty) { img.dispose(); return 0.0; }

    // Downscale to max 480px wide for speed
    final Mat small;
    if (img.cols > 480) {
      small = resize(img, (480, (img.rows * 480.0 / img.cols).round()));
      img.dispose();
    } else {
      small = img;
    }

    final gray = cvtColor(small, COLOR_BGR2GRAY);
    small.dispose();

    final lap = laplacian(gray, MatType.CV_64F);
    gray.dispose();

    final (_, stddev) = meanStdDev(lap);
    lap.dispose();
    final variance = stddev.val1 * stddev.val1;
    stddev.dispose();
    return variance;
  }

  // ── Overlap estimation ────────────────────────────────────────────────────

  /// Estimates horizontal overlap between two frames using ORB features.
  /// Returns a value in [0, 100] percent, or null if matching failed.
  static double? _overlapPercent(String prevPath, String newPath) {
    Mat img1 = imread(prevPath);
    Mat img2 = imread(newPath);

    if (img1.isEmpty || img2.isEmpty) {
      img1.dispose();
      img2.dispose();
      return null;
    }

    const int maxW = 480;

    // Downscale both to 480px wide
    Mat small1, small2;
    if (img1.cols > maxW) {
      small1 = resize(img1, (maxW, (img1.rows * maxW / img1.cols).round()));
      img1.dispose();
    } else {
      small1 = img1;
    }
    if (img2.cols > maxW) {
      small2 = resize(img2, (maxW, (img2.rows * maxW / img2.cols).round()));
      img2.dispose();
    } else {
      small2 = img2;
    }

    final frameWidth = small1.cols.toDouble();

    final gray1 = cvtColor(small1, COLOR_BGR2GRAY);
    final gray2 = cvtColor(small2, COLOR_BGR2GRAY);
    small1.dispose();
    small2.dispose();

    final orb = ORB.create(nFeatures: 500);
    final (kps1, desc1) = orb.detectAndCompute(gray1, Mat.empty());
    final (kps2, desc2) = orb.detectAndCompute(gray2, Mat.empty());
    gray1.dispose();
    gray2.dispose();
    orb.dispose();

    if (desc1.isEmpty || desc2.isEmpty || kps1.length == 0 || kps2.length == 0) {
      desc1.dispose();
      desc2.dispose();
      return null;
    }

    final matcher = BFMatcher.create(type: NORM_HAMMING);
    final matches = matcher.match(desc1, desc2);
    matcher.dispose();
    desc1.dispose();
    desc2.dispose();

    // Collect horizontal displacements from good matches (distance < 50)
    final List<double> dxList = [];
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.distance > 50) continue;
      if (m.queryIdx >= kps1.length || m.trainIdx >= kps2.length) continue;
      final dx = (kps2[m.trainIdx].x - kps1[m.queryIdx].x).abs();
      dxList.add(dx);
    }

    if (dxList.length < 5) return null;

    // Median displacement
    dxList.sort();
    final medianDx = dxList[dxList.length ~/ 2];

    // overlap = (frameWidth - displacement) / frameWidth * 100
    return ((frameWidth - medianDx) / frameWidth * 100.0).clamp(0.0, 100.0);
  }
}
