/**
 * Shelf Panorama Stitching Engine
 * ================================
 * On-device linear stitching pipeline:
 *   1. Load + resize to working resolution
 *   2. Exposure normalisation (LAB L-channel gain)
 *   3. ORB features + KNN match + Lowe's ratio test
 *   4. findHomography + RANSAC
 *   5. Constrain: clamp perspective, reject rotation > 10°
 *   6. Cumulative transforms in frame-0 coordinate system
 *   7. Canvas sizing from warped corners
 *   8. warpPerspective + distance-transform feather blend
 *   9. Hough-line tilt correction
 *  10. Rectangular black-border crop
 */

#include <opencv2/opencv.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>
#include <tuple>

#define TAG  "ShelfStitcher"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

using namespace cv;

// ─── Config ───────────────────────────────────────────────────────────────────
static constexpr int    WORKING_WIDTH    = 1920;
static constexpr int    DETECT_WIDTH     = 800;
static constexpr int    N_FEATURES       = 4000;
static constexpr float  SCALE_FACTOR     = 1.2f;
static constexpr int    N_LEVELS         = 8;
static constexpr float  RATIO_THRESH     = 0.75f;
static constexpr int    MIN_INLIERS      = 30;
static constexpr double RANSAC_REPROJ    = 3.0;
static constexpr double MIN_GAIN         = 0.5;
static constexpr double MAX_GAIN         = 2.0;

// ─── Resize ───────────────────────────────────────────────────────────────────

static Mat resizeToWidth(const Mat& src, int w) {
    if (src.cols <= w) return src.clone();
    double s = (double)w / src.cols;
    Mat dst;
    resize(src, dst, Size(), s, s, INTER_AREA);
    return dst;
}

// ─── Exposure normalisation ───────────────────────────────────────────────────

static double meanLuminance(const Mat& bgr) {
    Mat lab;
    cvtColor(bgr, lab, COLOR_BGR2Lab);
    return mean(lab)[0];
}

static Mat normaliseExposure(const Mat& img, double refL) {
    double mL = meanLuminance(img);
    if (mL < 1.0) return img.clone();
    double gain = std::clamp(refL / mL, MIN_GAIN, MAX_GAIN);
    Mat lab;
    cvtColor(img, lab, COLOR_BGR2Lab);
    std::vector<Mat> ch;
    split(lab, ch);
    ch[0] *= gain;
    threshold(ch[0], ch[0], 255, 255, THRESH_TRUNC);
    merge(ch, lab);
    Mat result;
    cvtColor(lab, result, COLOR_Lab2BGR);
    return result;
}

// ─── Feature matching ─────────────────────────────────────────────────────────

static bool detectAndMatch(const Mat& prev, const Mat& curr,
                            std::vector<Point2f>& srcPts,
                            std::vector<Point2f>& dstPts) {
    double scale = std::min(1.0, (double)DETECT_WIDTH / prev.cols);

    Mat sPrev = resizeToWidth(prev, DETECT_WIDTH);
    Mat sCurr = resizeToWidth(curr, DETECT_WIDTH);
    Mat gPrev, gCurr;
    cvtColor(sPrev, gPrev, COLOR_BGR2GRAY);
    cvtColor(sCurr, gCurr, COLOR_BGR2GRAY);

    auto orb = ORB::create(N_FEATURES, SCALE_FACTOR, N_LEVELS);
    std::vector<KeyPoint> kp1, kp2;
    Mat des1, des2;
    orb->detectAndCompute(gPrev, noArray(), kp1, des1);
    orb->detectAndCompute(gCurr, noArray(), kp2, des2);

    if (des1.empty() || des2.empty() || kp1.size() < 8 || kp2.size() < 8) {
        LOGI("Keypoints too few: %zu vs %zu", kp1.size(), kp2.size());
        return false;
    }

    BFMatcher matcher(NORM_HAMMING);
    std::vector<std::vector<DMatch>> knn;
    matcher.knnMatch(des1, des2, knn, 2);

    for (auto& pair : knn) {
        if (pair.size() < 2) continue;
        if (pair[0].distance < RATIO_THRESH * pair[1].distance) {
            srcPts.push_back(kp2[pair[0].trainIdx].pt / scale);
            dstPts.push_back(kp1[pair[0].queryIdx].pt / scale);
        }
    }

    LOGI("Good matches: %zu", srcPts.size());
    return (int)srcPts.size() >= MIN_INLIERS;
}

// ─── Homography ───────────────────────────────────────────────────────────────

static Mat computeHomography(const Mat& prev, const Mat& curr) {
    std::vector<Point2f> srcPts, dstPts;
    if (!detectAndMatch(prev, curr, srcPts, dstPts)) return {};

    Mat mask;
    Mat H = findHomography(srcPts, dstPts, RANSAC, RANSAC_REPROJ, mask);
    if (H.empty()) return {};

    int inliers = countNonZero(mask);
    LOGI("RANSAC inliers: %d", inliers);
    if (inliers < MIN_INLIERS) return {};

    // Normalise by H[2][2]
    H /= H.at<double>(2, 2);

    // For linear shelf scanning: always use translation-only.
    // Accumulated rotation/perspective across many frames causes bowing distortion.
    double tx = H.at<double>(0, 2);
    double ty = H.at<double>(1, 2);

    // Clamp vertical drift — phone tilt during horizontal pan is camera shake,
    // not real content shift. Clamping ty prevents the center-arch distortion.
    double maxTy = prev.rows * 0.03;   // 3 % of frame height
    ty = std::clamp(ty, -maxTy, maxTy);

    double angle = std::abs(std::atan2(H.at<double>(1, 0), H.at<double>(0, 0)))
                   * 180.0 / CV_PI;
    LOGI("H: tx=%.1f ty=%.1f (clamped) rot=%.1f°", tx, ty, angle);

    Mat T = Mat::eye(3, 3, CV_64F);
    T.at<double>(0, 2) = tx;
    T.at<double>(1, 2) = ty;
    return T;
}

// ─── Canvas ───────────────────────────────────────────────────────────────────

static std::tuple<int, int, Mat>
computeCanvas(const std::vector<Mat>& frames,
              const std::vector<Mat>& Hcum) {
    float xMin = 0, yMin = 0, xMax = 0, yMax = 0;
    for (size_t i = 0; i < frames.size(); i++) {
        float w = (float)frames[i].cols, h = (float)frames[i].rows;
        std::vector<Point2f> corners = {{0,0},{0,h},{w,h},{w,0}};
        std::vector<Point2f> warped;
        perspectiveTransform(corners, warped, Hcum[i]);
        for (auto& p : warped) {
            xMin = std::min(xMin, p.x);  yMin = std::min(yMin, p.y);
            xMax = std::max(xMax, p.x);  yMax = std::max(yMax, p.y);
        }
    }
    int cW = std::clamp((int)std::ceil(xMax - xMin), 1, 40000);
    int cH = std::clamp((int)std::ceil(yMax - yMin), 1, 20000);

    Mat T = Mat::eye(3, 3, CV_64F);
    T.at<double>(0, 2) = -xMin;
    T.at<double>(1, 2) = -yMin;
    return {cW, cH, T};
}

// ─── Seam blend ───────────────────────────────────────────────────────────────
// Blends only a narrow strip (FEATHER px each side) around the seam centre.
// Outside the strip each frame's pixels are copied clean — eliminates ghosting
// that distance-transform blending causes when alignment isn't perfect.

static Mat nonBlackMask(const Mat& img) {
    Mat gray, mask;
    cvtColor(img, gray, COLOR_BGR2GRAY);
    threshold(gray, mask, 1, 255, THRESH_BINARY);
    return mask;
}

static void featherBlend(Mat& canvas, const Mat& warped,
                          Mat& canvasMask, const Mat& warpedMask) {
    const int FEATHER = 80;   // blend half-width in pixels

    // 1. Warped-only pixels → direct copy (no overlap, no blending needed)
    Mat invCanvas = ~canvasMask;
    Mat newOnly;
    bitwise_and(warpedMask, invCanvas, newOnly);
    warped.copyTo(canvas, newOnly);

    // 2. Find overlap region
    Mat overlap;
    bitwise_and(canvasMask, warpedMask, overlap);

    if (countNonZero(overlap) > 0) {
        // Find x-bounds of overlap
        std::vector<std::vector<Point>> contours;
        findContours(overlap, contours, RETR_EXTERNAL, CHAIN_APPROX_SIMPLE);
        int xOvL = canvas.cols, xOvR = 0;
        for (auto& c : contours) {
            Rect r = boundingRect(c);
            xOvL = std::min(xOvL, r.x);
            xOvR = std::max(xOvR, r.x + r.width);
        }

        if (xOvR > xOvL) {
            int seam = (xOvL + xOvR) / 2;

            // Right of feather zone → warped wins (new frame content)
            int copyStart = std::min(canvas.cols, seam + FEATHER);
            int copyEnd   = std::min(canvas.cols, xOvR);
            if (copyEnd > copyStart) {
                Rect rRight(copyStart, 0, copyEnd - copyStart, canvas.rows);
                warped(rRight).copyTo(canvas(rRight), overlap(rRight));
            }

            // Feather zone: linear gradient blend
            int fL = std::max(0, seam - FEATHER);
            int fR = std::min(canvas.cols - 1, seam + FEATHER);
            if (fR > fL) {
                Mat cvs32, warp32;
                canvas.convertTo(cvs32,  CV_32FC3);
                warped.convertTo(warp32, CV_32FC3);

                for (int x = fL; x <= fR; x++) {
                    float alpha = float(x - fL) / float(fR - fL); // 0=canvas, 1=warped
                    Mat cCol = cvs32.col(x);
                    Mat wCol = warp32.col(x);
                    Mat mCol = overlap.col(x);
                    if (countNonZero(mCol) == 0) continue;
                    Mat blendCol;
                    addWeighted(cCol, 1.0f - alpha, wCol, alpha, 0.0f, blendCol);
                    Mat blendCol8;
                    blendCol.convertTo(blendCol8, CV_8UC3);
                    blendCol8.copyTo(canvas.col(x), mCol);
                }
            }
        }
    }

    bitwise_or(canvasMask, warpedMask, canvasMask);
}

// ─── Tilt correction ──────────────────────────────────────────────────────────

static Mat straighten(const Mat& img) {
    Mat gray, edges;
    cvtColor(img, gray, COLOR_BGR2GRAY);
    Canny(gray, edges, 50, 150, 3);

    std::vector<Vec4i> lines;
    HoughLinesP(edges, lines, 1.0, CV_PI / 180.0, 200,
                img.cols / 10.0, 20.0);
    if (lines.empty()) return img.clone();

    std::vector<double> angles;
    for (auto& l : lines) {
        double dx = l[2] - l[0], dy = l[3] - l[1];
        if (std::abs(dx) < 5) continue;
        double a = std::atan2(dy, dx) * 180.0 / CV_PI;
        if (std::abs(a) < 15.0) angles.push_back(a);
    }
    if (angles.empty()) return img.clone();

    std::sort(angles.begin(), angles.end());
    double tilt = angles[angles.size() / 2];
    if (std::abs(tilt) < 0.2) return img.clone();

    LOGI("Tilt correction: %.2f°", tilt);
    Mat M = getRotationMatrix2D(
        Point2f(img.cols / 2.0f, img.rows / 2.0f), tilt, 1.0);
    Mat result;
    warpAffine(img, result, M, img.size(), INTER_LINEAR, BORDER_CONSTANT);
    return result;
}

// ─── Crop black borders ───────────────────────────────────────────────────────

static Mat cropBlack(const Mat& img) {
    Mat gray, thresh;
    cvtColor(img, gray, COLOR_BGR2GRAY);
    threshold(gray, thresh, 1, 255, THRESH_BINARY);

    int y1 = 0, y2 = img.rows - 1, x1 = 0, x2 = img.cols - 1;
    for (int y = 0; y < img.rows; y++)
        if (countNonZero(thresh.row(y)) == img.cols) { y1 = y; break; }
    for (int y = img.rows - 1; y >= 0; y--)
        if (countNonZero(thresh.row(y)) == img.cols) { y2 = y; break; }
    for (int x = 0; x < img.cols; x++)
        if (countNonZero(thresh.col(x)) == img.rows) { x1 = x; break; }
    for (int x = img.cols - 1; x >= 0; x--)
        if (countNonZero(thresh.col(x)) == img.rows) { x2 = x; break; }

    if (x2 <= x1 || y2 <= y1) {
        Rect r = boundingRect(thresh);
        return img(r).clone();
    }
    return img(Rect(x1, y1, x2 - x1 + 1, y2 - y1 + 1)).clone();
}

// ─── Main pipeline ────────────────────────────────────────────────────────────

static std::string runPipeline(const std::vector<std::string>& paths,
                                const std::string& outPath) {
    // 1. Load + resize
    std::vector<Mat> frames;
    for (auto& p : paths) {
        Mat img = imread(p, IMREAD_COLOR);
        if (img.empty()) { LOGI("Skip unreadable: %s", p.c_str()); continue; }
        frames.push_back(resizeToWidth(img, WORKING_WIDTH));
    }
    if (frames.size() < 2) return "Need at least 2 valid images.";

    LOGI("Loaded %zu frames", frames.size());

    // 2. Exposure normalisation
    double refL = meanLuminance(frames[0]);
    for (size_t i = 1; i < frames.size(); i++)
        frames[i] = normaliseExposure(frames[i], refL);

    // 3. Pairwise homographies (skip failures and near-duplicate frames)
    std::vector<int> usedIdx = {0};
    std::vector<Mat> usedH   = {Mat::eye(3, 3, CV_64F)};  // H[0] = identity
    const double MIN_TX_RATIO = 0.04;  // skip frame if it moves < 4% of width

    for (size_t i = 1; i < frames.size(); i++) {
        Mat H = computeHomography(frames[usedIdx.back()], frames[i]);
        if (H.empty()) { LOGI("Frame %zu skipped (no match)", i); continue; }

        double tx = std::abs(H.at<double>(0, 2));
        double minTx = frames[i].cols * MIN_TX_RATIO;
        if (tx < minTx) {
            LOGI("Frame %zu skipped (tx=%.1f < %.1f, near-duplicate)", i, tx, minTx);
            continue;
        }

        usedIdx.push_back((int)i);
        usedH.push_back(H);
    }
    if (usedIdx.size() < 2) return "Could not match any frame pair.";

    // Build valid frame list
    std::vector<Mat> valid;
    for (int idx : usedIdx) valid.push_back(frames[idx]);

    // 4. Cumulative transforms
    std::vector<Mat> Hcum(valid.size());
    Hcum[0] = Mat::eye(3, 3, CV_64F);
    for (size_t i = 1; i < valid.size(); i++)
        Hcum[i] = Hcum[i-1] * usedH[i];   // 3×3 matrix multiply

    // 5. Canvas
    auto [cW, cH, T] = computeCanvas(valid, Hcum);
    LOGI("Canvas: %d × %d", cW, cH);

    Mat canvas     = Mat::zeros(cH, cW, CV_8UC3);
    Mat canvasMask = Mat::zeros(cH, cW, CV_8U);

    // 6. Warp + blend each frame
    for (size_t i = 0; i < valid.size(); i++) {
        Mat Hfinal = T * Hcum[i];
        Mat warped;
        warpPerspective(valid[i], warped, Hfinal, Size(cW, cH),
                        INTER_LINEAR, BORDER_CONSTANT, Scalar::all(0));
        Mat wMask = nonBlackMask(warped);
        featherBlend(canvas, warped, canvasMask, wMask);
        LOGI("Blended frame %zu / %zu", i + 1, valid.size());
    }

    // 7. Tilt
    Mat straight = straighten(canvas);

    // 8. Crop
    Mat cropped = cropBlack(straight);

    // 9. Write
    std::vector<int> params = {IMWRITE_JPEG_QUALITY, 95};
    if (!imwrite(outPath, cropped, params))
        return "Failed to write: " + outPath;

    LOGI("Done: %s  (%d×%d)", outPath.c_str(), cropped.cols, cropped.rows);
    return "";
}

// ─── JNI bridge ───────────────────────────────────────────────────────────────

extern "C"
JNIEXPORT jstring JNICALL
Java_com_simplr_shelf_1monitor_1app_NativeStitcher_stitchImages(
        JNIEnv* env, jobject /*thiz*/,
        jobjectArray pathArray,
        jstring jOutputPath) {

    jsize n = env->GetArrayLength(pathArray);
    std::vector<std::string> paths;
    paths.reserve(n);
    for (jsize i = 0; i < n; i++) {
        auto js = (jstring)env->GetObjectArrayElement(pathArray, i);
        const char* cs = env->GetStringUTFChars(js, nullptr);
        paths.emplace_back(cs);
        env->ReleaseStringUTFChars(js, cs);
        env->DeleteLocalRef(js);
    }

    const char* outCs = env->GetStringUTFChars(jOutputPath, nullptr);
    std::string outPath(outCs);
    env->ReleaseStringUTFChars(jOutputPath, outCs);

    LOGI("stitchImages: %d images → %s", n, outPath.c_str());

    std::string err = runPipeline(paths, outPath);
    return env->NewStringUTF(err.empty() ? outPath.c_str() : "");
}
