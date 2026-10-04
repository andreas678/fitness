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
  library(here); library(dplyr); library(readr); library(jsonlite)
})
source(here("scripts", "helpers.R"))

RIDE_GAP_MIN <- 30    # wie in garmin_fitness.R
RIDE_MIN_MIN <- 3

daily <- read_csv(here("data", "garmin_daily.csv"), show_col_types = FALSE) |>
  mutate(date = format(as.Date(date)),
         stress_avg = ifelse(stress_avg < 0, NA, stress_avg)) |>   # -1 = kein Wert
  select(date, steps, distance_km, resting_hr, kcal_active, intensity_min, stress_avg,
         bb_high, bb_low, sleep_h, deep_h, light_h, rem_h, awake_h, sleep_score)

acts <- read_csv(here("data", "garmin_activities.csv"), show_col_types = FALSE,
                 col_types = cols(activity_id = col_character(), start = col_datetime(),
                                  name = col_character(), type_key = col_character(),
                                  .default = col_double())) |>
  merge_rides(RIDE_GAP_MIN, RIDE_MIN_MIN) |>
  mutate(start = format(start, "%Y-%m-%d %H:%M", tz = "UTC"),   # Ortszeit, nur falsch als UTC markiert
         group = activity_group(type_key)) |>
  select(start, name, group, type_key, distance_km, duration_min, avg_hr, max_hr,
         kcal, te_aerobic, te_anaerobic)

to_json <- function(x) toJSON(x, dataframe = "rows", na = "null", digits = 3, auto_unbox = TRUE)
payload <- paste0(
  "const DAILY = ", to_json(daily), ";\n",
  "const ACTS = ",  to_json(acts),  ";\n",
  "const META = ", toJSON(list(built = format(Sys.time(), "%d.%m.%Y %H:%M"),
                               ride_gap_min = RIDE_GAP_MIN, ride_min_min = RIDE_MIN_MIN),
                          auto_unbox = TRUE), ";\n")

tpl <- paste(readLines(here("scripts", "dashboard_template.html"), encoding = "UTF-8"),
             collapse = "\n")
parts <- strsplit(tpl, "/*__DATA__*/", fixed = TRUE)[[1]]
stopifnot(length(parts) == 2)
html <- paste0(parts[1], payload, parts[2])

dir.create(here("_outputs"), showWarnings = FALSE)
out <- here("_outputs", "fitness_dashboard.html")
writeLines(html, out, useBytes = TRUE)
message(sprintf("Dashboard geschrieben: %s (%d Tage, %d Aktivitäten, %.0f kB)",
                out, nrow(daily), nrow(acts), file.size(out) / 1024))
