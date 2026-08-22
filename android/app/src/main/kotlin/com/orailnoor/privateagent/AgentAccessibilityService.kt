package com.orailnoor.privateagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * The phone's hands and eyes. P2 turns this device into a dumb executor: the bridge sends one
 * typed primitive, this service performs it and reports what it observed.
 *
 * The single most important property here is NODE IDENTITY. A dump hands the caller ids
 * "n0","n1",... and caches the matching node handles. A later tap on "n2" resolves against the
 * screen the caller actually saw — never against a screen that scrolled underneath it. A cache
 * miss (or a node that no longer refreshes) is a hard STALE_NODE error, because silently tapping
 * the neighbouring row is how an agent likes the wrong post.
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {
        var instance: AgentAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null

        /** Screenshots are rate limited by the framework to one per second (API 30). */
        private const val SCREENSHOT_MIN_INTERVAL_MS = 1100L
        private const val ERROR_SCREENSHOT_INTERVAL_TIME_SHORT = 3
    }

    // Screenshot callbacks are delivered on this executor so a blocking caller on a worker
    // thread never depends on the main looper being free.
    private val screenshotExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We don't react to events — every primitive is a pull, driven by the bridge.
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        clearNodeCache()
        instance = null
    }

    // ─── Node identity cache ─────────────────────────────────────

    /**
     * One row of a dump. [node] is a retained copy (the traversal recycles the originals), so
     * a later tap can still act on the exact view the caller saw.
     */
    class NodeEntry(
        val id: String,
        val node: AccessibilityNodeInfo?,
        val className: String,
        val text: String,
        val desc: String,
        val viewId: String,
        val bounds: Rect,
        val clickable: Boolean,
        val focused: Boolean,
        val editable: Boolean,
        val scrollable: Boolean,
        val checkable: Boolean,
        val checked: Boolean,
        val enabled: Boolean,
        val password: Boolean,
        val depth: Int,
        val childCount: Int
    )

    class DumpResult(
        val entries: List<NodeEntry>,
        val tsv: String,
        val fingerprint: String,
        val packageName: String?
    )

    private val cacheLock = Any()
    private val nodeCache = LinkedHashMap<String, NodeEntry>()

    // The post-action fingerprint must be comparable with the fingerprint the caller last saw,
    // so we replay the same filter/limit the last explicit dump used.
    @Volatile private var lastInteractiveOnly = false
    @Volatile private var lastMaxNodes = 0

    private fun clearNodeCache() {
        synchronized(cacheLock) {
            for (e in nodeCache.values) {
                try {
                    @Suppress("DEPRECATION")
                    e.node?.recycle()
                } catch (_: Throwable) {
                }
            }
            nodeCache.clear()
        }
    }

    fun cachedNode(id: String): NodeEntry? = synchronized(cacheLock) { nodeCache[id] }

    // ─── Dump / fingerprint ──────────────────────────────────────

    /**
     * Fresh dump that REPLACES the node cache. Any previously issued node id is invalid after
     * this call — that invalidation is the point.
     */
    fun dump(interactiveOnly: Boolean, maxNodes: Int): DumpResult {
        val result = collect(interactiveOnly, maxNodes, retain = true)
        synchronized(cacheLock) {
            clearNodeCache()
            for (e in result.entries) nodeCache[e.id] = e
            lastInteractiveOnly = interactiveOnly
            lastMaxNodes = maxNodes
        }
        return result
    }

    /**
     * Fingerprint the screen WITHOUT touching the node cache. Used for the after-action
     * fingerprint so that "did the screen change?" never silently re-points the caller's ids at
     * a different screen.
     */
    fun fingerprintOnly(): String =
        collect(lastInteractiveOnly, lastMaxNodes, retain = false).fingerprint

    /**
     * Read the screen without issuing or invalidating node ids. Used by polling loops, which
     * must never re-point the caller's ids at a screen it has not seen.
     */
    fun snapshot(): DumpResult = collect(interactiveOnly = false, maxNodes = 0, retain = false)

    private fun collect(interactiveOnly: Boolean, maxNodes: Int, retain: Boolean): DumpResult {
        val root = rootInActiveWindow
            ?: return DumpResult(emptyList(), TSV_HEADER, sha256Prefix(TSV_HEADER), null)
        val pkg = root.packageName?.toString()
        val out = mutableListOf<NodeEntry>()
        try {
            walk(root, 0, out, interactiveOnly, maxNodes, retain)
        } catch (_: Throwable) {
            // A window can vanish mid-traversal; return what we already have rather than throwing.
        } finally {
            try {
                @Suppress("DEPRECATION")
                root.recycle()
            } catch (_: Throwable) {
            }
        }
        val tsv = buildTsv(out)
        return DumpResult(out, tsv, sha256Prefix(tsv), pkg)
    }

    private fun walk(
        node: AccessibilityNodeInfo,
        depth: Int,
        out: MutableList<NodeEntry>,
        interactiveOnly: Boolean,
        maxNodes: Int,
        retain: Boolean
    ) {
        if (maxNodes > 0 && out.size >= maxNodes) return

        val rect = Rect()
        node.getBoundsInScreen(rect)

        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""
        val interactive = node.isClickable || node.isEditable || node.isScrollable ||
            node.isFocusable || node.isLongClickable || node.isCheckable

        // Off-screen and zero-size nodes are excluded: a node the user cannot see is a node we
        // must never hand back as a tap target.
        val visible = !rect.isEmpty && node.isVisibleToUser

        val include = visible && if (interactiveOnly) {
            interactive
        } else {
            interactive || text.isNotEmpty() || desc.isNotEmpty()
        }

        if (include) {
            out.add(
                NodeEntry(
                    id = "n${out.size}",
                    node = if (retain) obtainCopy(node) else null,
                    className = (node.className?.toString() ?: "").substringAfterLast('.'),
                    text = text,
                    desc = desc,
                    viewId = node.viewIdResourceName ?: "",
                    bounds = Rect(rect),
                    clickable = node.isClickable,
                    focused = node.isFocused,
                    editable = node.isEditable,
                    scrollable = node.isScrollable,
                    checkable = node.isCheckable,
                    checked = node.isChecked,
                    enabled = node.isEnabled,
                    password = node.isPassword,
                    depth = depth,
                    childCount = node.childCount
                )
            )
        }

        for (i in 0 until node.childCount) {
            if (maxNodes > 0 && out.size >= maxNodes) return
            val child = node.getChild(i) ?: continue
            walk(child, depth + 1, out, interactiveOnly, maxNodes, retain)
            try {
                @Suppress("DEPRECATION")
                child.recycle()
            } catch (_: Throwable) {
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun obtainCopy(node: AccessibilityNodeInfo): AccessibilityNodeInfo? = try {
        AccessibilityNodeInfo.obtain(node)
    } catch (_: Throwable) {
        null
    }

    private fun buildTsv(entries: List<NodeEntry>): String {
        val sb = StringBuilder(TSV_HEADER)
        for (e in entries) {
            sb.append('\n')
            sb.append(e.id).append('\t')
                .append(sanitize(e.className)).append('\t')
                .append(sanitize(e.text)).append('\t')
                .append(sanitize(e.desc)).append('\t')
                .append(boundsString(e.bounds)).append('\t')
                .append(e.clickable).append('\t')
                .append(e.focused)
        }
        return sb.toString()
    }

    // ─── Screen geometry ─────────────────────────────────────────

    fun screenSize(): Pair<Int, Int> {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val wm = getSystemService(WindowManager::class.java)
                val b = wm?.currentWindowMetrics?.bounds
                if (b != null && b.width() > 0) return Pair(b.width(), b.height())
            }
        } catch (_: Throwable) {
        }
        val dm = resources.displayMetrics
        return Pair(dm.widthPixels, dm.heightPixels)
    }

    private fun clampX(x: Float): Float {
        val (w, _) = screenSize()
        return x.coerceIn(0f, (w - 1).toFloat())
    }

    private fun clampY(y: Float): Float {
        val (_, h) = screenSize()
        return y.coerceIn(0f, (h - 1).toFloat())
    }

    // ─── Gestures ────────────────────────────────────────────────

    /**
     * Dispatch and block until the framework reports completion. Callers must be off the main
     * thread; from the main thread we fire-and-forget instead of deadlocking on our own looper.
     */
    fun dispatchAndWait(gesture: GestureDescription, timeoutMs: Long = 8000): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return try {
                dispatchGesture(gesture, null, null)
            } catch (_: Throwable) {
                false
            }
        }
        val latch = CountDownLatch(1)
        val ok = AtomicBoolean(false)
        mainHandler.post {
            val accepted = try {
                dispatchGesture(
                    gesture,
                    object : GestureResultCallback() {
                        override fun onCompleted(g: GestureDescription?) {
                            ok.set(true); latch.countDown()
                        }

                        override fun onCancelled(g: GestureDescription?) {
                            ok.set(false); latch.countDown()
                        }
                    },
                    mainHandler
                )
            } catch (_: Throwable) {
                false
            }
            if (!accepted) latch.countDown()
        }
        return try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS) && ok.get()
        } catch (_: InterruptedException) {
            false
        }
    }

    fun tapAt(x: Int, y: Int): Boolean {
        val p = Path()
        p.moveTo(clampX(x.toFloat()), clampY(y.toFloat()))
        return dispatchAndWait(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(p, 0, 60))
                .build()
        )
    }

    fun longPressAtMs(x: Int, y: Int, durationMs: Long): Boolean {
        val p = Path()
        p.moveTo(clampX(x.toFloat()), clampY(y.toFloat()))
        return dispatchAndWait(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(p, 0, durationMs.coerceIn(50, 30000)))
                .build(),
            durationMs + 5000
        )
    }

    fun swipeBetween(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long): Boolean {
        val p = Path()
        p.moveTo(clampX(x1.toFloat()), clampY(y1.toFloat()))
        p.lineTo(clampX(x2.toFloat()), clampY(y2.toFloat()))
        return dispatchAndWait(
            GestureDescription.Builder()
                .addStroke(
                    GestureDescription.StrokeDescription(p, 0, durationMs.coerceIn(10, 60000))
                )
                .build(),
            durationMs + 5000
        )
    }

    fun pathGesture(points: List<Pair<Int, Int>>, durationMs: Long): Boolean {
        if (points.isEmpty()) return false
        val p = Path()
        p.moveTo(clampX(points[0].first.toFloat()), clampY(points[0].second.toFloat()))
        for (i in 1 until points.size) {
            p.lineTo(clampX(points[i].first.toFloat()), clampY(points[i].second.toFloat()))
        }
        return dispatchAndWait(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(p, 0, durationMs.coerceIn(10, 60000)))
                .build(),
            durationMs + 5000
        )
    }

    /** Two-finger pinch. Both strokes start at 0 so they are genuinely simultaneous. */
    fun pinch(direction: String, scale: Double, cx: Int, cy: Int): Boolean {
        val (w, h) = screenSize()
        val span = (minOf(w, h) * 0.30).toFloat()
        val s = scale.coerceIn(1.05, 4.0).toFloat()
        val near = span / 4f
        val far = (span / 4f) * s

        val out = direction.lowercase() != "in"
        val startOffset = if (out) near else far
        val endOffset = if (out) far else near

        val a = Path()
        a.moveTo(clampX(cx - startOffset), clampY(cy.toFloat()))
        a.lineTo(clampX(cx - endOffset), clampY(cy.toFloat()))
        val b = Path()
        b.moveTo(clampX(cx + startOffset), clampY(cy.toFloat()))
        b.lineTo(clampX(cx + endOffset), clampY(cy.toFloat()))

        return dispatchAndWait(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(a, 0, 400))
                .addStroke(GestureDescription.StrokeDescription(b, 0, 400))
                .build()
        )
    }

    /**
     * Tap a cached node. One UI wraps a lot of tappable rows in non-clickable containers whose
     * ACTION_CLICK is a no-op, so we prefer a real gesture at the bounds centre and only fall
     * back to ACTION_CLICK on the nearest clickable ancestor.
     */
    fun tapNode(entry: NodeEntry): Boolean {
        val node = entry.node
        val rect = Rect(entry.bounds)
        if (node != null) {
            val live = Rect()
            node.getBoundsInScreen(live)
            if (!live.isEmpty) rect.set(live)
        }
        if (!rect.isEmpty && tapAt(rect.centerX(), rect.centerY())) return true
        return clickAncestor(node)
    }

    fun clickAncestor(node: AccessibilityNodeInfo?): Boolean {
        var t: AccessibilityNodeInfo? = node ?: return false
        var hops = 0
        while (t != null && hops < 12) {
            if (t.isClickable && t.isEnabled) {
                return try {
                    t.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                } catch (_: Throwable) {
                    false
                }
            }
            t = t.parent
            hops++
        }
        return false
    }

    // ─── Text targeting (does NOT rebuild the node cache) ────────

    /**
     * Locate a node by text/description for tap-by-text. Deliberately does not rebuild the node
     * cache: the caller's ids must stay bound to the dump they explicitly asked for.
     */
    fun findNodeByText(target: String): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val found = searchByText(root, target)
        if (found !== root) {
            try {
                @Suppress("DEPRECATION")
                root.recycle()
            } catch (_: Throwable) {
            }
        }
        return found
    }

    private fun searchByText(node: AccessibilityNodeInfo, target: String): AccessibilityNodeInfo? {
        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""
        val rect = Rect()
        node.getBoundsInScreen(rect)
        if (!rect.isEmpty && node.isVisibleToUser &&
            (text.equals(target, true) || desc.equals(target, true) ||
                text.contains(target, true) || desc.contains(target, true))
        ) {
            return obtainCopy(node)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = searchByText(child, target)
            try {
                @Suppress("DEPRECATION")
                child.recycle()
            } catch (_: Throwable) {
            }
            if (found != null) return found
        }
        return null
    }

    fun focusedEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        try {
            val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (focus != null && focus.isEditable) return focus
            return findFirstEditable(root)
        } finally {
            try {
                @Suppress("DEPRECATION")
                root.recycle()
            } catch (_: Throwable) {
            }
        }
    }

    private fun findFirstEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable && node.isVisibleToUser) return obtainCopy(node)
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findFirstEditable(child)
            try {
                @Suppress("DEPRECATION")
                child.recycle()
            } catch (_: Throwable) {
            }
            if (found != null) return found
        }
        return null
    }

    // ─── Text input ──────────────────────────────────────────────

    fun setNodeText(node: AccessibilityNodeInfo, value: String): Boolean {
        return try {
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            val args = Bundle()
            args.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value
            )
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * There is no way for an accessibility service to inject a raw ENTER key (that needs
     * INJECT_EVENTS, a signature permission). ACTION_IME_ENTER is the sanctioned equivalent and
     * only exists from API 30.
     */
    fun imeEnter(node: AccessibilityNodeInfo?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val target = node ?: focusedEditable() ?: return false
        return try {
            target.performAction(
                AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
            )
        } catch (_: Throwable) {
            false
        }
    }

    /** True when an IME window is on screen; guards keyboard_dismiss from navigating instead. */
    fun isKeyboardShowing(): Boolean {
        return try {
            windows?.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } ?: false
        } catch (_: Throwable) {
            false
        }
    }

    fun globalAction(action: Int): Boolean = try {
        performGlobalAction(action)
    } catch (_: Throwable) {
        false
    }

    // ─── Screenshot ──────────────────────────────────────────────

    /**
     * Blocking screenshot. API 30 only, and the framework rate-limits it to one per second —
     * we retry once after the interval rather than surfacing a spurious failure.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    fun screenshotBitmapBlocking(timeoutMs: Long = 8000): Bitmap? {
        val first = captureOnce(timeoutMs)
        if (first.first != null) return first.first
        if (first.second == ERROR_SCREENSHOT_INTERVAL_TIME_SHORT) {
            try {
                Thread.sleep(SCREENSHOT_MIN_INTERVAL_MS)
            } catch (_: InterruptedException) {
                return null
            }
            return captureOnce(timeoutMs).first
        }
        return null
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun captureOnce(timeoutMs: Long): Pair<Bitmap?, Int> {
        val latch = CountDownLatch(1)
        val bmpRef = AtomicReference<Bitmap?>(null)
        val errRef = AtomicReference(0)
        try {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                screenshotExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(screenshotResult: ScreenshotResult) {
                        val hb = screenshotResult.hardwareBuffer
                        try {
                            bmpRef.set(
                                Bitmap.wrapHardwareBuffer(hb, screenshotResult.colorSpace)
                                    ?.copy(Bitmap.Config.ARGB_8888, false)
                            )
                        } catch (_: Throwable) {
                        } finally {
                            hb.close()
                            latch.countDown()
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        errRef.set(errorCode)
                        latch.countDown()
                    }
                }
            )
        } catch (_: Throwable) {
            return Pair(null, -1)
        }
        return try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            Pair(bmpRef.get(), errRef.get())
        } catch (_: InterruptedException) {
            Pair(null, -1)
        }
    }

    // ─── Legacy channel surface (com.privateagent/accessibility) ──
    // Kept until the Dart callers are deleted; do not build new features on these.

    fun dumpScreen(): List<Map<String, Any?>> {
        val res = collect(interactiveOnly = false, maxNodes = 0, retain = false)
        return res.entries.map {
            mapOf(
                "index" to it.id.removePrefix("n").toIntOrNull(),
                "text" to it.text,
                "contentDescription" to it.desc,
                "className" to it.className,
                "viewId" to it.viewId,
                "isClickable" to it.clickable,
                "isEditable" to it.editable,
                "isScrollable" to it.scrollable,
                "isCheckable" to it.checkable,
                "isChecked" to it.checked,
                "isFocused" to it.focused,
                "bounds" to mapOf(
                    "left" to it.bounds.left,
                    "top" to it.bounds.top,
                    "right" to it.bounds.right,
                    "bottom" to it.bounds.bottom
                ),
                "depth" to it.depth
            )
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    fun takeScreenshot(callback: (String?) -> Unit) {
        screenshotExecutor.execute {
            val bmp = screenshotBitmapBlocking()
            if (bmp == null) {
                mainHandler.post { callback(null) }
                return@execute
            }
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 60, out)
            val b64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            mainHandler.post { callback(b64) }
        }
    }

    fun clickByText(targetText: String): Boolean {
        val node = findNodeByText(targetText) ?: return false
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val ok = clickAncestor(node) || (!rect.isEmpty && tapAt(rect.centerX(), rect.centerY()))
        try {
            @Suppress("DEPRECATION")
            node.recycle()
        } catch (_: Throwable) {
        }
        return ok
    }

    fun clickAtCoordinates(x: Float, y: Float): Boolean = tapAt(x.toInt(), y.toInt())

    fun typeText(text: String, fieldHint: String? = null): Boolean {
        val node = (if (fieldHint.isNullOrEmpty()) null else findNodeByText(fieldHint)?.takeIf { it.isEditable })
            ?: focusedEditable() ?: return false
        val ok = setNodeText(node, text)
        try {
            @Suppress("DEPRECATION")
            node.recycle()
        } catch (_: Throwable) {
        }
        return ok
    }

    fun scroll(direction: String, targetText: String? = null): Boolean {
        val root = rootInActiveWindow ?: return false
        val scrollNode = findScrollableNode(root, targetText)
        val action = when (direction.lowercase()) {
            "up", "backward" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            else -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        }
        val ok = scrollNode?.performAction(action) ?: false
        try {
            @Suppress("DEPRECATION")
            root.recycle()
        } catch (_: Throwable) {
        }
        return ok
    }

    private fun findScrollableNode(
        node: AccessibilityNodeInfo,
        targetText: String?
    ): AccessibilityNodeInfo? {
        if (node.isScrollable) {
            if (targetText == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            if (text.contains(targetText, true) || desc.contains(targetText, true)) return node
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findScrollableNode(child, targetText)
            if (found != null) return found
            try {
                @Suppress("DEPRECATION")
                child.recycle()
            } catch (_: Throwable) {
            }
        }
        return null
    }

    fun pressBack(): Boolean = globalAction(GLOBAL_ACTION_BACK)
    fun pressHome(): Boolean = globalAction(GLOBAL_ACTION_HOME)
    fun openRecents(): Boolean = globalAction(GLOBAL_ACTION_RECENTS)
    fun openNotifications(): Boolean = globalAction(GLOBAL_ACTION_NOTIFICATIONS)

    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long = 300): Boolean =
        swipeBetween(startX.toInt(), startY.toInt(), endX.toInt(), endY.toInt(), durationMs)

    fun longPressAt(x: Float, y: Float): Boolean = longPressAtMs(x.toInt(), y.toInt(), 1000)

    fun getCurrentPackage(): String? {
        val root = rootInActiveWindow ?: return null
        val pkg = root.packageName?.toString()
        try {
            @Suppress("DEPRECATION")
            root.recycle()
        } catch (_: Throwable) {
        }
        return pkg
    }
}

const val TSV_HEADER = "id\tclass\ttext\tdesc\tbounds\tclickable\tfocused"

/** Tabs and newlines would break the TSV table, so they collapse to a single space. */
fun sanitize(s: String): String =
    s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')

fun boundsString(r: Rect): String = "${r.left},${r.top},${r.right},${r.bottom}"

fun sha256Prefix(s: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
    val sb = StringBuilder(digest.size * 2)
    for (b in digest) sb.append(String.format("%02x", b))
    return sb.substring(0, 32)
}
