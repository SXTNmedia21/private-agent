package com.orailnoor.privateagent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reconnects the phone to the bridge after a reboot, but only when Flutter has opted in.
 *
 * The flag is written by the shared_preferences plugin, which prefixes every key with "flutter."
 * — reading a bare "bridge_enabled" here would silently always be false.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        const val PREFS = "FlutterSharedPreferences"
        const val KEY_ENABLED = "flutter.bridge_enabled"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) return

        val enabled = try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_ENABLED, false)
        } catch (_: Throwable) {
            false
        }
        if (!enabled) return

        try {
            AgentForegroundService.start(context, "Reconnecting after boot")
        } catch (_: Throwable) {
            // Boot-time foreground starts can be refused; the app will start it on next launch.
        }
    }
}
