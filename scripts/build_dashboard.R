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
COMMUTE_HRR  <- 0.40  # Annahme für Radfahrten ohne Pulsdaten (Anteil der Herzfrequenzreserve)

daily_raw <- read_csv(here("data", "garmin_daily.csv"), show_col_types = FALSE)

acts_m <- read_csv(here("data", "garmin_activities.csv"), show_col_types = FALSE,
                   col_types = cols(activity_id = col_character(), start = col_datetime(),
                                    name = col_character(), type_key = col_character(),
                                    .default = col_double())) |>
  merge_rides(RIDE_GAP_MIN, RIDE_MIN_MIN) |>
  mutate(group = activity_group(type_key))

# Profil, Belastung, Erholungs-Signale (siehe load_recovery.R)
rhr_ref <- median(daily_raw$resting_hr[daily_raw$resting_hr >= 45], na.rm = TRUE)
prof    <- athlete_profile(rhr_ref)
acts_s  <- session_load(acts_m, prof, COMMUTE_HRR)
dl      <- daily_load_recovery(daily_raw, acts_s)
recov   <- recovery_summary(dl)

daily <- dl |>
  mutate(date = format(date),
         stress_avg = ifelse(stress_avg < 0, NA, stress_avg),     # -1 = kein Wert
         across(c(sig_rhr, sig_sleep, sig_bb, unrecorded, hiit), as.integer),
         across(c(load_meas, load_est, acute_d, chronic_d, acwr, rhr_base, rhr_lo, rhr_hi),
                ~ round(.x, 2))) |>
  select(date, steps, distance_km, resting_hr, kcal_active, intensity_min, stress_avg,
         bb_high, bb_low, sleep_h, deep_h, light_h, rem_h, awake_h, sleep_score,
         hiit, unrecorded, load_meas, load_est, acute_d, chronic_d, acwr,
         rhr_base, rhr_lo, rhr_hi, sig_rhr, sig_sleep, sig_bb, flags)

acts <- acts_s |>
  mutate(start = format(start, "%Y-%m-%d %H:%M", tz = "UTC"),   # Ortszeit, nur falsch als UTC markiert
         trimp = round(trimp, 1), pct_hrmax = round(pct_hrmax)) |>
  select(start, name, group, type_key, distance_km, duration_min, avg_hr, max_hr,
         kcal, te_aerobic, te_anaerobic, zone, trimp, pct_hrmax, est)

hr_sessions <- acts_s |> filter(!is.na(max_hr))
meta <- list(
  built = format(Sys.time(), "%d.%m.%Y %H:%M"),
  ride_gap_min = RIDE_GAP_MIN, ride_min_min = RIDE_MIN_MIN, commute_hrr = COMMUTE_HRR,
  profile = list(age = prof$age, hrmax = prof$hrmax, hrmax_source = prof$hrmax_source,
                 rhr_ref = prof$rhr_ref, zones = prof$zones,
                 n_hr_sessions = nrow(hr_sessions),
                 n_exceed = sum(hr_sessions$max_hr > prof$hrmax)))

to_json <- function(x) toJSON(x, dataframe = "rows", na = "null", digits = 3, auto_unbox = TRUE)
payload <- paste0(
  "const DAILY = ", to_json(daily), ";\n",
  "const ACTS = ",  to_json(acts),  ";\n",
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
message(sprintf("Sessions mit Max-Puls über HFmax: %d von %d (HFmax prüfen!)",
                meta$profile$n_exceed, meta$profile$n_hr_sessions))
message(sprintf("Letzte 14 Tage: %d Tage mit >= 2 Erholungs-Signalen, ACWR aktuell %.2f",
                sum(last$flags >= 2), tail(na.omit(dl$acwr), 1)))
message(sprintf("Dashboard geschrieben: %s (%d Tage, %d Aktivitäten, %.0f kB)",
                out, nrow(daily), nrow(acts), file.size(out) / 1024))
