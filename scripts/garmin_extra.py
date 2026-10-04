"""Hilfsfunktionen für garmin_fitness.R (per reticulate::source_python eingebunden).

Die Umwandlung passiert in Python, weil reticulate Python-Ints > 2^31 in R als
Integer überlaufen lässt (Zeitstempel in ms, IDs). Zurück nach R gehen nur kleine Zahlen,
Fließkommazahlen und Strings. Jeder Garmin-Aufruf ist einzeln abgesichert: fehlt ein
Wert, kommt NA statt eines Abbruchs.
"""
from datetime import datetime, timezone


def _try(f, *args):
    try:
        return f(*args)
    except Exception:
        return None


def _g(d, *keys):
    for k in keys:
        if not isinstance(d, dict) or d.get(k) is None:
            return None
        d = d[k]
    return d


def _clock(ms):
    # "...Local"-Zeitstempel sind Millisekunden der lokalen Uhrzeit, als wäre sie UTC
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def _hours(sec):
    return None if sec is None else sec / 3600.0


def extra_day(api, d):
    """Schlaf, HRV, Training Readiness und Trainingsstatus eines Tages (4 API-Aufrufe)."""
    sl = _try(api.get_sleep_data, d) or {}
    dto = sl.get("dailySleepDTO") or {}
    hrv = (_try(api.get_hrv_data, d) or {}).get("hrvSummary") or {}
    rd = _try(api.get_morning_training_readiness, d) or {}
    if isinstance(rd, list):
        rd = rd[0] if rd else {}
    ts = _try(api.get_training_status, d) or {}
    lts = list(((ts.get("mostRecentTrainingStatus") or {}).get("latestTrainingStatusData") or {}).values())
    lts = lts[0] if lts else {}
    acute = lts.get("acuteTrainingLoadDTO") or {}
    return {
        # Schlaf (wie bisher)
        "sleep_h": _hours(dto.get("sleepTimeSeconds")),
        "deep_h": _hours(dto.get("deepSleepSeconds")),
        "light_h": _hours(dto.get("lightSleepSeconds")),
        "rem_h": _hours(dto.get("remSleepSeconds")),
        "awake_h": _hours(dto.get("awakeSleepSeconds")),
        "sleep_score": _g(dto, "sleepScores", "overall", "value"),
        # Schlaf (neu)
        "sleep_start": _clock(dto.get("sleepStartTimestampLocal")),
        "sleep_end": _clock(dto.get("sleepEndTimestampLocal")),
        "sleep_need_min": _g(dto, "sleepNeed", "actual"),
        "sleep_hr": dto.get("avgHeartRate"),
        "sleep_stress": dto.get("avgSleepStress"),
        "awake_count": dto.get("awakeCount"),
        "restless": sl.get("restlessMomentsCount"),
        "spo2_avg": dto.get("averageSpO2Value"),
        "spo2_low": dto.get("lowestSpO2Value"),
        "resp_sleep": dto.get("averageRespirationValue"),
        "skin_temp_dev": sl.get("avgSkinTempDeviationC"),
        "bb_sleep_change": sl.get("bodyBatteryChange"),
        # HRV
        "hrv_night": sl.get("avgOvernightHrv") if sl.get("avgOvernightHrv") is not None else hrv.get("lastNightAvg"),
        "hrv_weekly": hrv.get("weeklyAvg"),
        "hrv_5min_high": hrv.get("lastNight5MinHigh"),
        "hrv_base_low": _g(hrv, "baseline", "balancedLow"),
        "hrv_base_high": _g(hrv, "baseline", "balancedUpper"),
        "hrv_status": hrv.get("status"),
        # Training Readiness (Morgenwert), Garmin-eigene Last und Fitness
        "ready_score": rd.get("score"),
        "ready_level": rd.get("level"),
        "recovery_h": None if rd.get("recoveryTime") is None else rd["recoveryTime"] / 60.0,
        "ts_acute": acute.get("dailyTrainingLoadAcute"),
        "ts_chronic": acute.get("dailyTrainingLoadChronic"),
        "ts_acwr": acute.get("dailyAcuteChronicWorkloadRatio"),
        "ts_status": lts.get("trainingStatusFeedbackPhrase"),
        "vo2max": _g(ts, "mostRecentVO2Max", "generic", "vo2MaxPreciseValue"),
    }


def fetch_weights(api, start, end):
    """Wiegungen im Zeitraum als Liste von Dicts (Gewicht in kg)."""
    r = _try(api.get_weigh_ins, start, end) or {}
    out = []
    for day in r.get("dailyWeightSummaries") or []:
        w = day.get("latestWeight") or {}
        if w.get("weight") is None:
            continue
        out.append({
            "date": day.get("summaryDate"),
            "weight_kg": w["weight"] / 1000.0,
            "bmi": w.get("bmi"),
            "body_fat": w.get("bodyFat"),
            "muscle_kg": None if w.get("muscleMass") is None else w["muscleMass"] / 1000.0,
        })
    return out


def fetch_zones(api, activity_id):
    """Zeit in den Garmin-Herzfrequenzzonen (Sekunden) und Zonenuntergrenzen (bpm)."""
    z = _try(api.get_activity_hr_in_timezones, str(activity_id))
    if not z:
        return None
    by = {int(x["zoneNumber"]): x for x in z if x.get("zoneNumber") is not None}
    out = {}
    for i in range(1, 6):
        zi = by.get(i, {})
        out["z%d_s" % i] = zi.get("secsInZone")
        out["z%d_low" % i] = zi.get("zoneLowBoundary")
    return out
