package com.orailnoor.privateagent

import android.app.Activity
import android.accessibilityservice.AccessibilityService
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.util.concurrent.Executors

/**
 * "com.privateagent/device" — the P2 primitive surface. The bridge sends one typed primitive,
 * this handler performs it and reports what the phone observed. Nothing here is allowed to throw
 * into the channel: every failure becomes a stable error code.
 *
 * All work runs off the platform thread (waits, gesture completion and screenshots all block),
 * and every result is posted back on the main looper because Flutter requires it.
 */
class DeviceChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.privateagent/device"

        /** Give the UI a beat to react before we fingerprint, so "did it change?" is meaningful. */
        private const val SETTLE_MS = 250L

        /** startActivityForResult code for the MediaProjection consent dialog. */
        const val RECORD_CONSENT_REQUEST = 4301
    }

    private val appContext: Context = activity.applicationContext
    private val worker = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    private class ChannelError(val code: String, override val message: String) : Exception(message)

    // ─── Plumbing ────────────────────────────────────────────────

    private fun reply(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: ChannelError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (t: Throwable) {
                main.post { result.error("INTERNAL", t.message ?: t.toString(), null) }
            }
        }
    }

    private fun svc(): AgentAccessibilityService =
        AgentAccessibilityService.instance
            ?: throw ChannelError("SERVICE_NOT_RUNNING", "Accessibility service is not running")

    private fun listener(): AgentNotificationListenerService {
        if (!AgentNotificationListenerService.isAccessGranted(appContext)) {
            throw ChannelError("NO_NOTIFICATION_ACCESS", "Notification access is not granted")
        }
        return AgentNotificationListenerService.instance
            ?: throw ChannelError(
                "NO_NOTIFICATION_ACCESS",
                "Notification listener is granted but not bound yet"
            )
    }

    private fun intArg(call: MethodCall, key: String): Int? =
        (call.argument<Any>(key) as? Number)?.toInt()

    private fun longArg(call: MethodCall, key: String): Long? =
        (call.argument<Any>(key) as? Number)?.toLong()

    private fun dblArg(call: MethodCall, key: String): Double? =
        (call.argument<Any>(key) as? Number)?.toDouble()

    /** Fingerprint taken after the UI has had a moment to settle. */
    private fun fpAfterAction(s: AgentAccessibilityService): String {
        try {
            Thread.sleep(SETTLE_MS)
        } catch (_: InterruptedException) {
        }
        return s.fingerprintOnly()
    }

    private fun okFp(s: AgentAccessibilityService, ok: Boolean): Map<String, Any?> =
        mapOf("ok" to ok, "screen_fp" to fpAfterAction(s))

    // ─── Node resolution ─────────────────────────────────────────

    /**
     * The correctness anchor. A node id only resolves against the dump that produced it; a node
     * that no longer refreshes is STALE, not "close enough".
     */
    private fun resolveEntry(
        s: AgentAccessibilityService,
        id: String
    ): AgentAccessibilityService.NodeEntry {
        val entry = s.cachedNode(id)
            ?: throw ChannelError(
                "STALE_NODE",
                "node_id '$id' is not in the current screen cache — re-dump with screenState"
            )
        val node = entry.node
            ?: throw ChannelError("STALE_NODE", "node_id '$id' has no live handle")
        val alive = try {
            node.refresh()
        } catch (_: Throwable) {
            false
        }
        if (!alive) {
            throw ChannelError(
                "STALE_NODE",
                "node_id '$id' no longer exists on screen — re-dump with screenState"
            )
        }
        return entry
    }

    private class Target(
        val x: Int,
        val y: Int,
        val entry: AgentAccessibilityService.NodeEntry?,
        val node: AccessibilityNodeInfo?
    )

    /** Precedence is fixed: node_id, then text, then raw coordinates. */
    private fun resolveTarget(s: AgentAccessibilityService, call: MethodCall): Target {
        call.argument<String>("node_id")?.let { id ->
            val entry = resolveEntry(s, id)
            val live = Rect()
            entry.node?.getBoundsInScreen(live)
            val rect = if (live.isEmpty) entry.bounds else live
            return Target(rect.centerX(), rect.centerY(), entry, entry.node)
        }
        call.argument<String>("text")?.let { text ->
            // Deliberately does NOT rebuild the node cache: the caller's ids stay bound to the
            // dump they explicitly asked for.
            val node = s.findNodeByText(text)
                ?: throw ChannelError("NOT_FOUND", "no visible node matching text '$text'")
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (rect.isEmpty) throw ChannelError("NOT_FOUND", "matched node has empty bounds")
            return Target(rect.centerX(), rect.centerY(), null, node)
        }
        val x = intArg(call, "x")
        val y = intArg(call, "y")
        if (x != null && y != null) return Target(x, y, null, null)
        throw ChannelError("BAD_ARGS", "needs one of node_id, text, or x+y")
    }

    private fun entryMap(e: AgentAccessibilityService.NodeEntry): Map<String, Any?> = mapOf(
        "id" to e.id,
        "class" to e.className,
        "text" to e.text,
        "desc" to e.desc,
        "bounds" to boundsString(e.bounds),
        "clickable" to e.clickable,
        "focused" to e.focused
    )

    // ─── Dispatch ────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            // ── Perception ──────────────────────────────────────
            "status" -> reply(result) {
                val s = AgentAccessibilityService.instance
                mapOf(
                    "accessibility_running" to (s != null),
                    "foreground_app" to s?.getCurrentPackage(),
                    "battery" to batteryLevel(),
                    "screen_on" to screenOn(),
                    "android_sdk" to Build.VERSION.SDK_INT,
                    "notification_access" to
                        AgentNotificationListenerService.isAccessGranted(appContext)
                )
            }

            "screenState" -> reply(result) {
                val s = svc()
                val d = s.dump(
                    interactiveOnly = call.argument<Boolean>("interactive_only") ?: false,
                    maxNodes = intArg(call, "max_nodes") ?: 0
                )
                mapOf(
                    "tsv" to d.tsv,
                    "screen_fp" to d.fingerprint,
                    "node_count" to d.entries.size,
                    "foreground_app" to d.packageName
                )
            }

            "find" -> reply(result) {
                val s = svc()
                val d = s.dump(interactiveOnly = false, maxNodes = 0)
                val exact = call.argument<Boolean>("exact") ?: false
                val text = call.argument<String>("text")
                val viewId = call.argument<String>("id")
                val cls = call.argument<String>("class")?.substringAfterLast('.')

                val matches = d.entries.filter { e ->
                    (text == null || matchStr(e.text, text, exact) || matchStr(e.desc, text, exact)) &&
                        (viewId == null || matchStr(e.viewId, viewId, exact)) &&
                        (cls == null || matchStr(e.className, cls, exact))
                }.map { entryMap(it) }
                mapOf("matches" to matches)
            }

            "nodeDetails" -> reply(result) {
                val s = svc()
                val id = call.argument<String>("node_id")
                    ?: throw ChannelError("BAD_ARGS", "node_id is required")
                val e = resolveEntry(s, id)
                val n = e.node!!
                val rect = Rect()
                n.getBoundsInScreen(rect)
                mapOf(
                    "id" to e.id,
                    "class" to (n.className?.toString() ?: e.className).substringAfterLast('.'),
                    "text" to (n.text?.toString() ?: ""),
                    "desc" to (n.contentDescription?.toString() ?: ""),
                    "view_id" to (n.viewIdResourceName ?: ""),
                    "bounds" to boundsString(if (rect.isEmpty) e.bounds else rect),
                    "clickable" to n.isClickable,
                    "editable" to n.isEditable,
                    "scrollable" to n.isScrollable,
                    "checkable" to n.isCheckable,
                    "checked" to n.isChecked,
                    "focused" to n.isFocused,
                    "enabled" to n.isEnabled,
                    "password" to n.isPassword,
                    "depth" to e.depth,
                    "child_count" to n.childCount
                )
            }

            "screenshot" -> reply(result) {
                val s = svc()
                requireApi30("screenshot")
                val scale = (dblArg(call, "scale") ?: 0.5).coerceIn(0.05, 1.0)
                val bmp = s.screenshotBitmapBlocking()
                    ?: throw ChannelError("SCREENSHOT_FAILED", "takeScreenshot callback failed")
                pngBytes(bmp, scale)
            }

            "pixel" -> reply(result) {
                val s = svc()
                requireApi30("pixel")
                val x = intArg(call, "x") ?: throw ChannelError("BAD_ARGS", "x is required")
                val y = intArg(call, "y") ?: throw ChannelError("BAD_ARGS", "y is required")
                val bmp = s.screenshotBitmapBlocking()
                    ?: throw ChannelError("SCREENSHOT_FAILED", "takeScreenshot callback failed")
                val px = bmp.getPixel(
                    x.coerceIn(0, bmp.width - 1),
                    y.coerceIn(0, bmp.height - 1)
                )
                bmp.recycle()
                mapOf("argb" to px, "hex" to String.format("#%08X", px))
            }

            // ── Touch ───────────────────────────────────────────
            "tap" -> reply(result) {
                val s = svc()
                val t = resolveTarget(s, call)
                val ok = when {
                    t.entry != null -> s.tapNode(t.entry)
                    else -> s.tapAt(t.x, t.y) || s.clickAncestor(t.node)
                }
                recycle(t)
                okFp(s, ok)
            }

            "doubleTap" -> reply(result) {
                val s = svc()
                val t = resolveTarget(s, call)
                val first = s.tapAt(t.x, t.y)
                try {
                    Thread.sleep(120)
                } catch (_: InterruptedException) {
                }
                val second = s.tapAt(t.x, t.y)
                recycle(t)
                okFp(s, first && second)
            }

            "longPress" -> reply(result) {
                val s = svc()
                val t = resolveTarget(s, call)
                val ms = longArg(call, "duration_ms") ?: 1000L
                val ok = s.longPressAtMs(t.x, t.y, ms)
                recycle(t)
                okFp(s, ok)
            }

            "swipe" -> reply(result) {
                val s = svc()
                val duration = longArg(call, "duration_ms") ?: 300L
                val from = call.argument<Map<String, Any?>>("from")
                val to = call.argument<Map<String, Any?>>("to")
                val ok = if (from != null && to != null) {
                    s.swipeBetween(
                        num(from["x"]), num(from["y"]), num(to["x"]), num(to["y"]), duration
                    )
                } else {
                    val (w, h) = s.screenSize()
                    val dir = (call.argument<String>("direction") ?: "up").lowercase()
                    val vertical = dir == "up" || dir == "down"
                    val defaultDistance = ((if (vertical) h else w) * 0.6).toInt()
                    val d = intArg(call, "distance") ?: defaultDistance
                    val cx = w / 2
                    val cy = h / 2
                    when (dir) {
                        // "up" means the finger travels upward (content scrolls forward).
                        "up" -> s.swipeBetween(cx, cy + d / 2, cx, cy - d / 2, duration)
                        "down" -> s.swipeBetween(cx, cy - d / 2, cx, cy + d / 2, duration)
                        "left" -> s.swipeBetween(cx + d / 2, cy, cx - d / 2, cy, duration)
                        "right" -> s.swipeBetween(cx - d / 2, cy, cx + d / 2, cy, duration)
                        else -> throw ChannelError(
                            "BAD_ARGS", "direction must be up|down|left|right"
                        )
                    }
                }
                okFp(s, ok)
            }

            "pinch" -> reply(result) {
                val s = svc()
                val dir = call.argument<String>("direction")?.lowercase()
                    ?: throw ChannelError("BAD_ARGS", "direction is required (in|out)")
                if (dir != "in" && dir != "out") {
                    throw ChannelError("BAD_ARGS", "direction must be in|out")
                }
                val (w, h) = s.screenSize()
                val ok = s.pinch(
                    dir,
                    dblArg(call, "scale") ?: 2.0,
                    intArg(call, "x") ?: (w / 2),
                    intArg(call, "y") ?: (h / 2)
                )
                okFp(s, ok)
            }

            "gesture" -> reply(result) {
                val s = svc()
                val raw = call.argument<List<Map<String, Any?>>>("path")
                if (raw.isNullOrEmpty()) throw ChannelError("BAD_ARGS", "path must be non-empty")
                val points = raw.map { Pair(num(it["x"]), num(it["y"])) }
                okFp(s, s.pathGesture(points, longArg(call, "duration_ms") ?: 300L))
            }

            // ── Input ───────────────────────────────────────────
            "typeText" -> reply(result) {
                val s = svc()
                val text = call.argument<String>("text") ?: ""
                val mode = (call.argument<String>("mode") ?: "replace").lowercase()
                val submit = call.argument<Boolean>("submit") ?: false

                var owned: AccessibilityNodeInfo? = null
                val node: AccessibilityNodeInfo = call.argument<String>("node_id")?.let { id ->
                    resolveEntry(s, id).node!!
                } ?: run {
                    owned = s.focusedEditable()
                    owned ?: throw ChannelError("NOT_FOUND", "no editable field on screen")
                }

                val value = when (mode) {
                    "clear" -> ""
                    "append" -> (node.text?.toString() ?: "") + text
                    else -> text
                }
                var ok = s.setNodeText(node, value)
                if (ok && submit) ok = s.imeEnter(node)
                recycleNode(owned)
                okFp(s, ok)
            }

            "press" -> reply(result) {
                val s = svc()
                val key = call.argument<String>("key")?.lowercase()
                    ?: throw ChannelError("BAD_ARGS", "key is required")
                okFp(s, pressKey(s, key))
            }

            // ── Wait ────────────────────────────────────────────
            "waitFor" -> reply(result) { waitFor(call) }

            // ── Apps ────────────────────────────────────────────
            "closeApp" -> reply(result) { mapOf("ok" to closeApp(call)) }

            "sendIntent" -> reply(result) { mapOf("ok" to sendIntent(call)) }

            "shareFile" -> reply(result) { mapOf("ok" to shareFile(call)) }

            // ── Notifications ───────────────────────────────────
            "notifications" -> reply(result) { notifications(call) }

            "notificationReply" -> reply(result) {
                val l = listener()
                val id = call.argument<String>("id")
                    ?: throw ChannelError("BAD_ARGS", "id is required")
                val text = call.argument<String>("text")
                    ?: throw ChannelError("BAD_ARGS", "text is required")
                mapOf("ok" to l.reply(id, text))
            }

            "notificationAction" -> reply(result) {
                val l = listener()
                val id = call.argument<String>("id")
                    ?: throw ChannelError("BAD_ARGS", "id is required")
                val name = call.argument<String>("action")
                    ?: throw ChannelError("BAD_ARGS", "action is required")
                mapOf("ok" to l.fireAction(id, name))
            }

            "notificationAccessGranted" ->
                result.success(AgentNotificationListenerService.isAccessGranted(appContext))

            "openNotificationAccessSettings" ->
                result.success(launchSettings(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS, null))

            // ── Data ────────────────────────────────────────────
            // Clipboard must be touched from a Looper thread, and onMethodCall already runs on
            // the platform (main) thread — so this one stays synchronous on purpose.
            "clipboard" -> clipboard(call, result)

            "logs" -> reply(result) { mapOf("lines" to ownLogcat(intArg(call, "lines") ?: 200)) }

            // ── Lifecycle ───────────────────────────────────────
            "startForegroundService" -> reply(result) {
                AgentForegroundService.start(appContext, "Connected to bridge")
                mapOf("ok" to true)
            }

            "stopForegroundService" -> reply(result) {
                AgentForegroundService.stop(appContext)
                mapOf("ok" to true)
            }

            "updateForegroundStatus" -> reply(result) {
                val text = call.argument<String>("text")
                    ?: throw ChannelError("BAD_ARGS", "text is required")
                if (!AgentForegroundService.isRunning) {
                    mapOf("ok" to false)
                } else {
                    AgentForegroundService.update(appContext, text)
                    mapOf("ok" to true)
                }
            }

            "isForegroundServiceRunning" -> result.success(AgentForegroundService.isRunning)

            "batteryUnrestricted" -> result.success(isBatteryUnrestricted())

            "requestBatteryUnrestricted" -> result.success(
                launchSettings(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${appContext.packageName}")
                )
            )

            // ── Recording (P6) ──────────────────────────────────
            //
            // Recording is the ONE primitive that is not fully remote: MediaProjection needs a
            // human to tap a system dialog, and that dialog can only be raised from a foreground
            // Activity. So `screenRecordStart` refuses with a specific code when no consent has
            // been captured this process, rather than hanging or returning an empty file.
            "screenRecordStart" -> reply(result) {
                val maxS = (intArg(call, "max_s") ?: 60).coerceIn(1, 600)
                val scale = (dblArg(call, "scale") ?: 0.5).coerceIn(0.1, 1.0)
                if (!ScreenRecorder.hasConsent()) {
                    // Best effort: bring the consent dialog up so the next attempt can succeed.
                    // It only appears if a human is looking at the phone, which is the point.
                    requestRecordingConsent()
                    throw ChannelError(
                        ScreenRecorder.ERR_NO_CONSENT,
                        "Screen recording needs a one-time consent tap on the handset. The " +
                            "system dialog has been raised; approve it and call again. Consent " +
                            "lasts until the app process restarts.",
                    )
                }
                val path = try {
                    ScreenRecorder.start(appContext, maxS, scale, System.currentTimeMillis())
                } catch (e: IllegalStateException) {
                    throw ChannelError(codeOf(e), e.message ?: "recording failed to start")
                }
                mapOf("recording" to true, "max_s" to maxS, "scale" to scale, "path" to path)
            }

            "screenRecordStop" -> reply(result) {
                val file = try {
                    ScreenRecorder.stop()
                } catch (e: IllegalStateException) {
                    throw ChannelError(codeOf(e), e.message ?: "recording failed to stop")
                }
                val bytes = file.readBytes()
                // The file stays on disk as well: the bridge writes its own copy under the run's
                // evidence directory, and having both means a failed transfer is recoverable.
                bytes
            }

            "screenRecordStatus" -> reply(result) {
                ScreenRecorder.status(System.currentTimeMillis())
            }

            "requestRecordingConsent" -> reply(result) {
                requestRecordingConsent()
                mapOf("raised" to true, "has_consent" to ScreenRecorder.hasConsent())
            }

            else -> result.notImplemented()
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────

    private fun matchStr(haystack: String, needle: String, exact: Boolean): Boolean =
        if (exact) haystack.equals(needle, true) else haystack.contains(needle, true)

    private fun num(v: Any?): Int = (v as? Number)?.toInt() ?: 0

    private fun recycle(t: Target) {
        // Only the text-resolved node is ours to release; cached entries stay in the cache.
        if (t.entry == null) recycleNode(t.node)
    }

    @Suppress("DEPRECATION")
    private fun recycleNode(n: AccessibilityNodeInfo?) {
        try {
            n?.recycle()
        } catch (_: Throwable) {
        }
    }

    /**
     * Raise the MediaProjection consent dialog. Uses NEW_TASK so it works even when the app is
     * not the foreground activity — on a handset nobody is holding, it simply queues behind the
     * lock screen until someone looks, which is honest: consent that could be granted without a
     * person present would not be consent.
     */
    private fun requestRecordingConsent() {
        try {
            val intent = ScreenRecorder.consentIntent(activity)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivityForResult(intent, RECORD_CONSENT_REQUEST)
        } catch (_: Throwable) {
            // Nothing to salvage: the caller already gets RECORD_CONSENT_REQUIRED.
        }
    }

    /** ScreenRecorder throws IllegalStateException whose message STARTS with a stable code. */
    private fun codeOf(e: IllegalStateException): String {
        val m = e.message ?: return ScreenRecorder.ERR_FAILED
        return m.substringBefore(":").trim().ifEmpty { ScreenRecorder.ERR_FAILED }
    }

    private fun requireApi30(what: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw ChannelError(
                "UNSUPPORTED_VERSION", "$what requires Android 11 (API 30) or higher"
            )
        }
    }

    private fun pngBytes(bmp: Bitmap, scale: Double): ByteArray {
        val scaled = if (scale >= 0.999) {
            bmp
        } else {
            Bitmap.createScaledBitmap(
                bmp,
                (bmp.width * scale).toInt().coerceAtLeast(1),
                (bmp.height * scale).toInt().coerceAtLeast(1),
                true
            )
        }
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
        if (scaled !== bmp) scaled.recycle()
        bmp.recycle()
        return out.toByteArray()
    }

    private fun batteryLevel(): Int = try {
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
    } catch (_: Throwable) {
        -1
    }

    private fun screenOn(): Boolean = try {
        (appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive ?: false
    } catch (_: Throwable) {
        false
    }

    private fun isBatteryUnrestricted(): Boolean = try {
        (appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.isIgnoringBatteryOptimizations(appContext.packageName) ?: false
    } catch (_: Throwable) {
        false
    }

    private fun launchSettings(action: String, data: Uri?): Boolean = try {
        val i = Intent(action)
        if (data != null) i.data = data
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(i)
        true
    } catch (_: Throwable) {
        false
    }

    /**
     * An accessibility service cannot inject raw key events (that needs INJECT_EVENTS, a
     * signature permission), so everything routes through global actions or ACTION_IME_ENTER.
     */
    private fun pressKey(s: AgentAccessibilityService, key: String): Boolean = when {
        key == "back" -> s.globalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        key == "home" -> s.globalAction(AccessibilityService.GLOBAL_ACTION_HOME)
        key == "recents" -> s.globalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
        key == "notifications" ->
            s.globalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)
        key == "quick_settings" ->
            s.globalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS)
        key == "enter" -> s.imeEnter(null)
        // Pressing BACK with no IME up would navigate away instead of closing a keyboard.
        key == "keyboard_dismiss" ->
            if (s.isKeyboardShowing()) {
                s.globalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            } else {
                true
            }
        key.startsWith("key:") -> when (key.removePrefix("key:").trim().toIntOrNull()) {
            3 -> s.globalAction(AccessibilityService.GLOBAL_ACTION_HOME)
            4 -> s.globalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            66, 160 -> s.imeEnter(null)
            187 -> s.globalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
            else -> false
        }
        else -> throw ChannelError("BAD_ARGS", "unknown key '$key'")
    }

    private fun waitFor(call: MethodCall): Map<String, Any?> {
        val s = svc()
        val timeout = longArg(call, "timeout_ms") ?: 10000L
        val text = call.argument<String>("text")
        val nodeQuery = call.argument<String>("node")
        // With no positive condition to look for, "settled" is the only sensible meaning.
        val idle = call.argument<Boolean>("idle") ?: (text == null && nodeQuery == null)

        val start = System.currentTimeMillis()
        var previousFp: String? = null

        while (true) {
            val elapsed = System.currentTimeMillis() - start
            val fp = s.fingerprintOnly()

            if (text != null) {
                val hit = s.findNodeByText(text)
                if (hit != null) {
                    recycleNode(hit)
                    return mapOf(
                        "ok" to true, "waited_ms" to elapsed.toInt(),
                        "screen_fp" to fp, "reason" to "found"
                    )
                }
            }
            if (nodeQuery != null) {
                // snapshot(), not dump(): polling must not invalidate the caller's node ids.
                val d = s.snapshot()
                val hit = d.entries.any { it.viewId.contains(nodeQuery, true) }
                if (hit) {
                    return mapOf(
                        "ok" to true, "waited_ms" to elapsed.toInt(),
                        "screen_fp" to d.fingerprint, "reason" to "found"
                    )
                }
            }
            if (idle && text == null && nodeQuery == null &&
                previousFp != null && previousFp == fp
            ) {
                return mapOf(
                    "ok" to true, "waited_ms" to elapsed.toInt(),
                    "screen_fp" to fp, "reason" to "idle"
                )
            }
            previousFp = fp

            if (elapsed >= timeout) {
                return mapOf(
                    "ok" to false, "waited_ms" to elapsed.toInt(),
                    "screen_fp" to fp, "reason" to "timeout"
                )
            }
            try {
                Thread.sleep(200)
            } catch (_: InterruptedException) {
                return mapOf(
                    "ok" to false, "waited_ms" to elapsed.toInt(),
                    "screen_fp" to fp, "reason" to "interrupted"
                )
            }
        }
    }

    /**
     * There is no supported way to force-stop another app. killBackgroundProcesses only reaps
     * background processes, so we send the app to the background first when it is in front.
     */
    private fun closeApp(call: MethodCall): Boolean {
        val pkg = call.argument<String>("package")
            ?: throw ChannelError("BAD_ARGS", "package is required")
        if (pkg == appContext.packageName) {
            throw ChannelError("BAD_ARGS", "refusing to close PrivateAgent itself")
        }
        val s = AgentAccessibilityService.instance
        val wasForeground = s != null && s.getCurrentPackage() == pkg
        if (wasForeground) {
            s!!.globalAction(AccessibilityService.GLOBAL_ACTION_HOME)
            try {
                Thread.sleep(400)
            } catch (_: InterruptedException) {
            }
        }
        // ADR-21 D2: `ok` means the app WAS running and is now closed. The old version
        // returned `s == null || s.getCurrentPackage() != pkg`, which is true for an app
        // that was never installed — a cheerful success for a no-op.
        val installed = try {
            appContext.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (_: Throwable) {
            false
        }
        if (!installed) return false

        return try {
            (appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
                ?.killBackgroundProcesses(pkg)
            // Only claim it when we can SEE it: it was in the foreground and no longer is.
            // A background app cannot be confirmed closed from here, and D2 says an
            // unconfirmable effect is `false`, not an optimistic true.
            wasForeground && s?.getCurrentPackage() != pkg
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Share a file properly (build-15).
     *
     * The old path sent ACTION_SEND with a raw filesystem path in `data`, which could
     * never work and never did: ACTION_SEND reads EXTRA_STREAM, not `data`; it resolves
     * on MIME type, and none was set; and a bare path is not a Uri any receiving app may
     * read — a file:// Uri throws FileUriExposedException on Android 7+. Every share
     * silently returned false, on every screen state, since it was written.
     */
    private fun shareFile(call: MethodCall): Boolean {
        val path = call.argument<String>("path")
            ?: throw ChannelError("BAD_ARGS", "path is required")
        val pkg = call.argument<String>("package")
        val file = java.io.File(path)
        if (!file.exists()) {
            throw ChannelError("NOT_FOUND", "no such file to share: $path")
        }

        val uri = try {
            androidx.core.content.FileProvider.getUriForFile(
                appContext,
                "${appContext.packageName}.fileprovider",
                file,
            )
        } catch (e: Throwable) {
            // Almost always means the file sits outside every root in file_paths.xml.
            throw ChannelError("SHARE_FAILED", "cannot share this path: ${e.message}")
        }

        val mime = call.argument<String>("mime") ?: mimeOf(file.name)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (pkg != null) setPackage(pkg)
        }

        // A chooser, unless a specific app was named. Without one, a device with no
        // default handler shows nothing at all.
        val toStart = if (pkg != null) send else Intent.createChooser(send, "Share")
        toStart.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return startOrFalse(toStart)
    }

    /** Enough of a MIME guess to let a chooser resolve; the caller may override it. */
    private fun mimeOf(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "txt", "log", "md" -> "text/plain"
        "json" -> "application/json"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "mp4" -> "video/mp4"
        "pdf" -> "application/pdf"
        else -> "application/octet-stream"
    }

    private fun sendIntent(call: MethodCall): Boolean {
        val action = call.argument<String>("action") ?: ""
        val pkg = call.argument<String>("package")
        val component = call.argument<String>("component")
        val data = call.argument<String>("data")
        val extras = call.argument<Map<String, Any?>>("extras")

        // Convenience: no action + a package means "open this app".
        if (action.isBlank() && component == null && pkg != null) {
            val launch = appContext.packageManager.getLaunchIntentForPackage(pkg)
                ?: throw ChannelError("NOT_FOUND", "no launcher activity for $pkg")
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            applyExtras(launch, extras)
            return startOrFalse(launch)
        }

        val intent = Intent(action.ifBlank { Intent.ACTION_VIEW })
        if (pkg != null) intent.setPackage(pkg)
        if (component != null) {
            val cn = ComponentName.unflattenFromString(component)
                ?: throw ChannelError("BAD_ARGS", "component must be pkg/cls")
            intent.component = cn
        }
        if (data != null) intent.data = Uri.parse(data)
        applyExtras(intent, extras)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return startOrFalse(intent)
    }

    private fun startOrFalse(intent: Intent): Boolean = try {
        appContext.startActivity(intent)
        true
    } catch (_: Throwable) {
        false
    }

    private fun applyExtras(intent: Intent, extras: Map<String, Any?>?) {
        if (extras == null) return
        for ((k, v) in extras) {
            when (v) {
                null -> {}
                is String -> intent.putExtra(k, v)
                is Boolean -> intent.putExtra(k, v)
                is Int -> intent.putExtra(k, v)
                is Long -> intent.putExtra(k, v)
                is Double -> intent.putExtra(k, v)
                else -> intent.putExtra(k, v.toString())
            }
        }
    }

    private fun notifications(call: MethodCall): Map<String, Any?> {
        val l = listener()
        val action = (call.argument<String>("action") ?: "list").lowercase()
        if (action == "list") return mapOf("notifications" to l.listNotifications())

        val id = call.argument<String>("id")
            ?: throw ChannelError("BAD_ARGS", "id is required for action '$action'")
        return when (action) {
            "open" -> mapOf("ok" to l.open(id))
            "dismiss" -> mapOf("ok" to l.dismiss(id))
            "snooze" -> mapOf("ok" to l.snooze(id, longArg(call, "snooze_ms") ?: 600000L))
            else -> throw ChannelError("BAD_ARGS", "action must be list|open|dismiss|snooze")
        }
    }

    private fun clipboard(call: MethodCall, result: MethodChannel.Result) {
        try {
            val cm = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return result.error("INTERNAL", "no clipboard service", null)
            when ((call.argument<String>("action") ?: "get").lowercase()) {
                "set" -> {
                    val text = call.argument<String>("text") ?: ""
                    cm.setPrimaryClip(ClipData.newPlainText("PrivateAgent", text))
                    result.success(mapOf("ok" to true))
                }
                "get" -> {
                    // Android 10+ only lets the focused app read the clipboard; a null read is
                    // the restriction, not an error, so we say so instead of failing.
                    val clip = cm.primaryClip
                    val text = if (clip != null && clip.itemCount > 0) {
                        clip.getItemAt(0)?.coerceToText(appContext)?.toString()
                    } else {
                        null
                    }
                    if (text.isNullOrEmpty()) {
                        result.success(mapOf("text" to null, "restricted" to true))
                    } else {
                        result.success(mapOf("text" to text, "restricted" to false))
                    }
                }
                else -> result.error("BAD_ARGS", "action must be get|set", null)
            }
        } catch (t: Throwable) {
            result.error("INTERNAL", t.message ?: "clipboard failed", null)
        }
    }

    /** --pid keeps this to our own process; other apps' logs must never leave the device. */
    private fun ownLogcat(lines: Int): List<String> {
        val n = lines.coerceIn(1, 5000)
        return try {
            val proc = Runtime.getRuntime().exec(
                arrayOf("logcat", "-d", "-t", n.toString(), "--pid=${Process.myPid()}")
            )
            val out = mutableListOf<String>()
            BufferedReader(InputStreamReader(proc.inputStream)).use { r ->
                var line = r.readLine()
                while (line != null && out.size < n) {
                    out.add(line)
                    line = r.readLine()
                }
            }
            proc.destroy()
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }
}
