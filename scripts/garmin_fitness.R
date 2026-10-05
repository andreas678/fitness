#!/usr/bin/env Rscript
# =============================================================================
# garmin_fitness.R  –  Garmin Connect auslesen und lokal cachen
# =============================================================================
# Aufruf (aus dem Projektordner "fitness"):
#   Rscript scripts/garmin_fitness.R            # Daten holen (inkrementell)
#   Rscript scripts/garmin_fitness.R --refresh  # Cache ignorieren, alles neu laden
# Das Dashboard entsteht danach mit: Rscript scripts/build_dashboard.R
#
# Voraussetzungen (einmalig):
#   install.packages(c("here","dplyr","lubridate","readr","reticulate"))
#   ~/.Renviron:  GARMIN_EMAIL="..."   GARMIN_PASSWORD="..."
#   (Das Python-Paket "garminconnect" wird beim ersten Lauf automatisch in einem
#    eigenen virtualenv "r-garmin" installiert; Python 3 muss vorhanden sein.)
#
# Hinweis: Garmin bietet keine offizielle API für Privatnutzer. Das Skript nutzt
# die inoffizielle Python-Bibliothek "garminconnect" über reticulate. Nach dem
# ersten Login werden Tokens in ~/.garminconnect gespeichert, danach ist kein
# Passwort mehr nötig. Bei aktivierter 2-Faktor-Authentifizierung fragt das
# Skript beim ersten Login nach dem Code.
#
# Ausgabe:
#   data/garmin_daily.csv        Tageswerte (Schritte, Ruhepuls, Schlaf, Body Battery …)
#   data/garmin_activities.csv   Einzelne Aktivitäten
#   data/garmin_activity_zones.csv  Zeit in Herzfrequenzzonen je Aktivität (nur mit Pulsdaten)
#   data/garmin_activity_hr.csv  Spitzenpuls je Aktivität (30-Sekunden-Mittel und Einzelwert, aus der Pulskurve)
#   data/garmin_weight.csv       Wiegungen (Gewicht, BMI, falls vorhanden Körperfett)
#   data/weather.csv             Tagestemperaturen (Open-Meteo), siehe weather.R
# =============================================================================

# Rscript startet oft mit Locale "C"; dann werden Umlaute im Skript falsch gelesen.
# LC_CTYPE steuert nur die Zeichenkodierung (Zahlen-/Datumsformat bleiben unberührt).
# Python (reticulate) setzt LC_CTYPE beim Start zurück, daher wird das nach dem
# Garmin-Zugriff nochmals aufgerufen.
set_utf8_locale <- function() {
  for (loc in c("de_DE.UTF-8", "en_US.UTF-8", "C.UTF-8"))
    if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break
  invisible()
}
set_utf8_locale()

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(lubridate)
  library(readr)
})

# ---- 1. Konfiguration --------------------------------------------------------
args      <- commandArgs(trailingOnly = TRUE)
REFRESH   <- "--refresh" %in% args

DAYS_BACK <- 180      # So weit zurück wird geladen und gecacht
TOKEN_DIR <- path.expand("~/.garminconnect")
PY_ENV    <- "r-garmin"   # Name des Python-virtualenv für reticulate

# ---- 2. Hilfsfunktionen ------------------------------------------------------

# Sicherer Zugriff auf verschachtelte Listen (Python-Dicts); NA wenn nicht vorhanden
pick <- function(x, ...) {
  for (k in c(...)) {
    if (!is.list(x) || is.null(x[[k]])) return(NA)
    x <- x[[k]]
  }
  if (is.null(x) || length(x) == 0) NA else x
}
num <- function(x) suppressWarnings(as.numeric(x))

source(here("scripts", "helpers.R"))   # Pfade F_* und read_*_cache(), days_to_fetch(), validate_*(), report_validation()
source(here("scripts", "weather.R"))   # Tagestemperaturen (Open-Meteo)
dir.create(DIR_DATA, showWarnings = FALSE, recursive = TRUE)

# ---- 3. Garmin-Connect-Zugriff -----------------------------------------------

garmin_login <- function() {
  if (!requireNamespace("reticulate", quietly = TRUE))
    stop("Paket 'reticulate' fehlt: install.packages(\"reticulate\")")
  # Eigenes virtualenv, unabhängig vom System-Python. Wird beim ersten Lauf
  # automatisch angelegt und enthält "garminconnect". Muss VOR dem ersten
  # Python-Zugriff passieren (Python startet bei reticulate erst beim Import).
  if (!reticulate::virtualenv_exists(PY_ENV)) {
    message("Lege Python-virtualenv '", PY_ENV, "' mit garminconnect an (einmalig) …")
    reticulate::virtualenv_create(PY_ENV, packages = "garminconnect")
  }
  reticulate::use_virtualenv(PY_ENV, required = TRUE)
  gc <- tryCatch(
    reticulate::import("garminconnect"),
    error = function(e) stop(
      "Import von 'garminconnect' im virtualenv '", PY_ENV, "' fehlgeschlagen.\n",
      "Falls das Paket fehlt: R neu starten und ausführen:\n",
      "  reticulate::virtualenv_install(\"", PY_ENV, "\", \"garminconnect\")\n",
      conditionMessage(e)
    )
  )

  email <- Sys.getenv("GARMIN_EMAIL")
  pw    <- Sys.getenv("GARMIN_PASSWORD")
  has_tokens <- dir.exists(TOKEN_DIR) && length(list.files(TOKEN_DIR)) > 0
  if (!has_tokens && (!nzchar(email) || !nzchar(pw)))
    stop("Keine Zugangsdaten: GARMIN_EMAIL und GARMIN_PASSWORD in ~/.Renviron setzen.")

  ask_mfa <- function() {
    if (interactive()) readline("Garmin MFA-Code: ")
    else readLines(file("stdin"), n = 1)
  }
  api <- gc$Garmin(
    email = if (nzchar(email)) email else NULL,
    password = if (nzchar(pw)) pw else NULL,
    prompt_mfa = ask_mfa
  )
  api$login(TOKEN_DIR)   # nutzt gespeicherte Tokens, sonst Neu-Login + Speichern
  message("Garmin Connect: Login erfolgreich.")
  api
}

# Ein Tag: Tagesstatistik (R) + Schlaf, HRV, Readiness, Trainingsstatus (Python) -> eine Zeile
fetch_day <- function(api, d) {
  d  <- as.character(d)
  st <- tryCatch(api$get_stats(d), error = function(e) NULL)
  ex <- tryCatch(extra_day(api, d), error = function(e) list())
  ev <- function(k) { v <- ex[[k]]; if (is.null(v)) NA else v }
  # Erfolgsmarken: TRUE = Aufruf gelungen (auch wenn Garmin keine Daten hat), FALSE = Aufruf gescheitert.
  # Gescheiterte Tage werden beim nächsten Lauf erneut geholt (days_to_fetch in helpers.R).
  fx <- function(k) isTRUE(as.logical(ev(k)))
  tibble(
    date          = as.Date(d),
    steps         = num(pick(st, "totalSteps")),
    distance_km   = num(pick(st, "totalDistanceMeters")) / 1000,
    resting_hr    = num(pick(st, "restingHeartRate")),
    kcal_active   = num(pick(st, "activeKilocalories")),
    kcal_total    = num(pick(st, "totalKilocalories")),
    # Garmin zählt intensive Minuten doppelt
    intensity_min = num(pick(st, "moderateIntensityMinutes")) +
                    2 * num(pick(st, "vigorousIntensityMinutes")),
    stress_avg    = num(pick(st, "averageStressLevel")),
    bb_high       = num(pick(st, "bodyBatteryHighestValue")),
    bb_low        = num(pick(st, "bodyBatteryLowestValue")),
    sleep_h       = num(ev("sleep_h")),  deep_h  = num(ev("deep_h")),
    light_h       = num(ev("light_h")),  rem_h   = num(ev("rem_h")),
    awake_h       = num(ev("awake_h")),  sleep_score = num(ev("sleep_score")),
    sleep_start   = as.character(ev("sleep_start")), sleep_end = as.character(ev("sleep_end")),
    sleep_need_min = num(ev("sleep_need_min")), sleep_hr = num(ev("sleep_hr")),
    sleep_stress  = num(ev("sleep_stress")), awake_count = num(ev("awake_count")),
    restless      = num(ev("restless")), spo2_avg = num(ev("spo2_avg")), spo2_low = num(ev("spo2_low")),
    resp_sleep    = num(ev("resp_sleep")), skin_temp_dev = num(ev("skin_temp_dev")),
    bb_sleep_change = num(ev("bb_sleep_change")),
    hrv_night     = num(ev("hrv_night")), hrv_weekly = num(ev("hrv_weekly")),
    hrv_5min_high = num(ev("hrv_5min_high")), hrv_base_low = num(ev("hrv_base_low")),
    hrv_base_high = num(ev("hrv_base_high")), hrv_status = as.character(ev("hrv_status")),
    ready_score   = num(ev("ready_score")), ready_level = as.character(ev("ready_level")),
    recovery_h    = num(ev("recovery_h")), ts_acute = num(ev("ts_acute")),
    ts_chronic    = num(ev("ts_chronic")), ts_acwr = num(ev("ts_acwr")),
    ts_status     = as.character(ev("ts_status")), vo2max = num(ev("vo2max")),
    fx_stats = !is.null(st), fx_sleep = fx("fx_sleep"), fx_hrv = fx("fx_hrv"),
    fx_ready = fx("fx_ready"), fx_status = fx("fx_status")
  )
}

# reticulate wandelt Python-Ints in R-Integer um und läuft dabei über (IDs > 2^31).
# Deshalb wird activityId in Python zum String gemacht, bevor die Daten nach R gehen.
# (Caches aus der Zeit davor haben falsche IDs: einmalig mit --refresh neu aufbauen.)
py_fetch_activities <- function(api, start, end) {
  reticulate::py_run_string(paste(
    "def fetch_activities(api, start, end):",
    "    raw = api.get_activities_by_date(start, end)",
    "    for a in raw:",
    "        a['activityId'] = str(a.get('activityId'))",
    "    return raw",
    sep = "\n"))
  reticulate::py$fetch_activities(api, start, end)
}

parse_activity <- function(a) {
  tibble(
    activity_id  = as.character(pick(a, "activityId")),
    start        = ymd_hms(as.character(pick(a, "startTimeLocal")), quiet = TRUE, tz = "UTC"),
    name         = as.character(pick(a, "activityName")),
    type_key     = as.character(pick(a, "activityType", "typeKey")),
    distance_km  = num(pick(a, "distance")) / 1000,
    duration_min = num(pick(a, "duration")) / 60,
    avg_hr       = num(pick(a, "averageHR")),
    max_hr       = num(pick(a, "maxHR")),
    kcal         = num(pick(a, "calories")),
    elev_gain    = num(pick(a, "elevationGain")),
    te_aerobic   = num(pick(a, "aerobicTrainingEffect")),
    te_anaerobic = num(pick(a, "anaerobicTrainingEffect"))
  )
}

# Tageswerte inkrementell nachladen (heute und gestern immer neu, da unvollständig)
update_daily <- function(api) {
  old  <- if (REFRESH) NULL else read_daily_cache()
  # Cache aus der Zeit vor den HRV-/Readiness-Feldern: einmal komplett neu laden
  if (!is.null(old) && !all(c("hrv_night", "ready_score", "sleep_start") %in% names(old))) {
    message("Daily-Cache hat neue Spalten nicht (HRV, Readiness, Schlafzeiten): lade alles neu.")
    old <- NULL
  }
  todo <- days_to_fetch(old, Sys.Date(), DAYS_BACK)   # fehlende, heute/gestern, gescheiterte Teilaufrufe
  n_failed <- if (is.null(old)) 0L else sum(old$date %in% todo & Reduce(`|`, lapply(intersect(FX_COLS, names(old)),
                                                  function(k) !is.na(old[[k]]) & !old[[k]]), FALSE))
  message(sprintf("Tageswerte: %d Tage nachladen (davon %d wegen gescheiterter Aufrufe) …", length(todo), n_failed))

  rows <- vector("list", length(todo))
  for (i in seq_along(todo)) {
    rows[[i]] <- fetch_day(api, todo[i])
    if (i %% 10 == 0) message(sprintf("  %d/%d", i, length(todo)))
    Sys.sleep(0.5)   # Garmin nicht fluten (5 API-Aufrufe je Tag)
  }
  new <- bind_rows(rows)
  out <- bind_rows(if (!is.null(old)) filter(old, !date %in% new$date), new) |>
    arrange(date)
  write_csv(out, F_DAILY)
  out
}

# Aktivitäten: Zeitraum komplett holen, per activity_id mit Cache zusammenführen
update_activities <- function(api) {
  old <- if (REFRESH) NULL else read_act_cache()
  raw <- py_fetch_activities(api, as.character(Sys.Date() - DAYS_BACK),
                             as.character(Sys.Date()))
  new <- if (length(raw) > 0) bind_rows(lapply(raw, parse_activity)) else NULL
  message(sprintf("Aktivitäten: %d im Zeitraum.", if (is.null(new)) 0L else nrow(new)))
  out <- bind_rows(if (!is.null(old) && !is.null(new)) filter(old, !activity_id %in% new$activity_id) else old,
                   new) |>
    arrange(start)
  write_csv(out, F_ACT)
  out
}

# Wiegungen: Zeitraum komplett holen, per Datum mit Cache zusammenführen
update_weight <- function(api) {
  old <- if (REFRESH) NULL else read_weight_cache()
  raw <- fetch_weights(api, as.character(Sys.Date() - DAYS_BACK), as.character(Sys.Date()))
  new <- if (length(raw) > 0)
    bind_rows(lapply(raw, function(w) {
      nz <- function(x) if (is.null(x)) NA_real_ else num(x)   # fehlende Felder = NA
      tibble(date = as.Date(w$date), weight_kg = nz(w$weight_kg), bmi = nz(w$bmi),
             body_fat = nz(w$body_fat), muscle_kg = nz(w$muscle_kg))
    })) else NULL
  message(sprintf("Wiegungen: %d im Zeitraum.", if (is.null(new)) 0L else nrow(new)))
  out <- bind_rows(if (!is.null(old) && !is.null(new)) filter(old, !date %in% new$date) else old, new) |>
    arrange(date)
  write_csv(out, F_WEIGHT)
  out
}

# Zeit in Herzfrequenzzonen: je Aktivität mit Pulsdaten einmal holen und cachen
update_zones <- function(api, acts) {
  old <- if (REFRESH) NULL else read_zones_cache()
  ids <- acts$activity_id[!is.na(acts$avg_hr)]
  todo <- setdiff(ids, if (is.null(old)) character() else old$activity_id)
  message(sprintf("Herzfrequenzzonen: %d Aktivitäten nachladen …", length(todo)))
  rows <- vector("list", length(todo))
  for (i in seq_along(todo)) {
    z <- tryCatch(fetch_zones(api, todo[i]), error = function(e) NULL)
    if (!is.null(z)) rows[[i]] <- as_tibble(c(list(activity_id = todo[i]),
                                              lapply(z, function(v) if (is.null(v)) NA_real_ else num(v))))
    if (i %% 25 == 0) message(sprintf("  %d/%d", i, length(todo)))
    Sys.sleep(0.3)
  }
  out <- bind_rows(old, bind_rows(rows))
  if (!is.null(out) && nrow(out) > 0) write_csv(out, F_ZONES)
  out
}

# Spitzenpuls je Aktivität mit Pulsdaten aus der Pulskurve: einmal holen und cachen (ein Aufruf je Einheit)
update_hr <- function(api, acts) {
  old <- if (REFRESH) NULL else read_hr_cache()
  ids <- acts$activity_id[!is.na(acts$avg_hr)]
  todo <- setdiff(ids, if (is.null(old)) character() else old$activity_id)
  message(sprintf("Spitzenpuls: %d Aktivitäten nachladen …", length(todo)))
  rows <- vector("list", length(todo))
  for (i in seq_along(todo)) {
    r <- tryCatch(fetch_hr_peak(api, todo[i]), error = function(e) NULL)
    if (!is.null(r)) rows[[i]] <- as_tibble(c(list(activity_id = todo[i]),
                                              lapply(r, function(v) if (is.null(v)) NA_real_ else num(v))))
    if (i %% 25 == 0) message(sprintf("  %d/%d", i, length(todo)))
    Sys.sleep(0.3)
  }
  out <- bind_rows(old, bind_rows(rows))
  if (!is.null(out) && nrow(out) > 0) write_csv(out, F_HR)
  out
}

# ---- 4. Daten beschaffen -----------------------------------------------------
api <- tryCatch(garmin_login(), error = function(e) {
  if (is.null(read_daily_cache()) || is.null(read_act_cache())) stop(e)
  warning("Login fehlgeschlagen (", conditionMessage(e), ") – verwende Cache.")
  NULL
})
if (!is.null(api)) {
  reticulate::source_python(here("scripts", "garmin_extra.py"))   # extra_day() u. a.
  daily <- update_daily(api)
  acts  <- update_activities(api)
  invisible(update_weight(api))
  invisible(update_zones(api, acts))
  invisible(update_hr(api, acts))
  invisible(update_weather_env(min(daily$date)))      # Tagestemperaturen für den Wohnort (data/weather.csv)
} else {
  daily <- read_daily_cache(); acts <- read_act_cache()
}

set_utf8_locale()   # nach dem Python-Start: Umlaute in den Meldungen

report_validation(validate_daily(daily), "Tageswerte")
report_validation(validate_acts(acts), "Aktivitäten")
message("Daten aktualisiert in ", DIR_DATA, ". Dashboard bauen: Rscript scripts/build_dashboard.R")
