package com.simplr.shelf_monitor_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineExceptionHandler
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.simplr.shelf_monitor_app/stitch"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "stitchImages" -> {
                    @Suppress("UNCHECKED_CAST")
                    val paths: List<String> = call.argument<List<String>>("paths")
                        ?: run {
                            result.error("INVALID_ARGS", "Missing required argument 'paths'", null)
                            return@setMethodCallHandler
                        }

                    val outputDir: String = call.argument<String>("outputDir")
                        ?: run {
                            result.error("INVALID_ARGS", "Missing required argument 'outputDir'", null)
                            return@setMethodCallHandler
                        }

                    if (paths.size < 2) {
                        result.error("INVALID_ARGS",
                            "At least 2 image paths are required, got ${paths.size}", null)
                        return@setMethodCallHandler
                    }

                    val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
                        result.error("STITCH_FAILED",
                            throwable.message ?: "Unknown error in coroutine", null)
                    }

                    lifecycleScope.launch(exceptionHandler) {
                        try {
                            // Fix EXIF orientation before passing to native stitcher.
                            // OpenCV imread() ignores EXIF rotation tags — pre-rotate here.
                            val correctedPaths = withContext(Dispatchers.IO) {
                                correctExifOrientations(paths, outputDir)
                            }
                            val outputPath = NativeStitcher().stitch(correctedPaths, outputDir)

                            // Clean up temp-corrected files
                            withContext(Dispatchers.IO) {
                                correctedPaths.forEach { p ->
                                    if (p != paths[correctedPaths.indexOf(p)]) {
                                        File(p).delete()
                                    }
                                }
                            }

                            result.success(outputPath)
                        } catch (e: Exception) {
                            result.error("STITCH_FAILED",
                                e.message ?: "Native stitcher threw an exception", null)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * For each path, reads the EXIF orientation and if the image needs rotation,
     * writes a corrected JPEG to [outputDir]/exif_corrected_N.jpg and returns
     * that path. Images that are already upright are returned unchanged.
     */
    private fun correctExifOrientations(
        paths: List<String>,
        outputDir: String
    ): List<String> {
        val corrected = mutableListOf<String>()
        val tmpDir = File(outputDir, "exif_tmp").also { it.mkdirs() }

        paths.forEachIndexed { idx, path ->
            val rotation = getExifRotation(path)
            if (rotation == 0f) {
                corrected.add(path)
                return@forEachIndexed
            }

            // Rotate and save to temp file
            val opts = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.RGB_565 }
            val bmp = BitmapFactory.decodeFile(path, opts) ?: run {
                corrected.add(path)  // can't decode — pass original
                return@forEachIndexed
            }

            val matrix = Matrix().apply { postRotate(rotation) }
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
            bmp.recycle()

            val tmpFile = File(tmpDir, "frame_${idx}.jpg")
            FileOutputStream(tmpFile).use { out ->
                rotated.compress(Bitmap.CompressFormat.JPEG, 95, out)
            }
            rotated.recycle()

            corrected.add(tmpFile.absolutePath)
        }

        return corrected
    }

    /** Returns the clockwise rotation degrees needed to make the image upright. */
    private fun getExifRotation(path: String): Float {
        return try {
            val exif = ExifInterface(path)
            when (exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )) {
                ExifInterface.ORIENTATION_ROTATE_90  -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                ExifInterface.ORIENTATION_TRANSPOSE  -> 90f
                ExifInterface.ORIENTATION_TRANSVERSE -> 270f
                else -> 0f
            }
        } catch (e: Exception) {
            0f
        }
    }
}
