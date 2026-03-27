import 'dart:math' as math;
import 'package:opencv_dart/opencv.dart';

/// On-device stitching isolate.
///
/// Strategy:
///   1. Try OpenCV Stitcher (SCANS mode) — best quality, may fail on repetitive scenes.
///   2. Fall back to manual pipeline:
///        ORB + KNN match + Lowe's ratio → findHomography + RANSAC →
///        warpPerspective with growing canvas → 8-strip gradient blend →
///        Hough tilt correction → black-border crop.
class ProfessionalStitchIsolate {
  static const int _workingWidth   = 1000; // canvas resolution
  static const int _detectWidth    = 500;  // downscale for feature detection
  static const int _nFeatures      = 3000;
  static const double _ratioThresh  = 0.75;
  static const int _minInliers      = 30;
  static const double _ransacReproj = 4.0;

  // ── Entry points ────────────────────────────────────────────────────────────

  static Map<String, dynamic> run(Map<String, dynamic> params) {
    final paths     = params['imagePaths'] as List<String>;
    final outputDir = params['outputDir']  as String;
    final List<Mat> raw = [];
    try {
      for (final p in paths) {
        final img = imread(p);
        if (img.isEmpty || img.rows < 10 || img.cols < 10) { img.dispose(); continue; }
        raw.add(_resize(img, _workingWidth));
      }
      if (raw.length < 2) {
        _disposeAll(raw);
        return {'success': false, 'error': 'Need at least 2 valid images.'};
      }
      final r = _stitch(raw, outputDir);
      _disposeAll(raw);
      return r;
    } catch (e) {
      _disposeAll(raw);
      return {'success': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> runFrames(List<Mat> frames, String outputDir) {
    if (frames.length < 2) return {'success': false, 'error': 'Need ≥ 2 frames.'};
    try {
      final scaled = [for (final f in frames) _resize(f.clone(), _workingWidth)];
      final r = _stitch(scaled, outputDir);
      _disposeAll(scaled);
      return r;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ── Dispatch ────────────────────────────────────────────────────────────────

  static Map<String, dynamic> _stitch(List<Mat> frames, String outputDir) {
    // Go straight to manual pipeline — the OpenCV Stitcher uses cylindrical
    // warping (SCANS mode) which causes the curved/bowed top/bottom edges.
    // For flat linear shelf scanning, translation-only homography is correct.
    return _stitchManual(frames, outputDir);
  }

  // ── Manual pipeline (fallback) ───────────────────────────────────────────────

  static Map<String, dynamic> _stitchManual(List<Mat> frames, String outputDir) {
    // 1. Exposure normalisation
    final normed = _normalizeExposure(frames);

    // 2. Pairwise homographies (skip failures and near-duplicate frames)
    final List<int> usedIdx   = [0];
    final List<Mat> usedH     = [Mat.eye(3, 3, MatType.CV_64FC1)]; // H[0] = identity
    const double minTxRatio   = 0.04; // skip if frame moves < 4% of width

    for (int i = 1; i < normed.length; i++) {
      final H = _computeHomography(normed[usedIdx.last], normed[i]);
      if (H == null) continue;
      final tx = H.at<double>(0, 2).abs();
      if (tx < normed[i].cols * minTxRatio) {
        H.dispose();
        continue; // near-duplicate frame — skip to avoid ghosting
      }
      usedIdx.add(i);
      usedH.add(H);
    }

    if (usedIdx.length < 2) {
      _disposeAll(normed);
      _disposeAll(usedH);
      return {
        'success': false,
        'error': 'Could not match any frame pair.\n'
            'Ensure 40 %+ overlap and slow, steady panning.',
      };
    }

    final valid = [for (final i in usedIdx) normed[i]];

    // 3. Cumulative transforms in frame-0 coordinate system
    final List<Mat> Hcum = [Mat.eye(3, 3, MatType.CV_64FC1)];
    for (int i = 1; i < usedH.length; i++) {
      Hcum.add(_mul3x3(Hcum.last, usedH[i]));
    }
    _disposeAll(usedH);

    // 4. Canvas bounding box + translation offset
    final (cW, cH, T) = _computeCanvas(valid, Hcum);

    // 5. Warp + blend
    final canvas     = Mat.zeros(cH, cW, MatType.CV_8UC3);
    final canvasMask = Mat.zeros(cH, cW, MatType.CV_8UC1);

    for (int i = 0; i < valid.length; i++) {
      final Hf     = _mul3x3(T, Hcum[i]);
      final warped = warpPerspective(valid[i], Hf, (cW, cH));
      Hf.dispose();

      final wMask = _nonBlackMask(warped);
      _blendPaste(canvas, warped, canvasMask, wMask);
      wMask.dispose();
      warped.dispose();
    }

    _disposeAll(Hcum);
    T.dispose();
    _disposeAll(normed);

    // 6. Tilt correction
    final straight = _straighten(canvas);
    canvas.dispose();
    canvasMask.dispose();

    // 7. Crop
    final cropped = _cropBlack(straight);
    straight.dispose();

    final path = '$outputDir/panorama_${DateTime.now().millisecondsSinceEpoch}.jpeg';
    imwrite(path, cropped);
    cropped.dispose();

    return {
      'success': true,
      'filePath': path,
      'framesUsed': usedIdx.length,
      'method': 'orb_homography',
    };
  }

  // ── Homography estimation ────────────────────────────────────────────────────

  static Mat? _computeHomography(Mat prev, Mat curr) {
    // Downscale for fast feature detection
    final scale = math.min(1.0, _detectWidth / prev.cols);
    final sPrev = _resize(prev.clone(), _detectWidth);
    final sCurr = _resize(curr.clone(), _detectWidth);

    final gPrev = cvtColor(sPrev, COLOR_BGR2GRAY);
    final gCurr = cvtColor(sCurr, COLOR_BGR2GRAY);
    sPrev.dispose(); sCurr.dispose();

    final orb = ORB.create(nFeatures: _nFeatures);
    final (kp1, des1) = orb.detectAndCompute(gPrev, Mat.empty());
    final (kp2, des2) = orb.detectAndCompute(gCurr, Mat.empty());
    gPrev.dispose(); gCurr.dispose();

    if (des1.isEmpty || des2.isEmpty || kp1.length < 8 || kp2.length < 8) {
      des1.dispose(); des2.dispose();
      return null;
    }

    // KNN match with Lowe's ratio test
    final matcher    = BFMatcher.create(type: NORM_HAMMING);
    final knnMatches = matcher.knnMatch(des1, des2, 2);
    des1.dispose(); des2.dispose();

    final srcList = <(double, double)>[];
    final dstList = <(double, double)>[];

    for (int i = 0; i < knnMatches.length; i++) {
      final pair = knnMatches[i];
      if (pair.length < 2) continue;
      final m = pair[0], n = pair[1];
      if (m.distance < _ratioThresh * n.distance) {
        // Scale coords back to working resolution
        srcList.add((kp2[m.trainIdx].x / scale, kp2[m.trainIdx].y / scale));
        dstList.add((kp1[m.queryIdx].x / scale, kp1[m.queryIdx].y / scale));
      }
    }

    if (srcList.length < _minInliers) return null;

    // Build CV_32FC2 point Mats for findHomography
    final srcMat = _buildPointMat(srcList);
    final dstMat = _buildPointMat(dstList);

    final H = findHomography(
      srcMat, dstMat,
      method: RANSAC,
      ransacReprojThreshold: _ransacReproj,
    );
    srcMat.dispose(); dstMat.dispose();

    if (H.isEmpty) return null;
    final T = _constrainH(H);
    if (T == null) return null;

    // Clamp vertical drift — phone tilt during a horizontal pan is camera shake.
    // Without clamping, ty accumulates and arches the center of the panorama.
    final ty = T.at<double>(1, 2);
    final maxTy = prev.rows * 0.03; // 3% of frame height
    T.set<double>(1, 2, ty.clamp(-maxTy, maxTy));
    return T;
  }

  /// Creates a (N, 1, CV_32FC2) Mat from a list of 2D points.
  static Mat _buildPointMat(List<(double, double)> pts) {
    final xm = Mat.zeros(pts.length, 1, MatType.CV_32FC1);
    final ym = Mat.zeros(pts.length, 1, MatType.CV_32FC1);
    for (int i = 0; i < pts.length; i++) {
      xm.set<double>(i, 0, pts[i].$1);
      ym.set<double>(i, 0, pts[i].$2);
    }
    // merge to (N, 1, CV_32FC2)
    final merged = merge(VecMat.fromList([xm, ym]));
    xm.dispose(); ym.dispose();
    return merged;
  }

  /// Force translation-only homography for linear shelf scanning.
  /// Accumulated rotation/perspective across many frames causes bowing — discard it.
  static Mat? _constrainH(Mat H) {
    final h22 = H.at<double>(2, 2);
    if (h22.abs() < 1e-10) { H.dispose(); return null; }

    final tx = H.at<double>(0, 2) / h22;
    final ty = H.at<double>(1, 2) / h22;
    H.dispose();

    final T = Mat.eye(3, 3, MatType.CV_64FC1);
    T.set<double>(0, 2, tx);
    T.set<double>(1, 2, ty);
    return T;
  }

  // ── Canvas geometry ──────────────────────────────────────────────────────────

  static (int, int, Mat) _computeCanvas(List<Mat> frames, List<Mat> Hcum) {
    double xMin = 0, yMin = 0, xMax = 0, yMax = 0;

    for (int i = 0; i < frames.length; i++) {
      final w = frames[i].cols.toDouble();
      final h = frames[i].rows.toDouble();
      for (final (cx, cy) in [(0.0,0.0),(0.0,h),(w,h),(w,0.0)]) {
        final (px, py) = _perspTransform(Hcum[i], cx, cy);
        xMin = math.min(xMin, px); yMin = math.min(yMin, py);
        xMax = math.max(xMax, px); yMax = math.max(yMax, py);
      }
    }

    final cW = (xMax - xMin).ceil().clamp(1, 40000).toInt();
    final cH = (yMax - yMin).ceil().clamp(1, 20000).toInt();
    final T  = Mat.eye(3, 3, MatType.CV_64FC1);
    T.set<double>(0, 2, -xMin);
    T.set<double>(1, 2, -yMin);
    return (cW, cH, T);
  }

  static (double, double) _perspTransform(Mat H, double x, double y) {
    final wx = H.at<double>(0,0)*x + H.at<double>(0,1)*y + H.at<double>(0,2);
    final wy = H.at<double>(1,0)*x + H.at<double>(1,1)*y + H.at<double>(1,2);
    final ww = H.at<double>(2,0)*x + H.at<double>(2,1)*y + H.at<double>(2,2);
    return (wx/ww, wy/ww);
  }

  // ── 3×3 matrix multiply (manual — avoids matMul API uncertainty) ─────────────

  static Mat _mul3x3(Mat A, Mat B) {
    final C = Mat.zeros(3, 3, MatType.CV_64FC1);
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        double s = 0;
        for (int k = 0; k < 3; k++) s += A.at<double>(i, k) * B.at<double>(k, j);
        C.set<double>(i, j, s);
      }
    }
    return C;
  }

  // ── Narrow seam blend ────────────────────────────────────────────────────────
  // Blends only FEATHER pixels each side of the seam centre.
  // Outside that strip, each frame's pixels are copied clean.
  // This prevents ghosting that occurs when blending large misaligned overlaps.

  static const int _feather = 80;

  static void _blendPaste(Mat canvas, Mat warped, Mat canvasMask, Mat warpedMask) {
    final w = math.min(warped.cols, canvas.cols).toInt();
    final h = math.min(warped.rows, canvas.rows).toInt();
    if (w <= 0 || h <= 0) return;

    // 1. Warped-only region → direct copy
    final invCanvas = bitwiseNOT(canvasMask);
    final newOnly   = bitwiseAND(warpedMask, invCanvas);
    invCanvas.dispose();
    warped.copyTo(canvas, mask: newOnly);
    newOnly.dispose();

    // 2. Overlap region
    final overlap = bitwiseAND(canvasMask, warpedMask);

    if (countNonZero(overlap) > 0) {
      final (ovContours, _) = findContours(overlap, RETR_EXTERNAL, CHAIN_APPROX_SIMPLE);
      if (ovContours.isNotEmpty) {
        int xOvL = canvas.cols, xOvR = 0;
        for (int i = 0; i < ovContours.length; i++) {
          final r = boundingRect(ovContours[i]);
          xOvL = math.min(xOvL, r.x);
          xOvR = math.max(xOvR, r.x + r.width);
        }

        if (xOvR > xOvL) {
          final seam = (xOvL + xOvR) ~/ 2;

          // Right of feather zone → warped wins
          final copyStart = math.min(canvas.cols, seam + _feather);
          final copyEnd   = math.min(canvas.cols, xOvR);
          if (copyEnd > copyStart) {
            final rRight = Rect(copyStart, 0, copyEnd - copyStart, canvas.rows);
            warped.region(rRight).copyTo(canvas.region(rRight),
                mask: overlap.region(rRight));
          }

          // Feather zone: linear gradient
          final fL = math.max(0, seam - _feather);
          final fR = math.min(canvas.cols, seam + _feather);
          final featherW = fR - fL;
          if (featherW > 0) {
            const steps = 16;
            for (int s = 0; s < steps; s++) {
              final x0 = fL + (featherW * s / steps).round();
              final x1 = fL + (featherW * (s + 1) / steps).round();
              final sw = x1 - x0;
              if (sw <= 0 || x0 >= canvas.cols) continue;
              final alpha = (s + 0.5) / steps;
              final strip = Rect(x0, 0, sw, canvas.rows);
              final cStrip = canvas.region(strip);
              final wStrip = warped.region(strip);
              final mStrip = overlap.region(strip);
              if (countNonZero(mStrip) == 0) continue;
              final blended = addWeighted(cStrip, 1.0 - alpha, wStrip, alpha, 0.0);
              blended.copyTo(cStrip, mask: mStrip);
              blended.dispose();
            }
          }
        }
      }
    }
    overlap.dispose();

    // Update canvas mask
    final newMask = bitwiseOR(canvasMask, warpedMask);
    newMask.copyTo(canvasMask);
    newMask.dispose();
  }

  // ── Exposure normalisation (LAB L-channel) ───────────────────────────────────

  static List<Mat> _normalizeExposure(List<Mat> frames) {
    final refMean = _meanLuminance(frames[0]);
    return [
      for (final img in frames) () {
        final m = _meanLuminance(img);
        if (m < 1.0 || (m - refMean).abs() < 5.0) return img.clone();
        final scale = (refMean / m).clamp(0.5, 2.0);
        final lab = cvtColor(img, COLOR_BGR2Lab);
        final result = cvtColor(
          addWeighted(lab, scale, Mat.zeros(img.rows, img.cols, img.type), 0, 0),
          COLOR_Lab2BGR,
        );
        lab.dispose();
        return result;
      }(),
    ];
  }

  static double _meanLuminance(Mat img) {
    final gray = cvtColor(img, COLOR_BGR2GRAY);
    final (m, _) = meanStdDev(gray);
    gray.dispose();
    final v = m.val1;
    m.dispose();
    return v;
  }

  // ── Tilt correction (Hough) ──────────────────────────────────────────────────

  static Mat _straighten(Mat img) {
    try {
      final gray  = cvtColor(img, COLOR_BGR2GRAY);
      final edges = canny(gray, 50, 150);
      gray.dispose();
      final lines = HoughLinesP(edges, 1.0, math.pi / 180, 200,
          minLineLength: img.cols / 10.0, maxLineGap: 20.0);
      edges.dispose();

      if (lines.rows == 0) return img.clone();

      final angles = <double>[];
      for (int i = 0; i < lines.rows; i++) {
        final dx = lines.at<int>(i, 2) - lines.at<int>(i, 0);
        final dy = lines.at<int>(i, 3) - lines.at<int>(i, 1);
        if (dx.abs() < 5) continue;
        final a = math.atan2(dy.toDouble(), dx.toDouble()) * 180 / math.pi;
        if (a.abs() < 15) angles.add(a);
      }
      lines.dispose();

      if (angles.isEmpty) return img.clone();
      angles.sort();
      final tilt = angles[angles.length ~/ 2];
      if (tilt.abs() < 0.2) return img.clone();

      final M = getRotationMatrix2D(
        Point2f(img.cols / 2.0, img.rows / 2.0), tilt, 1.0);
      final result = warpAffine(img, M, (img.cols, img.rows));
      M.dispose();
      return result;
    } catch (_) {
      return img.clone();
    }
  }

  // ── Crop black borders (largest inscribed rectangle) ─────────────────────────

  static Mat _cropBlack(Mat src) {
    final gray = cvtColor(src, COLOR_BGR2GRAY);
    final (_, thresh) = threshold(gray, 1, 255, THRESH_BINARY);
    gray.dispose();

    // Scan full rows top→bottom and bottom→top to find first fully non-black rows.
    int t = 0, b = src.rows - 1;
    for (int y = 0; y < src.rows; y++) {
      if (countNonZero(thresh.row(y)) == src.cols) { t = y; break; }
    }
    for (int y = src.rows - 1; y > t; y--) {
      if (countNonZero(thresh.row(y)) == src.cols) { b = y; break; }
    }

    // Scan full columns using the [t, b] band so corners don't shrink left/right.
    final h = b - t + 1;
    int l = 0, r = src.cols - 1;
    if (h > 0) {
      for (int x = 0; x < src.cols; x++) {
        if (countNonZero(thresh.region(Rect(x, t, 1, h))) == h) { l = x; break; }
      }
      for (int x = src.cols - 1; x > l; x--) {
        if (countNonZero(thresh.region(Rect(x, t, 1, h))) == h) { r = x; break; }
      }
    }
    thresh.dispose();

    // Fallback to full extent if inscribed rect is tiny
    final w = r - l + 1;
    final ch = b - t + 1;
    if (w < src.cols * 0.3 || ch < src.rows * 0.3) return src.clone();

    return src.region(Rect(l, t, w, ch)).clone();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  static Mat _nonBlackMask(Mat img) {
    final gray = cvtColor(img, COLOR_BGR2GRAY);
    final (_, mask) = threshold(gray, 1, 255, THRESH_BINARY);
    gray.dispose();
    return mask;
  }

  static Mat _resize(Mat src, int maxEdge) {
    final long = math.max(src.cols, src.rows);
    if (long <= maxEdge) return src;
    final s = maxEdge / long;
    final w = (src.cols * s).round().clamp(1, maxEdge);
    final h = (src.rows * s).round().clamp(1, maxEdge);
    final dst = resize(src, (w, h));
    src.dispose();
    return dst;
  }

  static void _disposeAll(List<Mat> mats) {
    for (final m in mats) m.dispose();
    mats.clear();
  }
}
