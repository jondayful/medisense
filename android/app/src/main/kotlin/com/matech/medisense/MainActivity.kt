package com.matech.medisense

import android.content.Intent
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var alarmChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        if (intent?.action == MedicationAlarmService.ACTION_OPEN_ALARM) showAlarmOverLockScreen()
        super.onCreate(savedInstanceState)
    }

    private fun showAlarmOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medisense/storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "availableBytes") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val directory = call.argument<String>("path")
                if (directory.isNullOrBlank()) {
                    result.error("INVALID_PATH", "A storage path is required.", null)
                    return@setMethodCallHandler
                }
                try {
                    result.success(StatFs(directory).availableBytes)
                } catch (error: IllegalArgumentException) {
                    result.error("STORAGE_UNAVAILABLE", error.message, null)
                }
            }

        alarmChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "medisense/alarm")
        alarmChannel?.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "ensureFullScreenAccess" -> {
                            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            val allowed = Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent()
                            if (!allowed) {
                                startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")))
                            }
                            result.success(allowed)
                        }
                        "takeLaunchAlarmAction" -> {
                            if (intent.action == MedicationAlarmService.ACTION_MARK_TAKEN ||
                                intent.action == MedicationAlarmService.ACTION_OPEN_ALARM) {
                                val action = mapOf(
                                    "type" to if (intent.action == MedicationAlarmService.ACTION_OPEN_ALARM) "open" else "taken",
                                    "medicationId" to intent.getStringExtra(EXTRA_MEDICATION_ID),
                                    "scheduleId" to intent.getStringExtra(EXTRA_SCHEDULE_ID),
                                )
                                setIntent(Intent(this, MainActivity::class.java))
                                result.success(action)
                            } else {
                                result.success(null)
                            }
                        }
                        "syncAlarms" -> {
                            val alarmMaps = call.argument<List<*>>("alarms") ?: emptyList<Any>()
                            val alarms = alarmMaps.map { entry ->
                                val fields = entry as? Map<*, *>
                                    ?: throw IllegalArgumentException("Invalid alarm entry.")
                                fun number(name: String): Int =
                                    (fields[name] as? Number)?.toInt()
                                        ?: throw IllegalArgumentException("Alarm $name is required.")
                                MedicationAlarm(
                                    id = number("id"),
                                    title = fields["title"] as? String ?: "Medication alarm",
                                    body = fields["body"] as? String ?: "Time to take your medicine",
                                    medicationId = fields["medicationId"] as? String ?: "",
                                    scheduleId = fields["scheduleId"] as? String ?: "",
                                    hour = number("hour"),
                                    minute = number("minute"),
                                )
                            }
                            MedicationAlarmScheduler.replaceAll(this, alarms)
                            result.success(null)
                        }
                        "scheduleAlarm" -> {
                            val id = call.argument<Int>("id")
                                ?: throw IllegalArgumentException("Alarm ID is required.")
                            val alarm = MedicationAlarm(
                                id = id,
                                title = call.argument<String>("title") ?: "Medication alarm",
                                body = call.argument<String>("body") ?: "Time to take your medicine",
                                medicationId = call.argument<String>("medicationId") ?: "",
                                scheduleId = call.argument<String>("scheduleId") ?: "",
                                hour = call.argument<Int>("hour")
                                    ?: throw IllegalArgumentException("Alarm hour is required."),
                                minute = call.argument<Int>("minute")
                                    ?: throw IllegalArgumentException("Alarm minute is required."),
                            )
                            MedicationAlarmScheduler.schedule(this, alarm)
                            result.success(null)
                        }
                        "ringNow" -> {
                            val alarm = MedicationAlarm(
                                id = call.argument<Int>("id")
                                    ?: throw IllegalArgumentException("Alarm ID is required."),
                                title = call.argument<String>("title") ?: "Medication reminder",
                                body = call.argument<String>("body") ?: "Time to take your medicine",
                                medicationId = call.argument<String>("medicationId") ?: "",
                                scheduleId = call.argument<String>("scheduleId") ?: "",
                                hour = 0,
                                minute = 0,
                            )
                            startForegroundService(alarm.putIn(
                                Intent(this, MedicationAlarmService::class.java)
                                    .setAction(MedicationAlarmService.ACTION_RING),
                            ))
                            result.success(null)
                        }
                        "cancelAlarm" -> {
                            val id = call.argument<Int>("id")
                                ?: throw IllegalArgumentException("Alarm ID is required.")
                            MedicationAlarmScheduler.cancel(this, id)
                            MedicationAlarmService.stopIfActive(this, id)
                            result.success(null)
                        }
                        "cancelAllAlarms" -> {
                            MedicationAlarmScheduler.cancelAll(this)
                            startService(
                                Intent(this, MedicationAlarmService::class.java)
                                    .setAction(MedicationAlarmService.ACTION_STOP),
                            )
                            result.success(null)
                        }
                        "stopRinging" -> {
                            startService(
                                Intent(this, MedicationAlarmService::class.java)
                                    .setAction(MedicationAlarmService.ACTION_STOP),
                            )
                            result.success(null)
                        }
                        "snoozeAlarm" -> {
                            // The id comes from Dart so the notification hash is
                            // never implemented twice across the boundary.
                            val id = call.argument<Int>("id")
                                ?: throw IllegalArgumentException("An alarm id is required to snooze.")
                            MedicationAlarmService.stopIfActive(this, id)
                            if (!MedicationAlarmScheduler.snoozeStored(this, id)) {
                                throw IllegalStateException("That reminder is no longer scheduled.")
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("ALARM_OPERATION_FAILED", error.message, null)
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == MedicationAlarmService.ACTION_OPEN_ALARM) showAlarmOverLockScreen()
        if (intent.action == MedicationAlarmService.ACTION_MARK_TAKEN ||
            intent.action == MedicationAlarmService.ACTION_OPEN_ALARM) {
            val action = mapOf(
                "type" to if (intent.action == MedicationAlarmService.ACTION_OPEN_ALARM) "open" else "taken",
                "medicationId" to intent.getStringExtra(EXTRA_MEDICATION_ID),
                "scheduleId" to intent.getStringExtra(EXTRA_SCHEDULE_ID),
            )
            alarmChannel?.invokeMethod("alarmAction", action, object : MethodChannel.Result {
                override fun success(result: Any?) = Unit
                override fun error(code: String, message: String?, details: Any?) = Unit
                override fun notImplemented() = Unit
            })
        }
    }
}
