package com.matech.medisense

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject
import java.util.Calendar

internal data class MedicationAlarm(
    val id: Int,
    val title: String,
    val body: String,
    val medicationId: String,
    val scheduleId: String,
    val hour: Int,
    val minute: Int,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title)
        .put("body", body)
        .put("medicationId", medicationId)
        .put("scheduleId", scheduleId)
        .put("hour", hour)
        .put("minute", minute)

    fun putIn(intent: Intent): Intent = intent
        .putExtra(EXTRA_ID, id)
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_BODY, body)
        .putExtra(EXTRA_MEDICATION_ID, medicationId)
        .putExtra(EXTRA_SCHEDULE_ID, scheduleId)
        .putExtra(EXTRA_HOUR, hour)
        .putExtra(EXTRA_MINUTE, minute)

    companion object {
        fun fromJson(value: JSONObject) = MedicationAlarm(
            id = value.getInt("id"),
            title = value.getString("title"),
            body = value.getString("body"),
            medicationId = value.getString("medicationId"),
            scheduleId = value.getString("scheduleId"),
            hour = value.getInt("hour"),
            minute = value.getInt("minute"),
        )

        fun fromIntent(intent: Intent): MedicationAlarm? {
            if (!intent.hasExtra(EXTRA_ID)) return null
            return MedicationAlarm(
                id = intent.getIntExtra(EXTRA_ID, 0),
                title = intent.getStringExtra(EXTRA_TITLE) ?: "Medication alarm",
                body = intent.getStringExtra(EXTRA_BODY) ?: "Time to take your medicine",
                medicationId = intent.getStringExtra(EXTRA_MEDICATION_ID) ?: "",
                scheduleId = intent.getStringExtra(EXTRA_SCHEDULE_ID) ?: "",
                hour = intent.getIntExtra(EXTRA_HOUR, 8),
                minute = intent.getIntExtra(EXTRA_MINUTE, 0),
            )
        }
    }
}

internal object MedicationAlarmScheduler {
    private const val PREFS = "medisense_native_alarms"
    private const val PREFIX_ALARM = "alarm:"
    private const val PREFIX_SNOOZE = "snooze:"

    fun schedule(context: Context, alarm: MedicationAlarm) {
        checkExactAlarmAccess(context)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFIX_ALARM + alarm.id, alarm.toJson().toString())
            .apply()
        scheduleAt(context, alarm, nextDailyTrigger(alarm), snooze = false)
    }

    fun replaceAll(context: Context, alarms: List<MedicationAlarm>) {
        checkExactAlarmAccess(context)
        val keepIds = alarms.map { it.id }.toSet()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val staleKeys = prefs.all.keys.filter { key ->
            val isAlarm = key.startsWith(PREFIX_ALARM) || key.startsWith(PREFIX_SNOOZE)
            val id = key.substringAfter(':').toIntOrNull()
            isAlarm && id != null && id !in keepIds
        }
        staleKeys.forEach { key ->
            val id = key.substringAfter(':').toIntOrNull() ?: return@forEach
            val snooze = key.startsWith(PREFIX_SNOOZE)
            alarmManager(context).cancel(pendingIntent(context, id, snooze))
        }
        prefs.edit().also { editor ->
            staleKeys.forEach { editor.remove(it) }
        }.apply()
        alarms.forEach { schedule(context, it) }
    }

    fun cancel(context: Context, id: Int) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .remove(PREFIX_ALARM + id)
            .remove(PREFIX_SNOOZE + id)
            .apply()
        alarmManager(context).cancel(pendingIntent(context, id, snooze = false))
        alarmManager(context).cancel(pendingIntent(context, id, snooze = true))
    }

    fun cancelAll(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val keys = prefs.all.keys.toList()
        keys.forEach { key ->
            val encoded = prefs.getString(key, null) ?: return@forEach
            val alarm = runCatching { MedicationAlarm.fromJson(JSONObject(encoded)) }.getOrNull()
                ?: return@forEach
            val snooze = key.startsWith(PREFIX_SNOOZE)
            alarmManager(context).cancel(pendingIntent(context, alarm.id, snooze))
        }
        prefs.edit().clear().apply()
    }

    fun onAlarmFired(context: Context, alarm: MedicationAlarm, snooze: Boolean) {
        if (snooze) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(PREFIX_SNOOZE + alarm.id)
                .apply()
        } else {
            runCatching { scheduleAt(context, alarm, nextDailyTrigger(alarm), snooze = false) }
        }
    }

    fun snooze(context: Context, alarm: MedicationAlarm) {
        checkExactAlarmAccess(context)
        val triggerAt = System.currentTimeMillis() + SNOOZE_MILLIS
        val value = alarm.toJson().put("triggerAt", triggerAt)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFIX_SNOOZE + alarm.id, value.toString())
            .apply()
        scheduleAt(context, alarm, triggerAt, snooze = true)
    }

    /**
     * Defers an already-scheduled reminder by [SNOOZE_MILLIS] without touching
     * the medication schedule. Returns false when no stored alarm has that id,
     * so the caller can report that the reminder is gone.
     */
    fun snoozeStored(context: Context, id: Int): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val encoded = prefs.getString(PREFIX_ALARM + id, null) ?: return false
        val alarm = runCatching { MedicationAlarm.fromJson(JSONObject(encoded)) }.getOrNull()
            ?: return false
        snooze(context, alarm)
        return true
    }

    fun restore(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager(context).canScheduleExactAlarms()) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.all.forEach { (key, encoded) ->
            if (encoded !is String) return@forEach
            runCatching {
                val value = JSONObject(encoded)
                val alarm = MedicationAlarm.fromJson(value)
                if (key.startsWith(PREFIX_SNOOZE)) {
                    val triggerAt = value.optLong("triggerAt", 0L)
                    if (triggerAt > System.currentTimeMillis()) {
                        scheduleAt(context, alarm, triggerAt, snooze = true)
                    } else {
                        prefs.edit().remove(key).apply()
                    }
                } else if (key.startsWith(PREFIX_ALARM)) {
                    scheduleAt(context, alarm, nextDailyTrigger(alarm), snooze = false)
                }
            }
        }
    }

    private fun scheduleAt(context: Context, alarm: MedicationAlarm, at: Long, snooze: Boolean) {
        checkExactAlarmAccess(context)
        val pendingIntent = pendingIntent(context, alarm.id, snooze, alarm)
        val showIntent = PendingIntent.getActivity(
            context,
            alarm.id,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager(context).setAlarmClock(
            AlarmManager.AlarmClockInfo(at, showIntent),
            pendingIntent,
        )
    }

    private fun pendingIntent(
        context: Context,
        id: Int,
        snooze: Boolean,
        alarm: MedicationAlarm? = null,
    ): PendingIntent {
        val action = if (snooze) "$ACTION_FIRE:snooze:$id" else "$ACTION_FIRE:$id"
        val intent = Intent(context, MedicationAlarmReceiver::class.java).setAction(action)
        alarm?.putIn(intent)
        val requestCode = if (snooze) id xor SNOOZE_REQUEST_CODE_MASK else id
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun nextDailyTrigger(alarm: MedicationAlarm): Long {
        val now = Calendar.getInstance()
        val next = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, alarm.hour)
            set(Calendar.MINUTE, alarm.minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (!after(now)) add(Calendar.DAY_OF_YEAR, 1)
        }
        return next.timeInMillis
    }

    private fun checkExactAlarmAccess(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager(context).canScheduleExactAlarms()) {
            throw SecurityException("Allow alarms and reminders for MediSense in Android Settings.")
        }
    }

    private fun alarmManager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private const val ACTION_FIRE = "com.matech.medisense.MEDICATION_ALARM"
    private const val SNOOZE_MILLIS = 5 * 60 * 1000L
    private const val SNOOZE_REQUEST_CODE_MASK = 0x40000000
}

internal const val EXTRA_ID = "alarm_id"
internal const val EXTRA_TITLE = "alarm_title"
internal const val EXTRA_BODY = "alarm_body"
internal const val EXTRA_MEDICATION_ID = "medication_id"
internal const val EXTRA_SCHEDULE_ID = "schedule_id"
internal const val EXTRA_HOUR = "alarm_hour"
internal const val EXTRA_MINUTE = "alarm_minute"
internal const val EXTRA_IS_SNOOZE = "alarm_is_snooze"

class MedicationAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val alarm = MedicationAlarm.fromIntent(intent) ?: return
        val snooze = intent.action?.contains(":snooze:") == true
        MedicationAlarmScheduler.onAlarmFired(context, alarm, snooze)
        val service = Intent(context, MedicationAlarmService::class.java)
            .setAction(MedicationAlarmService.ACTION_RING)
            .putExtras(intent)
            .putExtra(EXTRA_IS_SNOOZE, snooze)
        context.startForegroundService(service)
    }
}

class MedicationAlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        MedicationAlarmScheduler.restore(context)
    }
}
