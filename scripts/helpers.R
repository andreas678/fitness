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
  acts$segment_ids <- acts$activity_id    # Nicht-Rad-Aktivitäten bestehen aus genau einem Segment
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
    # Reihenfolge beachten: summarise() sieht früher erzeugte Spalten. avg_hr muss vor der
    # Überschreibung von duration_min stehen, sonst fehlen die Segment-Gewichte.
    summarise(avg_hr = if (any(!is.na(avg_hr))) weighted.mean(avg_hr, coalesce(duration_min, 0), na.rm = TRUE) else NA_real_,
              segment_ids  = paste(activity_id, collapse = ";"),   # für Zonen-Zuordnung (session_load)
              activity_id  = first(activity_id), start = first(start),
              name = first(name), type_key = first(type_key),
              distance_km  = sum_na(distance_km),
              duration_min = sum(duration_min, na.rm = TRUE),
              max_hr = max_na(max_hr), kcal = sum_na(kcal), elev_gain = sum_na(elev_gain),
              te_aerobic = max_na(te_aerobic), te_anaerobic = max_na(te_anaerobic),
              .groups = "drop") |>
    select(-trip) |>
    filter(duration_min >= min_min)
  bind_rows(acts[!is_ride, ], rides) |> arrange(start)
}

# ---- Tageswerte bereinigen (eine Stelle für R-Plots, Berechnungen und Dashboard) ------------
# Schwellen: Nächte unter MIN_SLEEP_H gelten als "Uhr nicht getragen", Ruhepuls unter MIN_RHR als
# Messartefakt, Tage unter MIN_STEPS ohne Schlafdaten als nicht getragen bzw. nicht synchronisiert.
MIN_SLEEP_H <- 5
MIN_RHR     <- 45
MIN_STEPS   <- 500

# Spalten, die aus der Nacht stammen und bei ungültiger Nacht (sleep_bad) ungültig sind
SLEEP_COLS <- c("sleep_h", "deep_h", "light_h", "rem_h", "awake_h", "sleep_score", "sleep_start",
                "sleep_end", "sleep_hr", "sleep_stress", "awake_count", "restless", "spo2_avg",
                "spo2_low", "resp_sleep", "skin_temp_dev", "bb_sleep_change", "hrv_night")

# Markiert Zeilen, ändert keine Werte:
#   sleep_bad  Schlafdauer vorhanden, aber unter min_sleep_h (fehlender Schlaf ist NICHT "bad")
#   rhr_bad    Ruhepuls vorhanden, aber unter min_rhr
#   partial    Tag unvollständig: heute (Tagessummen laufen noch) oder kaum Schritte ohne
#              Schlafdaten (Uhr nicht getragen / nicht synchronisiert). Solche Tage zählen weder
#              in Mittelwerten noch im ACWR.
flag_daily <- function(daily, min_sleep_h = MIN_SLEEP_H, min_rhr = MIN_RHR, min_steps = MIN_STEPS,
                       today = Sys.Date()) {
  col <- function(nm) if (nm %in% names(daily)) daily[[nm]] else rep(NA_real_, nrow(daily))
  sl <- col("sleep_h"); rhr <- col("resting_hr"); st <- col("steps")
  daily$sleep_bad <- !is.na(sl)  & sl  < min_sleep_h
  # Annotierter Zeitraum mit "kurze Nächte sind echt" (z. B. Nachtwachen): nicht als "Uhr nicht getragen" werten
  if ("ann_short_sleep" %in% names(daily)) daily$sleep_bad <- daily$sleep_bad & !daily$ann_short_sleep
  daily$rhr_bad   <- !is.na(rhr) & rhr < min_rhr
  daily$partial   <- as.Date(daily$date) >= today | (!is.na(st) & st < min_steps & is.na(sl))
  daily
}

# Wie flag_daily, setzt aber ungültige Werte auf NA: Nacht-Spalten bei sleep_bad, Ruhepuls bei
# rhr_bad. extra_cols = weitere Spalten, die an die Nacht gebunden sind (z. B. "bb_high").
# Schritte und andere Tagessummen bleiben unverändert (partial ist nur eine Markierung).
clean_daily <- function(daily, min_sleep_h = MIN_SLEEP_H, min_rhr = MIN_RHR, extra_cols = character(),
                        today = Sys.Date()) {
  d <- flag_daily(daily, min_sleep_h, min_rhr, today = today)
  for (cl in intersect(c(SLEEP_COLS, extra_cols), names(d))) d[[cl]][d$sleep_bad] <- NA
  if ("resting_hr" %in% names(d)) d$resting_hr[d$rhr_bad] <- NA
  d
}

# ---- Annotationen: bekannte Zeiträume beschriften (data/annotations.csv, git-ignoriert) -------------
# Spalten: from, to (JJJJ-MM-TT), note (Text), load_unknown (TRUE = Uhr getragen, aber Trainingslast
# nicht erfasst, z. B. Segeln ohne Aufzeichnung), short_sleep_real (TRUE = kurze Nächte sind echt,
# z. B. Nachtwachen, und gelten nicht als "Uhr nicht getragen"). Hinweis: Garmin erfasst bei geteiltem
# Schlaf nur die Hauptphase, die Schlafdauer ist dann eine Untergrenze.
ANN_COLS <- c("from", "to", "note", "load_unknown", "short_sleep_real")

read_annotations <- function(path = here::here("data", "annotations.csv")) {
  empty <- tibble(from = as.Date(character()), to = as.Date(character()), note = character(),
                  load_unknown = logical(), short_sleep_real = logical())
  if (!file.exists(path)) return(empty)
  raw <- readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = readr::col_character()))
  miss <- setdiff(ANN_COLS, names(raw))
  if (length(miss)) stop("annotations.csv: Spalten fehlen: ", paste(miss, collapse = ", "))
  out <- tibble(from = as.Date(raw$from, optional = TRUE), to = as.Date(raw$to, optional = TRUE),
                note = raw$note,
                load_unknown = toupper(raw$load_unknown) %in% c("TRUE", "T", "JA", "1"),
                short_sleep_real = toupper(raw$short_sleep_real) %in% c("TRUE", "T", "JA", "1"))
  if (anyNA(out$from) || anyNA(out$to)) stop("annotations.csv: unlesbares Datum in von/bis (Format JJJJ-MM-TT)")
  if (any(out$from > out$to)) stop("annotations.csv: 'von' liegt nach 'bis'")
  out
}

# Fügt je Tag ann_note, ann_load_unknown, ann_short_sleep hinzu (Überlappungen: Flags werden verodert)
apply_annotations <- function(daily, ann) {
  daily$ann_note <- NA_character_; daily$ann_load_unknown <- FALSE; daily$ann_short_sleep <- FALSE
  for (i in seq_len(nrow(ann))) {
    hit <- as.Date(daily$date) >= ann$from[i] & as.Date(daily$date) <= ann$to[i]
    daily$ann_note[hit] <- ifelse(is.na(daily$ann_note[hit]), ann$note[i], paste(daily$ann_note[hit], ann$note[i], sep = "; "))
    daily$ann_load_unknown[hit] <- daily$ann_load_unknown[hit] | ann$load_unknown[i]
    daily$ann_short_sleep[hit]  <- daily$ann_short_sleep[hit]  | ann$short_sleep_real[i]
  }
  daily
}
