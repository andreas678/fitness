#!/usr/bin/env Rscript
# =============================================================================
# garmin_fitness.R  –  Garmin Connect auslesen und grafisch aufbereiten
# =============================================================================
# Aufruf (aus dem Projektordner "fitness"):
#   Rscript scripts/garmin_fitness.R            # Daten holen (inkrementell) + Grafiken
#   Rscript scripts/garmin_fitness.R --refresh  # Cache ignorieren, alles neu laden
#   Rscript scripts/garmin_fitness.R --demo     # Testlauf mit synthetischen Daten
#
# Voraussetzungen (einmalig):
#   install.packages(c("here","dplyr","tidyr","ggplot2","lubridate","readr",
#                      "scales","reticulate","patchwork","ragg"))
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
#   _outputs/*.png               Einzelgrafiken + fitness_dashboard.png
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
  library(tidyr)
  library(ggplot2)
  library(lubridate)
  library(readr)
  library(scales)
})

# ---- 1. Konfiguration --------------------------------------------------------
args      <- commandArgs(trailingOnly = TRUE)
DEMO      <- "--demo" %in% args
REFRESH   <- "--refresh" %in% args

DAYS_BACK <- 180      # So weit zurück wird geladen und gecacht
PLOT_DAYS <- 90       # So weit zurück zeigen die Grafiken
STEP_GOAL <- 10000    # Schrittziel (gestrichelte Linie)
RIDE_GAP_MIN <- 30    # Rad-Segmente mit kleinerem Abstand gelten als eine Fahrt
RIDE_MIN_MIN <- 3     # Fahrten unter dieser Dauer (min) werden verworfen
TOKEN_DIR <- path.expand("~/.garminconnect")
PY_ENV    <- "r-garmin"   # Name des Python-virtualenv für reticulate

DIR_DATA <- here("data")
DIR_OUT  <- here("_outputs")
dir.create(DIR_DATA, showWarnings = FALSE, recursive = TRUE)
dir.create(DIR_OUT,  showWarnings = FALSE, recursive = TRUE)

F_DAILY <- file.path(DIR_DATA, "garmin_daily.csv")
F_ACT   <- file.path(DIR_DATA, "garmin_activities.csv")
F_WEIGHT <- file.path(DIR_DATA, "garmin_weight.csv")
F_ZONES  <- file.path(DIR_DATA, "garmin_activity_zones.csv")
F_HR     <- file.path(DIR_DATA, "garmin_activity_hr.csv")
PREFIX  <- if (DEMO) "demo_" else ""

GROUP_COLORS <- c(
  "Rad"             = "#0072B2",
  "Laufen"          = "#D55E00",
  "Gym / HIIT"      = "#CC79A7",
  "Gehen / Wandern" = "#009E73",
  "Segeln / Wasser" = "#56B4E9",
  "Sonstiges"       = "#999999"
)

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

# Gleitender Mittelwert über die letzten k Tage (mind. 3 Werte, sonst NA)
roll_mean <- function(x, k = 7) {
  vapply(seq_along(x), function(i) {
    w <- x[max(1, i - k + 1):i]
    if (sum(!is.na(w)) >= 3) mean(w, na.rm = TRUE) else NA_real_
  }, numeric(1))
}

source(here("scripts", "helpers.R"))   # activity_group(), merge_rides()

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

read_daily_cache <- function() {
  if (!file.exists(F_DAILY)) return(NULL)
  # Textspalten fest typisieren: read_csv würde "2026-10-01 22:44" sonst als Datum/Zeit lesen
  read_csv(F_DAILY, show_col_types = FALSE,
           col_types = cols(.default = col_guess(), sleep_start = col_character(),
                            sleep_end = col_character(), hrv_status = col_character(),
                            ready_level = col_character(), ts_status = col_character())) |>
    mutate(date = as.Date(date))
}
read_act_cache <- function() {
  if (!file.exists(F_ACT)) return(NULL)
  read_csv(F_ACT, show_col_types = FALSE,
           col_types = cols(activity_id = col_character(),
                            start = col_datetime(), name = col_character(),
                            type_key = col_character(), .default = col_double()))
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
  old <- if (!REFRESH && file.exists(F_WEIGHT)) read_csv(F_WEIGHT, show_col_types = FALSE) else NULL
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
  old <- if (!REFRESH && file.exists(F_ZONES))
    read_csv(F_ZONES, show_col_types = FALSE, col_types = cols(activity_id = col_character(), .default = col_double())) else NULL
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
  old <- if (!REFRESH && file.exists(F_HR))
    read_csv(F_HR, show_col_types = FALSE, col_types = cols(activity_id = col_character(), .default = col_double())) else NULL
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

# ---- 4. Demo-Daten (nur --demo) ----------------------------------------------
demo_data <- function() {
  set.seed(42)
  d <- seq(Sys.Date() - DAYS_BACK, Sys.Date(), by = "day")
  n <- length(d)
  workday <- !wday(d, week_start = 1) %in% c(6, 7)
  sleep <- pmax(5, rnorm(n, 7.1, 0.7))
  deep  <- sleep * runif(n, .14, .22); rem <- sleep * runif(n, .18, .25)
  awake <- runif(n, .2, .6);           light <- sleep - deep - rem
  daily <- tibble(
    date = d,
    steps = round(pmax(2000, rnorm(n, ifelse(workday, 9500, 7000), 2500))),
    distance_km = steps * 0.00075,
    resting_hr = round(54 - seq(0, 3, length.out = n) + rnorm(n, 0, 1.5)),
    kcal_active = round(rnorm(n, 650, 180)), kcal_total = kcal_active + 1900,
    intensity_min = round(pmax(0, rnorm(n, 60, 35))),
    stress_avg = round(pmax(10, rnorm(n, 28, 7))),
    bb_high = round(pmin(100, rnorm(n, 88, 6))), bb_low = round(pmax(5, rnorm(n, 22, 8))),
    sleep_h = sleep, deep_h = deep, light_h = light, rem_h = rem, awake_h = awake,
    sleep_score = round(pmin(100, pmax(40, rnorm(n, 78, 8))))
  )
  rides <- tibble(day = d[workday], type_key = "cycling") |>
    mutate(distance_km = rnorm(n(), 14, 1.5), duration_min = distance_km / 20 * 60,
           avg_hr = rnorm(n(), 128, 6), name = "Radpendeln")
  hiit <- tibble(day = d[wday(d, week_start = 1) %in% c(2, 4)], type_key = "hiit") |>
    mutate(distance_km = NA_real_, duration_min = rnorm(n(), 55, 4),
           avg_hr = rnorm(n(), 148, 7), name = "Functional HIIT")
  acts <- bind_rows(rides, hiit) |>
    mutate(activity_id = as.character(seq_len(n())),
           start = as.POSIXct(paste(day, "07:30:00"), tz = "UTC"),
           max_hr = avg_hr + 25, kcal = duration_min * 9, elev_gain = NA_real_,
           te_aerobic = NA_real_, te_anaerobic = NA_real_) |>
    select(-day) |> arrange(start)
  list(daily = daily, acts = acts)
}

# ---- 5. Daten beschaffen -----------------------------------------------------
if (DEMO) {
  message("DEMO-Modus: synthetische Daten, es wird nichts von Garmin geladen oder gecacht.")
  dd <- demo_data(); daily <- dd$daily; acts <- dd$acts
} else {
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
  } else {
    daily <- read_daily_cache(); acts <- read_act_cache()
  }
}

set_utf8_locale()   # nach dem Python-Start, vor dem Plot-Code

if (!DEMO) { report_validation(validate_daily(daily), "Tageswerte"); report_validation(validate_acts(acts), "Aktivitäten") }

since <- Sys.Date() - PLOT_DAYS
# clean_daily() (helpers.R): ungültige Nächte und Ruhepuls-Artefakte werden NA, unvollständige Tage
# bekommen partial = TRUE und zählen nicht in Mittelwerten (wie im Dashboard)
daily <- daily |> filter(date >= since) |> arrange(date) |> clean_daily() |>
  mutate(steps_c = ifelse(partial, NA_real_, steps),
         steps_7d = roll_mean(steps_c), rhr_7d = roll_mean(resting_hr),
         sleep_7d = roll_mean(sleep_h))
acts <- merge_rides(acts, RIDE_GAP_MIN, RIDE_MIN_MIN) |>
  filter(as.Date(start) >= since) |>
  mutate(group = factor(activity_group(type_key), levels = names(GROUP_COLORS)))

# ---- 6. Grafiken -------------------------------------------------------------
theme_set(
  theme_minimal(base_size = 11) +
    theme(plot.title = element_text(face = "bold"),
          plot.title.position = "plot",
          panel.grid.minor = element_blank(),
          legend.position = "bottom")
)
x_date <- scale_x_date(date_labels = "%d.%m.", expand = expansion(mult = 0.01))
de_num <- label_number(big.mark = ".", decimal.mark = ",")
has    <- function(df, col) nrow(df) > 0 && any(!is.na(df[[col]]))

plots <- list()

# 6.1 Schritte
if (has(daily, "steps")) {
  plots$schritte <- ggplot(daily, aes(date, steps)) +
    geom_col(aes(alpha = partial), fill = "#A6C8E0") +
    scale_alpha_manual(values = c(`FALSE` = 1, `TRUE` = 0.35), guide = "none") +
    geom_line(aes(y = steps_7d), colour = "#0072B2", linewidth = 1, na.rm = TRUE) +
    geom_hline(yintercept = STEP_GOAL, linetype = "dashed", colour = "grey40") +
    x_date + scale_y_continuous(labels = de_num) +
    labs(title = "Schritte pro Tag", subtitle = "Linie: 7-Tage-Mittel, gestrichelt: Ziel, blass: unvollständiger Tag",
         x = NULL, y = NULL)
}

# 6.2 Ruhepuls
if (has(daily, "resting_hr")) {
  plots$ruhepuls <- ggplot(daily, aes(date, resting_hr)) +
    geom_point(colour = "#E69F00", alpha = 0.6, na.rm = TRUE) +
    geom_line(aes(y = rhr_7d), colour = "#D55E00", linewidth = 1, na.rm = TRUE) +
    x_date +
    labs(title = "Ruhepuls", subtitle = "Linie: 7-Tage-Mittel", x = NULL, y = "bpm")
}

# 6.3 Schlafphasen
sleep_long <- daily |>
  filter(!is.na(sleep_h), sleep_h > 0) |>
  select(date, Tief = deep_h, Leicht = light_h, REM = rem_h, Wach = awake_h) |>
  pivot_longer(-date, names_to = "phase", values_to = "h") |>
  mutate(phase = factor(phase, levels = c("Wach", "REM", "Leicht", "Tief")))
if (nrow(sleep_long) > 0) {
  plots$schlaf <- ggplot(sleep_long, aes(date, h, fill = phase)) +
    geom_col(width = 0.9, na.rm = TRUE) +
    scale_fill_manual(values = c(Tief = "#1F4E79", Leicht = "#6BAED6",
                                 REM = "#9E7BB5", Wach = "#E69F00"),
                      breaks = c("Tief", "Leicht", "REM", "Wach"), name = NULL) +
    x_date + labs(title = "Schlaf", subtitle = "Stunden pro Nacht nach Phase", x = NULL, y = "h")
}

# 6.4 Wochenumfang nach Aktivitätsgruppe
weekly <- acts |>
  filter(!is.na(duration_min)) |>
  mutate(week = floor_date(as.Date(start), "week", week_start = 1)) |>
  group_by(week, group) |>
  summarise(hours = sum(duration_min) / 60, km = sum(distance_km, na.rm = TRUE),
            .groups = "drop") |>
  mutate(partial = week < since | week + 6 > Sys.Date())   # angeschnittene oder laufende Woche
if (nrow(weekly) > 0) {
  plots$wochenumfang <- ggplot(weekly, aes(week, hours, fill = group, alpha = partial)) +
    geom_col(width = 6) +
    scale_alpha_manual(values = c(`FALSE` = 1, `TRUE` = 0.45), guide = "none") +
    scale_fill_manual(values = GROUP_COLORS, name = NULL, drop = TRUE) +
    scale_x_date(date_labels = "KW %V", expand = expansion(mult = 0.02)) +
    labs(title = "Trainingsumfang pro Woche", subtitle = "Stunden nach Aktivitätstyp, blass: unvollständige Woche",
         x = NULL, y = "h")
}

# 6.5 Radpendeln: Wochenkilometer
ride_week <- filter(weekly, group == "Rad", km > 0)
if (nrow(ride_week) > 0) {
  plots$rad <- ggplot(ride_week, aes(week, km, alpha = partial)) +
    geom_col(width = 6, fill = GROUP_COLORS[["Rad"]]) +
    scale_alpha_manual(values = c(`FALSE` = 1, `TRUE` = 0.45), guide = "none") +
    scale_x_date(date_labels = "KW %V", expand = expansion(mult = 0.02)) +
    labs(title = "Rad: Kilometer pro Woche", subtitle = "blass: unvollständige Woche", x = NULL, y = "km")
}

# 6.6 Durchschnittspuls je Aktivität
act_hr <- filter(acts, !is.na(avg_hr), !is.na(start))
if (nrow(act_hr) > 0) {
  p <- ggplot(act_hr, aes(as.Date(start), avg_hr)) +
    geom_point(aes(colour = group, size = duration_min), alpha = 0.7) +
    scale_colour_manual(values = GROUP_COLORS, name = NULL, drop = TRUE) +
    scale_size_continuous(range = c(1.5, 5), name = "Dauer (min)") +
    x_date +
    labs(title = "Durchschnittspuls je Aktivität", x = NULL, y = "bpm")
  # Trend je Aktivitätsgruppe statt über alle Typen: ein gemeinsamer Trend mischt Gruppen mit sehr
  # verschiedenem Puls (Zusammensetzungseffekt). Nur Gruppen mit mindestens 8 Einheiten; "Sonstiges"
  # ist ein Sammelbecken (Atemübungen, Mobility, Seilspringen ...) und bekommt keine Linie.
  trend_groups <- act_hr |> filter(group != "Sonstiges") |> count(group) |> filter(n >= 8) |> pull(group)
  if (length(trend_groups) > 0) {
    p <- p + geom_smooth(data = filter(act_hr, group %in% trend_groups), aes(colour = group, group = group),
                         method = "loess", formula = y ~ x, se = FALSE, linewidth = 0.8, na.rm = TRUE)
    p <- p + labs(subtitle = "Linien: Trend je Aktivitätsgruppe (ab 8 Einheiten, ohne \"Sonstiges\")")
  }
  plots$aktivitaeten_puls <- p
}

# 6.7 Body Battery
if (has(daily, "bb_high")) {
  plots$body_battery <- ggplot(daily, aes(date)) +
    geom_ribbon(aes(ymin = bb_low, ymax = bb_high), fill = "#009E73", alpha = 0.35, na.rm = TRUE) +
    geom_line(aes(y = bb_high), colour = "#009E73", na.rm = TRUE) +
    geom_line(aes(y = bb_low),  colour = "#006B4F", na.rm = TRUE) +
    x_date + coord_cartesian(ylim = c(0, 100)) +
    labs(title = "Body Battery", subtitle = "Tageshöchst- und -tiefstwert", x = NULL, y = NULL)
}

# ---- 7. Speichern ------------------------------------------------------------
# ragg rendert Umlaute und Sonderzeichen auch ohne UTF-8-Locale (Rscript: "C") korrekt
png_dev <- if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else NULL
if (is.null(png_dev)) message("Hinweis: Für korrekte Umlaute install.packages(\"ragg\").")
for (nm in names(plots)) {
  f <- file.path(DIR_OUT, paste0(PREFIX, nm, ".png"))
  ggsave(f, plots[[nm]], width = 9, height = 4.5, dpi = 150, bg = "white", device = png_dev)
}
if (length(plots) >= 2 && requireNamespace("patchwork", quietly = TRUE)) {
  dash <- patchwork::wrap_plots(plots, ncol = 2) +
    patchwork::plot_annotation(
      title = sprintf("Fitness-Dashboard – letzte %d Tage (Stand %s)",
                      PLOT_DAYS, format(Sys.Date(), "%d.%m.%Y")),
      theme = theme(plot.title = element_text(face = "bold", size = 16)))
  ggsave(file.path(DIR_OUT, paste0(PREFIX, "fitness_dashboard.png")), dash,
         width = 14, height = 3.6 * ceiling(length(plots) / 2), dpi = 130, bg = "white",
         device = png_dev)
} else if (length(plots) >= 2) {
  message("Hinweis: Für das Gesamt-Dashboard install.packages(\"patchwork\").")
}

# ---- 8. Kurz-Zusammenfassung (letzte 30 Tage) --------------------------------
last30 <- filter(daily, date > Sys.Date() - 30, !partial)   # ohne unvollständige Tage
a30    <- filter(acts, as.Date(start) > Sys.Date() - 30)
cat(sprintf("\n=== Letzte 30 Tage (%d Tage, %d unvollständige nicht mitgerechnet) ===\n",
            nrow(last30), sum(daily$partial & daily$date > Sys.Date() - 30)))
cat(sprintf("Schritte (Ø/Tag):   %s\n", format(round(mean(last30$steps, na.rm = TRUE)), big.mark = ".", decimal.mark = ",")))
cat(sprintf("Ruhepuls (Ø):       %.1f bpm\n", mean(last30$resting_hr, na.rm = TRUE)))
cat(sprintf("Schlaf (Ø):         %.1f h\n", mean(last30$sleep_h, na.rm = TRUE)))
cat(sprintf("Aktivitäten:        %d (%.1f h)\n", nrow(a30), sum(a30$duration_min, na.rm = TRUE) / 60))
cat(sprintf("Rad:                %.0f km\n", sum(a30$distance_km[a30$group == "Rad"], na.rm = TRUE)))
cat(sprintf("\nGrafiken: %s\n", DIR_OUT))
