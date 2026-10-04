# =============================================================================
# helpers.R  –  gemeinsame Funktionen für garmin_fitness.R und build_dashboard.R
# (benötigt dplyr; wird per source() eingebunden)
# =============================================================================

# Aktivitätstyp (Garmin typeKey) -> Gruppe
activity_group <- function(type) {
  type <- tolower(as.character(type))
  case_when(
    grepl("cycling|biking|ride", type)                          ~ "Rad",
    grepl("run|treadmill", type)                                ~ "Laufen",
    grepl("hiit|strength|cardio|fitness|training", type)        ~ "Gym / HIIT",
    grepl("walk|hik", type)                                     ~ "Gehen / Wandern",
    grepl("sail|boat|rowing|paddl|wind|kite|surf", type)        ~ "Segeln / Wasser",
    TRUE                                                        ~ "Sonstiges"
  )
}

# Garmin zerlegt Radpendeln oft in mehrere Mini-Segmente. Segmente derselben Radfahrt
# (gleicher Tag, Abstand <= gap_min) werden zu einer Fahrt zusammengefasst, sehr kurze
# Fahrten verworfen. Nur für die Auswertung; die CSV-Cache-Datei bleibt unverändert.
sum_na <- function(x) if (all(is.na(x))) NA_real_ else sum(x, na.rm = TRUE)
max_na <- function(x) if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)

merge_rides <- function(acts, gap_min = 30, min_min = 3) {
  is_ride <- acts$type_key %in% "cycling"
  rides <- acts[is_ride, ] |>
    arrange(start) |>
    mutate(dur_s   = coalesce(duration_min, 0) * 60,
           end_s   = cummax(as.numeric(start) + dur_s),
           gap_m   = (as.numeric(start) - lag(end_s)) / 60,
           new_trip = is.na(gap_m) | gap_m > gap_min |
                      as.Date(start) != lag(as.Date(start)),
           trip    = cumsum(new_trip)) |>
    group_by(trip) |>
    summarise(activity_id  = first(activity_id), start = first(start),
              name = first(name), type_key = first(type_key),
              distance_km  = sum_na(distance_km),
              duration_min = sum(duration_min, na.rm = TRUE),
              avg_hr = if (any(!is.na(avg_hr))) weighted.mean(avg_hr, duration_min, na.rm = TRUE) else NA_real_,
              max_hr = max_na(max_hr), kcal = sum_na(kcal), elev_gain = sum_na(elev_gain),
              te_aerobic = max_na(te_aerobic), te_anaerobic = max_na(te_anaerobic),
              .groups = "drop") |>
    select(-trip) |>
    filter(duration_min >= min_min)
  bind_rows(acts[!is_ride, ], rides) |> arrange(start)
}
