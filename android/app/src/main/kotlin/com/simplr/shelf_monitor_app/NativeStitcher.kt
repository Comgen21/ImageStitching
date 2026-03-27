package com.simplr.shelf_monitor_app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Kotlin wrapper around the native C++ stitcher (shelf_stitcher.so).
 *
 * Usage:
 *   val path = NativeStitcher().stitch(imagePaths, outputDir)
 */
class NativeStitcher {

    companion object {
        /** True only when shelf_stitcher.so was linked successfully. */
        var isAvailable: Boolean = false
            private set

        init {
            try {
                System.loadLibrary("shelf_stitcher")
                isAvailable = true
            } catch (e: UnsatisfiedLinkError) {
                android.util.Log.w(
                    "NativeStitcher",
                    "shelf_stitcher.so not found — run setup_opencv_android.bat and rebuild."
                )
            }
        }
    }

    /**
     * JNI function implemented in stitcher.cpp.
     *
     * @param paths      Array of absolute local file paths to the input images.
     * @param outputPath Absolute path where the stitched JPEG should be written.
     * @return           The output path on success, or an empty string on failure.
     */
    external fun stitchImages(paths: Array<String>, outputPath: String): String

    /**
     * Suspending convenience wrapper.
     *
     * Runs the native stitcher on [Dispatchers.IO] and returns the output path.
     *
     * @param imagePaths List of absolute paths to input images (must be ≥ 2).
     * @param outputDir  Directory in which to place the result file.
     * @return           Absolute path of the saved panorama JPEG.
     * @throws Exception if stitching fails or the output is empty.
     */
    suspend fun stitch(imagePaths: List<String>, outputDir: String): String {
        return withContext(Dispatchers.IO) {
            val outFile = File(outputDir, "panorama_${System.currentTimeMillis()}.jpg")
            // Ensure the output directory exists
            outFile.parentFile?.mkdirs()

            val result = stitchImages(imagePaths.toTypedArray(), outFile.absolutePath)

            if (result.isNullOrEmpty()) {
                throw Exception(
                    "Native stitcher failed. Check logcat tag 'ShelfStitcher' for details."
                )
            }

            result
        }
    }
}
