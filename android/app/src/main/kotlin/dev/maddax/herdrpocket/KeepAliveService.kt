package dev.maddax.herdrpocket

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Holds this app's process alive while it is in the background.
 *
 * ## Why this is the only way
 *
 * The whole product is one long-lived SSH connection. Android freezes the
 * process of a backgrounded app, and a frozen process runs no Dart: the SSH
 * keepalive stops being written, and the connection dies in the middle — the
 * NAT table, the cellular handover, or the overlay network carrying it — with
 * neither end told. That is the failure this service exists to prevent, and a
 * foreground service is the one mechanism Android provides for it.
 *
 * ## It is a TOGGLE, not a mode
 *
 * A foreground service is started and stopped by this app's own code
 * (`startForegroundService` / `stopService`), so the switch in Settings turns it
 * on and off at runtime and the notification comes and goes with it. The two
 * manifest entries — the service and its permission — are declarations, and a
 * declaration on its own does nothing visible.
 *
 * ## What it does NOT do
 *
 * It does not reconnect anything, and it does not talk to the network. It holds
 * the process; the connection itself belongs to Dart, and its recovery belongs
 * to `ConnectionNotifier`. `START_NOT_STICKY` is deliberate: if the system kills
 * this process, the Dart side that owns the connection goes with it, and a
 * service restarted on its own would be a notification with nothing behind it.
 */
class KeepAliveService : Service() {

    companion object {
        /** Channel the Dart side starts and stops this through. */
        const val CHANNEL = "dev.maddax.herdrpocket/keep_alive"

        /** The notification's two lines, written by Dart so they are localized. */
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        /**
         * The notification's channel id.
         *
         * LOW importance: this is a statement of fact, not an alert. IMPORTANCE_
         * DEFAULT would buzz the phone every time the user leaves the app. The
         * channel's NAME is deliberately not localized, for the same reason the
         * agent-attention channel's is not (`agent_notifier.dart`): Android
         * remembers a channel by id and keeps the name it was created with, so a
         * translated name would only ever appear for users whose first launch
         * was in that language.
         */
        const val CHANNEL_ID = "herdr-pocket-keepalive"
        const val CHANNEL_NAME = "Connection keep-alive"
        const val CHANNEL_DESCRIPTION =
            "Shown while the connection to your machine is held open in the background."

        /** Fixed, so a second start replaces the notification instead of stacking. */
        const val NOTIFICATION_ID = 0x4841 // 'HA'

        /**
         * Starts or re-labels the service.
         *
         * Repeat calls are cheap and expected: the label carries the machine's
         * name, and switching machines re-labels the same notification rather
         * than stacking a second one.
         */
        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, KeepAliveService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            ContextCompat.startForegroundService(context, intent)
        }

        /** Stops it, and takes the notification with it. */
        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: return START_NOT_STICKY
        val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
        ensureChannel()
        val notification = buildNotification(title, text)

        // The TYPE is mandatory from Android 14 for an app targeting 34+, and it
        // must match the manifest's `foregroundServiceType`. `specialUse` is the
        // honest one here: there is no category for "the user asked this app to
        // keep a connection to their own machine open", and the alternatives are
        // worse — `dataSync` is capped at six hours a day from Android 15 (which
        // is a connection that dies halfway through a working day), and
        // `connectedDevice` means a Bluetooth/USB-style peripheral.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Not sticky: see the class comment.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        // The service can be killed from under us (the user swipes the app away,
        // the system reclaims memory). Dropping the notification here keeps the
        // tray honest: a notification whose service is gone claims something
        // that is no longer true.
        NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun buildNotification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_keep_alive)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            // The user can still dismiss the notification on some builds; the
            // service keeps running either way, which is the honest behaviour —
            // a notification is how Android explains a foreground service, not
            // the service itself.
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = CHANNEL_DESCRIPTION
                setShowBadge(false)
            },
        )
    }
}
