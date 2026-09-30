export type CloudMedication = {
  id: string;
  data: Record<string, unknown>;
};
export type CloudLog = { data: Record<string, unknown> };
export type DueDose = {
  medicationId: string;
  scheduleId: string;
  doseDay: string;
};

function localParts(instant: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(instant);
  const get = (type: string) => Number(parts.find((part) => part.type === type)?.value);
  return { year: get('year'), month: get('month'), day: get('day'), hour: get('hour'), minute: get('minute') };
}

function dateKey(year: number, month: number, day: number) {
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

function scheduledInstant(day: Date, hour: number, minute: number, timeZone: string) {
  const target = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), hour, minute);
  let guess = target;
  // Resolve an IANA local wall time without relying on the Edge Function's zone.
  for (let i = 0; i < 3; i++) {
    const local = localParts(new Date(guess), timeZone);
    const observed = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute);
    guess += target - observed;
  }
  return guess;
}

/** A dose is eligible 30 minutes after schedule, for at most three hours. */
export function dueDoses(
  medications: CloudMedication[], logs: CloudLog[], timeZone: string, now: Date,
): DueDose[] {
  const localNow = localParts(now, timeZone);
  const today = new Date(Date.UTC(localNow.year, localNow.month - 1, localNow.day));
  const days = [today, new Date(today.getTime() - 86_400_000)];
  const latest = new Map<string, { timestamp: number; status: unknown }>();
  for (const row of logs) {
    const data = row.data;
    const stamp = data.timestamp;
    const medicationId = data.medicationId;
    const scheduleId = data.scheduleId;
    if (typeof stamp !== 'number' || !Number.isFinite(stamp) ||
        typeof medicationId !== 'string' || typeof scheduleId !== 'string') continue;
    const parts = localParts(new Date(stamp), timeZone);
    const key = `${medicationId}\u0000${scheduleId}\u0000${dateKey(parts.year, parts.month, parts.day)}`;
    if (!latest.has(key) || latest.get(key)!.timestamp < stamp) {
      latest.set(key, { timestamp: stamp, status: data.status });
    }
  }
  const result: DueDose[] = [];
  for (const medication of medications) {
    if (medication.data.is_active === 0 || medication.data.is_active === false) continue;
    const schedules = medication.data.schedules;
    if (!Array.isArray(schedules)) continue;
    for (const schedule of schedules) {
      if (schedule === null || typeof schedule !== 'object') continue;
      const { id, hour, minute } = schedule as Record<string, unknown>;
      if (typeof id !== 'string' || typeof hour !== 'number' || typeof minute !== 'number' ||
          !Number.isInteger(hour) || !Number.isInteger(minute) ||
          hour < 0 || hour > 23 || minute < 0 || minute > 59) continue;
      for (const day of days) {
        const doseDay = dateKey(day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate());
        const elapsed = now.getTime() - scheduledInstant(day, hour, minute, timeZone);
        if (elapsed < 30 * 60_000 || elapsed > 180 * 60_000) continue;
        if (latest.get(`${medication.id}\u0000${id}\u0000${doseDay}`)?.status === 'taken') continue;
        result.push({ medicationId: medication.id, scheduleId: id, doseDay });
      }
    }
  }
  return result;
}
