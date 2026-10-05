#!/usr/bin/env Rscript
# =============================================================================
# build_dashboard.R  –  interaktives HTML-Dashboard aus den Garmin-CSVs erzeugen
# =============================================================================
# Aufruf (aus dem Projektordner "fitness"):
#   Rscript scripts/build_dashboard.R
#
# Liest data/garmin_daily.csv und data/garmin_activities.csv (zuerst
# garmin_fitness.R laufen lassen, um sie zu aktualisieren), fasst Rad-Segmente zu
# Fahrten zusammen und bettet alles in scripts/dashboard_template.html ein.
# Ausgabe: _outputs/fitness_dashboard.html (enthält persönliche Daten, git-ignoriert).
# =============================================================================

for (loc in c("de_DE.UTF-8", "en_US.UTF-8", "C.UTF-8"))
  if (nzchar(suppressWarnings(Sys.setlocale("LC_CTYPE", loc)))) break

suppressPackageStartupMessages({
  library(here); library(dplyr); library(readr); library(jsonlite); library(tibble)
})
source(here("scripts", "helpers.R"))
source(here("scripts", "load_recovery.R"))

RIDE_GAP_MIN <- 30    # wie in garmin_fitness.R
RIDE_MIN_MIN <- 3

ann       <- read_annotations()      # data/annotations.csv: bekannte Zeiträume (Segeln, Nachtwachen ...)
daily_raw <- read_csv(here("data", "garmin_daily.csv"), show_col_types = FALSE) |>
  apply_annotations(ann)
if (nrow(ann) > 0) message(sprintf("Annotationen: %d Zeitraum/Zeiträume, %d Tage beschriftet.", nrow(ann), sum(!is.na(daily_raw$ann_note))))

acts_m <- read_csv(here("data", "garmin_activities.csv"), show_col_types = FALSE,
                   col_types = cols(activity_id = col_character(), start = col_datetime(),
                                    name = col_character(), type_key = col_character(),
                                    .default = col_double())) |>
  merge_rides(RIDE_GAP_MIN, RIDE_MIN_MIN) |>
  mutate(group = activity_group(type_key))

# optionale Zusatzdaten (garmin_fitness.R legt sie an)
read_opt <- function(f, ...) if (file.exists(f)) read_csv(f, show_col_types = FALSE, ...) else NULL
zones_raw  <- read_opt(here("data", "garmin_activity_zones.csv"),
                       col_types = cols(activity_id = col_character(), .default = col_double()))
weight_raw <- read_opt(here("data", "garmin_weight.csv"))

# Profil, Belastung, Erholungs-Signale (siehe load_recovery.R)
rhr_ref <- median(clean_daily(daily_raw)$resting_hr, na.rm = TRUE)   # ohne Ruhepuls-Artefakte
prof    <- athlete_profile(rhr_ref)
# Pendel-Intensität (Radfahrten ohne Puls) aus den gemessenen Fahrten ableiten, sonst Annahme 0,40
commute    <- derive_commute_hrr(acts_m, prof, default = 0.40)
COMMUTE_HRR <- commute$value
acts_s  <- session_load(acts_m, prof, COMMUTE_HRR, zones_raw)
dl      <- daily_load_recovery(daily_raw, acts_s)
recov   <- recovery_summary(dl)

to_clock_h <- function(x, shift_night = FALSE) {      # "2026-10-01 22:44" -> 22.73 (nach Mitternacht +24)
  t <- as.POSIXct(x, tz = "UTC", format = "%Y-%m-%d %H:%M")
  h <- as.numeric(format(t, "%H")) + as.numeric(format(t, "%M")) / 60
  if (shift_night) ifelse(h < 12, h + 24, h) else h
}
if (!"sleep_start" %in% names(dl)) dl$sleep_start <- NA_character_
if (!"sleep_end"   %in% names(dl)) dl$sleep_end   <- NA_character_

daily <- dl |>
  mutate(date = format(date),
         stress_avg = ifelse(stress_avg < 0, NA, stress_avg),     # -1 = kein Wert
         bed_h = round(to_clock_h(sleep_start, TRUE), 2), wake_h = round(to_clock_h(sleep_end), 2),
         across(any_of(c("sig_rhr", "sig_sleep", "sig_bb", "sig_hrv", "unrecorded", "hiit",
                         "sleep_bad", "rhr_bad", "partial", "no_wear", "load_unknown")), as.integer),
         across(c(load_meas, load_est, acute_d, chronic_d, acwr, acwr_meas, rhr_base, rhr_lo, rhr_hi),
                ~ round(.x, 2))) |>
  select(date, steps, distance_km, resting_hr, kcal_active, intensity_min, stress_avg,
         bb_high, bb_low, sleep_h, deep_h, light_h, rem_h, awake_h, sleep_score,
         hiit, unrecorded, no_wear, load_unknown, ann_note, load_meas, load_est, acute_d, chronic_d, acwr, acwr_meas,
         rhr_base, rhr_lo, rhr_hi, sig_rhr, sig_sleep, sig_bb, sig_hrv, flags,
         sleep_bad, rhr_bad, partial,
         any_of(c("bed_h", "wake_h", "sleep_need_min", "sleep_hr", "sleep_stress", "awake_count",
                  "restless", "spo2_avg", "spo2_low", "resp_sleep", "skin_temp_dev", "bb_sleep_change",
                  "hrv_night", "hrv_weekly", "hrv_base_low", "hrv_base_high", "hrv_status",
                  "ready_score", "ready_level", "recovery_h", "ts_acute", "ts_chronic", "ts_acwr",
                  "ts_status", "vo2max")))

acts <- acts_s |>
  mutate(start = format(start, "%Y-%m-%d %H:%M", tz = "UTC"),   # Ortszeit, nur falsch als UTC markiert
         trimp = round(trimp, 1), pct_hrmax = round(pct_hrmax), pct_z45 = round(pct_z45),
         across(c(z1_min, z2_min, z3_min, z4_min, z5_min), ~ round(.x, 1))) |>
  select(start, name, group, type_key, distance_km, duration_min, avg_hr, max_hr,
         kcal, te_aerobic, te_anaerobic, zone, trimp, trimp_src, pct_hrmax, est,
         pct_z45, z1_min, z2_min, z3_min, z4_min, z5_min)

weights <- if (!is.null(weight_raw)) weight_raw |>
  transmute(date = format(date), weight_kg = round(weight_kg, 1)) else tibble(date = character(), weight_kg = numeric())

hr_sessions <- acts_s |> filter(!is.na(max_hr))
meta <- list(
  built = format(Sys.time(), "%d.%m.%Y %H:%M"),
  ride_gap_min = RIDE_GAP_MIN, ride_min_min = RIDE_MIN_MIN, commute_hrr = COMMUTE_HRR,
  commute = list(n = commute$n, lo = commute$lo, hi = commute$hi, source = commute$source),
  min_sleep_h = MIN_SLEEP_H, min_rhr = MIN_RHR,                 # Schwellen aus helpers.R, vom Dashboard mitgenutzt
  sleep_cols = c(SLEEP_COLS, "bed_h", "wake_h"),                # bei ungültiger Nacht ausblendbar
  garmin_zones = if (!is.null(zones_raw) && nrow(zones_raw) > 0)
    list(lows = round(c(median(zones_raw$z1_low, na.rm = TRUE), median(zones_raw$z2_low, na.rm = TRUE),
                        median(zones_raw$z3_low, na.rm = TRUE), median(zones_raw$z4_low, na.rm = TRUE),
                        median(zones_raw$z5_low, na.rm = TRUE))),
         hrmax = round(2 * median(zones_raw$z1_low, na.rm = TRUE)),
         n_sessions = nrow(zones_raw)) else NULL,
  profile = list(age = prof$age, hrmax = prof$hrmax, hrmax_source = prof$hrmax_source,
                 rhr_ref = prof$rhr_ref, zones = prof$zones,
                 n_hr_sessions = nrow(hr_sessions),
                 n_exceed = sum(hr_sessions$max_hr > prof$hrmax)))

to_json <- function(x) toJSON(x, dataframe = "rows", na = "null", digits = 3, auto_unbox = TRUE)
payload <- paste0(
  "const DAILY = ", to_json(daily), ";\n",
  "const ACTS = ",  to_json(acts),  ";\n",
  "const WEIGHT = ", to_json(weights), ";\n",
  "const RECOVERY = ", to_json(mutate(recov, across(where(is.numeric), ~ round(.x, 4)))), ";\n",
  "const META = ", toJSON(meta, auto_unbox = TRUE, dataframe = "rows", na = "null"), ";\n")

tpl <- paste(readLines(here("scripts", "dashboard_template.html"), encoding = "UTF-8"),
             collapse = "\n")
parts <- strsplit(tpl, "/*__DATA__*/", fixed = TRUE)[[1]]
stopifnot(length(parts) == 2)
html <- paste0(parts[1], payload, parts[2])

dir.create(here("_outputs"), showWarnings = FALSE)
out <- here("_outputs", "fitness_dashboard.html")
writeLines(html, out, useBytes = TRUE)
last <- tail(dl, 14)
message(sprintf("Profil: %d Jahre, HFmax %d bpm (%s), Ruhe-HF-Referenz %d bpm", prof$age,
                prof$hrmax, prof$hrmax_source, prof$rhr_ref))
message(sprintf("Pendel-Intensität: HFR %.2f (%s, n = %d gemessene Fahrten%s)", COMMUTE_HRR, commute$source, commute$n,
                if (commute$source == "abgeleitet") sprintf(", Spannweite %.2f–%.2f", commute$lo, commute$hi) else ""))
sens <- trimp_sensitivity(acts_m, prof, COMMUTE_HRR, zones_raw)
message("Sensitivität der Gesamt-TRIMP (jeweils eine Annahme variiert):")
for (i in seq_len(nrow(sens)))
  message(sprintf("  %-10s %6.2f -> TRIMP %5.0f (%2.0f %% geschätzt)", sens$parameter[i], sens$value[i],
                  sens$trimp_total[i], sens$share_est[i] * 100))
message(sprintf("Sessions mit Max-Puls über HFmax: %d von %d (HFmax prüfen!)",
                meta$profile$n_exceed, meta$profile$n_hr_sessions))
message(sprintf("Letzte 14 Tage: %d Tage mit >= 2 Erholungs-Signalen, ACWR aktuell %.2f",
                sum(last$flags >= 2), tail(na.omit(dl$acwr), 1)))
message(sprintf("Dashboard geschrieben: %s (%d Tage, %d Aktivitäten, %.0f kB)",
                out, nrow(daily), nrow(acts), file.size(out) / 1024))
