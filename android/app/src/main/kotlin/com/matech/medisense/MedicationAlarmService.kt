package com.matech.medisense

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject
import java.util.Locale

class MedicationAlarmService : Service() {
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var speaker: TextToSpeech? = null
    private val repeatHandler = Handler(Looper.getMainLooper())
    private var repeatSpeech: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val requestedId = intent.getIntExtra(EXTRA_ID, -1)
                if (requestedId == -1 || requestedId == currentAlarmId) {
                    stopAlarm()
                    return START_NOT_STICKY
                }
                stopSelfResult(startId)
                return START_STICKY
            }
            ACTION_SNOOZE -> {
                MedicationAlarm.fromIntent(intent)?.let {
                    runCatching { MedicationAlarmScheduler.snooze(this, it) }
                }
                stopAlarm()
                return START_NOT_STICKY
            }
        }

        val alarm = intent?.let(MedicationAlarm::fromIntent) ?: activeAlarm()
        if (alarm == null) {
            stopAlarm()
            return START_NOT_STICKY
        }

        currentAlarmId = alarm.id
        saveActiveAlarm(alarm)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(alarm))
        startAlarmSoundAndVibration(alarm)
        return START_STICKY
    }

    private fun startAlarmSoundAndVibration(alarm: MedicationAlarm) {
        stopPlayback()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener { }
                .build()
            audioManager?.requestAudioFocus(audioFocusRequest!!)
        }

        speaker = TextToSpeech(this) { status ->
            if (currentAlarmId != alarm.id) return@TextToSpeech
            if (status == TextToSpeech.SUCCESS) {
                speaker?.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                val language = speaker?.setLanguage(Locale("fil", "PH"))
                if (language == TextToSpeech.LANG_MISSING_DATA ||
                    language == TextToSpeech.LANG_NOT_SUPPORTED) {
                    speaker?.language = Locale.US
                }
                val repeat = object : Runnable {
                    override fun run() {
                        if (currentAlarmId != alarm.id) return
                        val spoken = speaker?.speak(
                            alarm.body,
                            TextToSpeech.QUEUE_FLUSH,
                            Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1f) },
                            "dose-${alarm.id}",
                        ) ?: TextToSpeech.ERROR
                        if (spoken == TextToSpeech.ERROR) {
                            startFallbackTone()
                            return
                        }
                        repeatHandler.postDelayed(this, 9000)
                    }
                }
                repeatSpeech = repeat
                repeatHandler.post(repeat)
            } else {
                startFallbackTone()
            }
        }

        vibrator = getSystemService(Vibrator::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(
                VibrationEffect.createWaveform(longArrayOf(0, 1100, 300, 1100, 650), 0),
            )
        }
    }

    private fun startFallbackTone() {
        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        if (alarmUri != null) {
            runCatching {
                MediaPlayer().also { mediaPlayer ->
                    mediaPlayer.setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    mediaPlayer.setWakeMode(this, android.os.PowerManager.PARTIAL_WAKE_LOCK)
                    mediaPlayer.isLooping = true
                    mediaPlayer.setVolume(1f, 1f)
                    mediaPlayer.setDataSource(this, alarmUri)
                    mediaPlayer.setOnPreparedListener { it.start() }
                    mediaPlayer.setOnErrorListener { failedPlayer, _, _ ->
                        failedPlayer.release()
                        if (player === failedPlayer) player = null
                        true
                    }
                    player = mediaPlayer
                    mediaPlayer.prepareAsync()
                }
            }
        }

    }

    private fun buildNotification(alarm: MedicationAlarm): Notification {
        val takenIntent = PendingIntent.getActivity(
            this,
            alarm.id xor REQUEST_TAKEN,
            alarm.putIn(
                Intent(this, MainActivity::class.java)
                    .setAction(ACTION_MARK_TAKEN)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snoozeIntent = actionIntent(alarm, ACTION_SNOOZE, REQUEST_SNOOZE)
        val stopIntent = actionIntent(alarm, ACTION_STOP, REQUEST_STOP)
        val openApp = PendingIntent.getActivity(
            this,
            alarm.id,
            alarm.putIn(Intent(this, MainActivity::class.java)
                .setAction(ACTION_OPEN_ALARM)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Medication alarm is ringing")
            .setContentText("${alarm.title} · ${alarm.body}")
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_ALARM)
            .setFullScreenIntent(openApp, true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(
                        this,
                        android.R.drawable.checkbox_on_background,
                    ),
                    "I took it",
                    takenIntent,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(
                        this,
                        android.R.drawable.ic_lock_idle_alarm,
                    ),
                    "Snooze 5 min",
                    snoozeIntent,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(
                        this,
                        android.R.drawable.ic_menu_close_clear_cancel,
                    ),
                    "Stop alarm",
                    stopIntent,
                ).build(),
            )
            .build()
    }

    private fun actionIntent(alarm: MedicationAlarm, action: String, requestCode: Int) =
        PendingIntent.getService(
            this,
            alarm.id xor requestCode,
            alarm.putIn(Intent(this, MedicationAlarmService::class.java).setAction(action)),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Active medication alarm",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Silent service controls while a medication alarm rings"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                },
            )
        }
    }

    private fun stopAlarm() {
        clearActiveAlarm()
        stopPlayback()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopPlayback() {
        repeatSpeech?.let(repeatHandler::removeCallbacks)
        repeatSpeech = null
        speaker?.stop()
        speaker?.shutdown()
        speaker = null
        player?.let { mediaPlayer ->
            runCatching { if (mediaPlayer.isPlaying) mediaPlayer.stop() }
            mediaPlayer.reset()
            mediaPlayer.release()
        }
        player = null
        vibrator?.cancel()
        vibrator = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
        }
        audioFocusRequest = null
        audioManager = null
    }

    private fun saveActiveAlarm(alarm: MedicationAlarm) {
        getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(ACTIVE_ALARM, alarm.toJson().toString())
            .apply()
    }

    private fun activeAlarm(): MedicationAlarm? = runCatching {
        val encoded = getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .getString(ACTIVE_ALARM, null) ?: return null
        MedicationAlarm.fromJson(JSONObject(encoded))
    }.getOrNull()

    private fun clearActiveAlarm() {
        getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(ACTIVE_ALARM)
            .apply()
    }

    override fun onDestroy() {
        stopPlayback()
        currentAlarmId = null
        super.onDestroy()
    }

    companion object {
        const val ACTION_RING = "com.matech.medisense.action.RING_ALARM"
        const val ACTION_STOP = "com.matech.medisense.action.STOP_ALARM"
        const val ACTION_SNOOZE = "com.matech.medisense.action.SNOOZE_ALARM"
        const val ACTION_MARK_TAKEN = "com.matech.medisense.action.MARK_TAKEN"
        const val ACTION_OPEN_ALARM = "com.matech.medisense.action.OPEN_ALARM"

        private const val CHANNEL_ID = "medication_alarm_screen"
        private const val NOTIFICATION_ID = 72940
        private const val SERVICE_PREFS = "medisense_alarm_service"
        private const val ACTIVE_ALARM = "active_alarm"
        private const val REQUEST_SNOOZE = 0x1357
        private const val REQUEST_STOP = 0x2468
        private const val REQUEST_TAKEN = 0x369c

        @Volatile
        private var currentAlarmId: Int? = null

        fun stopIfActive(context: Context, alarmId: Int) {
            if (currentAlarmId == alarmId) {
                context.startService(
                    Intent(context, MedicationAlarmService::class.java)
                        .setAction(ACTION_STOP)
                        .putExtra(EXTRA_ID, alarmId),
                )
            }
        }
    }
}
