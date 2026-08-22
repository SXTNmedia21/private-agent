package com.orailnoor.privateagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while the bridge WebSocket is connected. Without a foreground service
 * One UI's aggressive background policy kills the socket within minutes of screen-off.
 */
class AgentForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "agent_bridge"
        const val NOTIFICATION_ID = 4201

        const val ACTION_START = "com.orailnoor.privateagent.FGS_START"
        const val ACTION_STOP = "com.orailnoor.privateagent.FGS_STOP"
        const val ACTION_UPDATE = "com.orailnoor.privateagent.FGS_UPDATE"
        const val EXTRA_TEXT = "text"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, text: String? = null) {
            val i = Intent(context, AgentForegroundService::class.java).apply {
                action = ACTION_START
                if (text != null) putExtra(EXTRA_TEXT, text)
            }
            // API 26+ refuses startService from the background; startForegroundService gives us
            // the 5 s window we satisfy in onStartCommand.
            context.startForegroundService(i)
        }

        fun stop(context: Context) {
            val i = Intent(context, AgentForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                // Still startForegroundService: API 26+ refuses a background startService, and
                // onStartCommand satisfies the 5 s contract before it stops itself.
                context.startForegroundService(i)
            } catch (_: Throwable) {
                context.stopService(Intent(context, AgentForegroundService::class.java))
            }
        }

        fun update(context: Context, text: String) {
            val i = Intent(context, AgentForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TEXT, text)
            }
            context.startForegroundService(i)
        }
    }

    private var statusText: String = "Connected to bridge"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground FIRST, unconditionally: the system ANRs the process if we take longer
        // than 5 s, and that includes the STOP path (we were started as a foreground service).
        goForeground()

        when (intent?.action) {
            ACTION_STOP -> {
                isRunning = false
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                intent.getStringExtra(EXTRA_TEXT)?.let { statusText = it }
                goForeground()
            }
            else -> {
                intent?.getStringExtra(EXTRA_TEXT)?.let { statusText = it }
                goForeground()
            }
        }
        isRunning = true
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun goForeground() {
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (_: Throwable) {
            // A denied foreground-service start must not take the whole app down.
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(Service.STOP_FOREGROUND_REMOVE)
            } else {
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, "Bridge connection", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps PrivateAgent connected to the bridge"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("PrivateAgent")
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }
}
