package com.orailnoor.privateagent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.File

/**
 * Screen recording over MediaProjection (P6).
 *
 * THE CONSENT CONSTRAINT, because it shapes everything else here.
 *
 * MediaProjection cannot be granted silently. Android shows a system dialog that a HUMAN must
 * tap, and it can only be raised from a foreground Activity. A remote agent cannot tap it, and
 * nothing on the bridge can conjure it. So recording is the one primitive on this device that
 * is not fully remote — the token is captured once and cached for the life of the app process,
 * and a recording asked for without one is REFUSED with a code that says exactly that rather
 * than hanging, timing out, or returning an empty file.
 *
 * That is also why recording must never sit on a scheduled path: a 03:00 mission that needs a
 * human to tap a dialog is a mission that fails every night.
 *
 * State is process-static because the token is. If the process dies the consent dies with it,
 * which is the system's design, not ours.
 */
object ScreenRecorder {

    /** The consent result, cached for this process. Null until a human has tapped Allow. */
    private var consentCode: Int = Activity.RESULT_CANCELED
    private var consentData: Intent? = null

    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null
    private var outputFile: File? = null
    private var startedAtMs: Long = 0L
    private var maxSeconds: Int = 0

    /** Codes returned to the bridge. Stable strings — the bridge maps them to messages. */
    const val ERR_NO_CONSENT = "RECORD_CONSENT_REQUIRED"
    const val ERR_BUSY = "RECORD_ALREADY_RUNNING"
    const val ERR_NOT_RUNNING = "RECORD_NOT_RUNNING"
    const val ERR_FAILED = "RECORD_FAILED"

    @Synchronized
    fun hasConsent(): Boolean = consentData != null && consentCode == Activity.RESULT_OK

    @Synchronized
    fun rememberConsent(resultCode: Int, data: Intent?) {
        if (resultCode == Activity.RESULT_OK && data != null) {
            consentCode = resultCode
            consentData = data
        }
    }

    @Synchronized
    fun isRecording(): Boolean = recorder != null

    /** Intent that raises the system consent dialog. Must be started from an Activity. */
    fun consentIntent(context: Context): Intent {
        val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        return mgr.createScreenCaptureIntent()
    }

    @Synchronized
    fun status(nowMs: Long): Map<String, Any?> = mapOf(
        "recording" to isRecording(),
        "has_consent" to hasConsent(),
        "elapsed_s" to if (isRecording()) ((nowMs - startedAtMs) / 1000).toInt() else 0,
        "max_s" to if (isRecording()) maxSeconds else 0,
        "path" to outputFile?.absolutePath,
    )

    /**
     * Begin recording. Throws with one of the ERR_* codes; the caller turns it into a channel
     * error. `scale` shrinks the captured resolution — the A20e is a 720x1560 phone and a
     * full-resolution H264 stream is larger than anything downstream wants.
     */
    @Synchronized
    fun start(context: Context, maxS: Int, scale: Double, nowMs: Long): String {
        if (isRecording()) throw IllegalStateException(ERR_BUSY)
        if (!hasConsent()) throw IllegalStateException(ERR_NO_CONSENT)

        val metrics = screenMetrics(context)
        // Encoders reject odd dimensions. Rounding to even is not cosmetic: an odd width
        // fails at prepare() with an opaque error that looks like a permission problem.
        val w = ((metrics.widthPixels * scale).toInt() / 2) * 2
        val h = ((metrics.heightPixels * scale).toInt() / 2) * 2
        val dpi = metrics.densityDpi

        val dir = File(context.getExternalFilesDir(null), "bridge/recordings")
        dir.mkdirs()
        val file = File(dir, "rec-$nowMs.mp4")

        @Suppress("DEPRECATION")
        val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            MediaRecorder()
        }

        try {
            rec.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setOutputFile(file.absolutePath)
            rec.setVideoSize(w, h)
            rec.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            rec.setVideoEncodingBitRate(4_000_000)
            rec.setVideoFrameRate(24)
            if (maxS > 0) rec.setMaxDuration(maxS * 1000)
            rec.prepare()
        } catch (e: Throwable) {
            runCatching { rec.release() }
            throw IllegalStateException("$ERR_FAILED: could not prepare the encoder (${e.message})")
        }

        val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        // A fresh MediaProjection per recording, from the cached token. A projection cannot be
        // reused after it is stopped, but the CONSENT can — which is what "one tap per process
        // life" actually means.
        val proj = mgr.getMediaProjection(consentCode, consentData!!)
            ?: run {
                runCatching { rec.release() }
                throw IllegalStateException("$ERR_FAILED: the system refused the projection token")
            }

        val vd = try {
            proj.createVirtualDisplay(
                "agent-record",
                w, h, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                rec.surface, null, null,
            )
        } catch (e: Throwable) {
            runCatching { rec.release() }
            runCatching { proj.stop() }
            throw IllegalStateException("$ERR_FAILED: virtual display (${e.message})")
        } ?: run {
            // createVirtualDisplay returns null rather than throwing when the system declines.
            // Treating that as success would leave a recorder running against no surface and
            // produce a zero-byte file at stop().
            runCatching { rec.release() }
            runCatching { proj.stop() }
            throw IllegalStateException("$ERR_FAILED: the system returned no virtual display")
        }

        try {
            rec.start()
        } catch (e: Throwable) {
            runCatching { vd.release() }
            runCatching { rec.release() }
            runCatching { proj.stop() }
            throw IllegalStateException("$ERR_FAILED: recorder did not start (${e.message})")
        }

        projection = proj
        recorder = rec
        display = vd
        outputFile = file
        startedAtMs = nowMs
        maxSeconds = maxS
        return file.absolutePath
    }

    /**
     * Stop and return the finished file.
     *
     * MediaRecorder.stop() throws when it has captured no frames — a recording stopped within
     * a few hundred milliseconds of starting produces a zero-byte file and an exception. That
     * is reported as a failure rather than handed back as a valid-looking empty MP4, because
     * an artifact that opens to nothing is worse than an error.
     */
    @Synchronized
    fun stop(): File {
        val rec = recorder ?: throw IllegalStateException(ERR_NOT_RUNNING)
        val file = outputFile

        var stopError: Throwable? = null
        try {
            rec.stop()
        } catch (e: Throwable) {
            stopError = e
        }
        runCatching { rec.reset() }
        runCatching { rec.release() }
        runCatching { display?.release() }
        runCatching { projection?.stop() }

        recorder = null
        display = null
        projection = null
        outputFile = null
        startedAtMs = 0L
        maxSeconds = 0

        if (file == null || !file.exists() || file.length() == 0L) {
            throw IllegalStateException(
                "$ERR_FAILED: the recording captured no frames" +
                    (stopError?.let { " (${it.message})" } ?: "")
            )
        }
        return file
    }

    /** Release everything without returning a file — used when the app is going away. */
    @Synchronized
    fun abandon() {
        runCatching { recorder?.reset() }
        runCatching { recorder?.release() }
        runCatching { display?.release() }
        runCatching { projection?.stop() }
        recorder = null
        display = null
        projection = null
        outputFile = null
        startedAtMs = 0L
        maxSeconds = 0
    }

    @Suppress("DEPRECATION")
    private fun screenMetrics(context: Context): DisplayMetrics {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val m = DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(m)
        return m
    }
}
