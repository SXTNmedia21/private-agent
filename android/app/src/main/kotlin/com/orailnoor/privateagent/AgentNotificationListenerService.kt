package com.orailnoor.privateagent

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Read/act side of the notification surface. The bridge needs to see what the phone was told and
 * be able to answer it (open, dismiss, snooze, inline-reply) without opening the app.
 *
 * Bound by the system only once the user grants notification access in Settings; until then
 * [instance] stays null and every caller gets NO_NOTIFICATION_ACCESS instead of a crash.
 */
class AgentNotificationListenerService : NotificationListenerService() {

    companion object {
        @Volatile
        var instance: AgentNotificationListenerService? = null
            private set

        /**
         * Settings.Secure is the source of truth for "access granted". [instance] only tells us
         * whether the system has bound us yet, which lags the grant by a moment.
         */
        fun isAccessGranted(context: Context): Boolean {
            return try {
                val flat = android.provider.Settings.Secure.getString(
                    context.contentResolver, "enabled_notification_listeners"
                ) ?: return false
                flat.split(':').any { it.contains(context.packageName) }
            } catch (_: Throwable) {
                false
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Pull model: the bridge asks for the list when it wants it. Nothing to do on post.
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {}

    // ─── Operations ──────────────────────────────────────────────

    fun listNotifications(): List<Map<String, Any?>> {
        val active = try {
            activeNotifications ?: emptyArray()
        } catch (_: Throwable) {
            emptyArray<StatusBarNotification>()
        }
        return active.map { sbn ->
            val extras = sbn.notification?.extras
            mapOf(
                "id" to sbn.key,
                "package" to sbn.packageName,
                "title" to charSeq(extras, Notification.EXTRA_TITLE),
                "text" to charSeq(extras, Notification.EXTRA_TEXT),
                "posted_at" to sbn.postTime,
                "is_clearable" to sbn.isClearable
            )
        }
    }

    private fun charSeq(extras: Bundle?, key: String): String? =
        try {
            extras?.getCharSequence(key)?.toString()
        } catch (_: Throwable) {
            null
        }

    fun byKey(key: String): StatusBarNotification? = try {
        activeNotifications?.firstOrNull { it.key == key }
    } catch (_: Throwable) {
        null
    }

    fun open(key: String): Boolean {
        val sbn = byKey(key) ?: return false
        val pi = sbn.notification?.contentIntent ?: return false
        return try {
            pi.send()
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun dismiss(key: String): Boolean = try {
        cancelNotification(key)
        true
    } catch (_: Throwable) {
        false
    }

    fun snooze(key: String, ms: Long): Boolean = try {
        snoozeNotification(key, ms)
        true
    } catch (_: Throwable) {
        false
    }

    /** Fire the first action that carries a RemoteInput — that is the inline reply box. */
    fun reply(key: String, text: String): Boolean {
        val sbn = byKey(key) ?: return false
        val actions = sbn.notification?.actions ?: return false
        for (action in actions) {
            val inputs = action.remoteInputs ?: continue
            if (inputs.isEmpty()) continue
            return try {
                val intent = Intent()
                val bundle = Bundle()
                for (ri in inputs) bundle.putCharSequence(ri.resultKey, text)
                RemoteInput.addResultsToIntent(inputs, intent, bundle)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT)
                }
                action.actionIntent.send(applicationContext, 0, intent)
                true
            } catch (_: Throwable) {
                false
            }
        }
        return false
    }

    fun fireAction(key: String, name: String): Boolean {
        val sbn = byKey(key) ?: return false
        val actions = sbn.notification?.actions ?: return false
        val match = actions.firstOrNull {
            val t = it.title?.toString() ?: ""
            t.equals(name, true) || t.contains(name, true)
        } ?: return false
        return try {
            match.actionIntent.send()
            true
        } catch (_: Throwable) {
            false
        }
    }
}
