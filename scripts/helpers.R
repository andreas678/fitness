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

# ---- Cache-Integrität: welche Tage nachladen? -----------------------------------------------------
# Nachgeladen werden: fehlende Tage (kein Schrittwert und kein gelungener Statistik-Aufruf), heute und gestern (unvollständig), Tage mit
# gescheitertem Teilaufruf (fx_* == FALSE) und bei Alt-Caches ohne fx-Spalten junge Tage ohne Schlafdaten.
# "Keine Daten" (Aufruf gelungen, Garmin liefert nichts) wird NICHT erneut geholt.
FX_COLS <- c("fx_stats", "fx_sleep", "fx_hrv", "fx_ready", "fx_status")

days_to_fetch <- function(old, today = Sys.Date(), days_back = 180, legacy_days = 14) {
  want <- seq(today - days_back, today, by = "day")
  if (is.null(old)) return(want)
  fx   <- intersect(FX_COLS, names(old))
  # erledigt: Schrittwert vorhanden oder Statistik-Aufruf gelungen (dann hat Garmin für den Tag nichts, z. B. Uhr nicht getragen)
  stats_ok <- if ("fx_stats" %in% fx) old$fx_stats %in% TRUE else rep(FALSE, nrow(old))
  have <- old$date[!is.na(old$steps) | stats_ok]
  failed <- if (length(fx)) old$date[Reduce(`|`, lapply(fx, function(k) !is.na(old[[k]]) & !old[[k]]))] else as.Date(character())
  legacy_row <- if (length(fx)) Reduce(`&`, lapply(fx, function(k) is.na(old[[k]]))) else rep(TRUE, nrow(old))
  sl <- if ("sleep_h" %in% names(old)) old$sleep_h else rep(NA_real_, nrow(old))
  legacy <- old$date[legacy_row & is.na(sl) & old$date >= today - legacy_days]
  want[!(want %in% have) | want >= today - 1 | want %in% failed | want %in% legacy]
}

# ---- Plausibilitätsprüfung (Warnung, kein Abbruch) --------------------------------------------------
# Rückgabe: Tabelle check / n / example. n = 0: unauffällig.
check_row <- function(check, bad, label) {
  tibble(check = check, n = sum(bad, na.rm = TRUE),
         example = if (any(bad, na.rm = TRUE)) paste(head(label[which(bad)], 3), collapse = ", ") else "")
}

validate_daily <- function(d) {
  col <- function(nm) if (nm %in% names(d)) d[[nm]] else rep(NA_real_, nrow(d))
  dt  <- as.Date(d$date); u <- sort(unique(dt)); gap <- c(FALSE, diff(u) != 1)
  bind_rows(
    tibble(check = "Datumslücken", n = sum(gap), example = if (any(gap)) paste(head(as.character(u[gap]), 3), collapse = ", ") else ""),
    check_row("doppelte Tage", duplicated(dt), as.character(dt)),
    check_row("Schritte < 0", col("steps") < 0, as.character(dt)),
    check_row("Ruhepuls außerhalb 30-100", col("resting_hr") < 30 | col("resting_hr") > 100, as.character(dt)),
    check_row("Schlaf außerhalb 0-16 h", col("sleep_h") < 0 | col("sleep_h") > 16, as.character(dt)))
}

validate_acts <- function(a) {
  col <- function(nm) if (nm %in% names(a)) a[[nm]] else rep(NA_real_, nrow(a))
  id  <- as.character(col("activity_id")); st <- col("start")
  lab <- ifelse(is.na(st), id, format(st, "%Y-%m-%d %H:%M"))
  bind_rows(
    check_row("doppelte activity_id", duplicated(id), id),
    check_row("Start fehlt", is.na(st), id),
    check_row("Dauer <= 0 oder > 24 h", col("duration_min") <= 0 | col("duration_min") > 1440, lab),
    check_row("Puls außerhalb 30-230", col("avg_hr") < 30 | col("avg_hr") > 230 | col("max_hr") < 30 | col("max_hr") > 230, lab),
    check_row("max_hr < avg_hr", col("max_hr") < col("avg_hr"), lab),
    check_row("Strecke < 0", col("distance_km") < 0, lab))
}

report_validation <- function(v, label) {
  bad <- v[v$n > 0, ]
  if (nrow(bad) == 0) { message(sprintf("Plausibilitätsprüfung %s: keine Auffälligkeiten.", label)); return(invisible(v)) }
  for (i in seq_len(nrow(bad)))
    message(sprintf("Plausibilitätsprüfung %s: %s: %d%s", label, bad$check[i], bad$n[i],
                    if (nzchar(bad$example[i])) sprintf(" (z. B. %s)", bad$example[i]) else ""))
  invisible(v)
}

# ---- Feste Referenzwerte (data/profile.json, git-ignoriert) -----------------------------------------
# Ruhepuls-Referenz und Pendel-Puls werden einmal bestimmt und gespeichert, damit sich die Belastung
# historischer Einheiten nicht mit jedem Lauf (gleitendes Datenfenster) verschiebt.
# Neu berechnen: Rscript scripts/build_dashboard.R --recalc-profile
read_ref <- function(path = here::here("data", "profile.json")) {
  if (!file.exists(path)) return(list())
  tryCatch(jsonlite::read_json(path, simplifyVector = TRUE), error = function(e) list())
}
write_ref <- function(ref, path = here::here("data", "profile.json")) {
  jsonlite::write_json(ref, path, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
}

# Reihenfolge: Umgebungsvariable RHR_REF vor gespeichertem Wert vor Neuberechnung.
resolve_rhr_ref <- function(ref, candidate, env = NA_real_, recalc = FALSE) {
  if (is.finite(env) && env > 0) return(list(value = env, source = "RHR_REF (Renviron)", save = FALSE))
  if (!recalc && !is.null(ref$rhr_ref) && is.finite(ref$rhr_ref))
    return(list(value = ref$rhr_ref, source = "gespeichert", save = FALSE))
  list(value = candidate, source = "neu berechnet", save = TRUE)
}

# ---- Gewichtstrend ----------------------------------------------------------------------------------
# Wiegungen sind selten (hier etwa alle 10 Tage) und streuen von Tag zu Tag um 1 kg und mehr
# (Flüssigkeit, Tageszeit). Deshalb kein Einzelwert-Vergleich, sondern ein lokaler Trend (loess,
# Grad 1) mit 95-%-Band für den Verlauf; liefert NULL bei weniger als min_n Wiegungen. Das Band gilt
# für den Trend (Mittelwert), nicht für einzelne Wiegungen. Nur innerhalb des Wiegezeitraums
# (keine Extrapolation); mehrere Wiegungen am selben Tag werden gemittelt.
weight_trend <- function(w, min_n = 8, span = 0.75) {
  w <- w[!is.na(w$weight_kg) & !is.na(w$date), ]
  if (nrow(w) == 0) return(NULL)
  w <- w |> dplyr::group_by(date = as.Date(date)) |> dplyr::summarise(weight_kg = mean(weight_kg), .groups = "drop")
  if (nrow(w) < min_n) return(NULL)
  x <- as.numeric(w$date)
  lo <- stats::loess(weight_kg ~ x, data = data.frame(x = x, weight_kg = w$weight_kg), degree = 1,
                     span = min(1, max(span, 6 / nrow(w))), family = "gaussian")
  grid <- seq(min(w$date), max(w$date), by = "day")
  pr <- stats::predict(lo, data.frame(x = as.numeric(grid)), se = TRUE)
  tc <- stats::qt(0.975, pr$df)
  tibble::tibble(date = grid, fit = as.numeric(pr$fit),
                 lo = as.numeric(pr$fit - tc * pr$se.fit), hi = as.numeric(pr$fit + tc * pr$se.fit))
}

# ---- Anpassungs-Trends: Wochentrend von Ruhepuls, HRV und Puls im Schlaf -----------------------------
# Tageswerte streuen stark (Schlaf, Stress, Wärme, Krankheit). Deshalb Wochenmittel (Montag-Wochen) und eine
# lineare Steigung über die letzten `weeks` vollständigen Wochen mit 95-%-Konfidenzintervall (t-Verteilung).
# Eine Woche zählt nur mit mindestens `min_days` gültigen Tagen und höchstens `max_ann_share` annotierter
# Tage (z. B. Segeltörn); unvollständige Tage und Artefakte (clean_daily) zählen nicht. Unter `min_weeks`
# Wochen gibt es keine Steigung. HRV wird logarithmisch gefittet (multiplikative Schwankung), die Steigung
# steht dann in Prozent je Woche, die Wochenwerte sind in ms zurückgerechnet (geometrisches Mittel).
# Näherung: Die Wochenmittel sind schwächer autokorreliert als Tageswerte, bei etwa 12 Punkten ist das
# Intervall dennoch nur ungefähr; es beschreibt einen Zusammenhang, keine Ursache (Training wirkt hier nicht
# von Schlaf, Stress und Krankheit getrennt).
TREND_METRICS <- tibble::tibble(col = c("resting_hr", "hrv_night", "sleep_hr"),
                                log = c(FALSE, TRUE, FALSE),
                                unit = c("bpm/Woche", "%/Woche", "bpm/Woche"))

adaptation_trends <- function(daily, weeks = 12, min_days = 4, min_weeks = 6, max_ann_share = 0.5,
                              today = Sys.Date()) {
  empty <- list(
    weekly = tibble::tibble(metric = character(), week = as.Date(character()), value = numeric(),
                            n_days = integer(), fit = numeric()),
    trend = tibble::tibble(metric = character(), slope_unit = character(), slope = numeric(), lo = numeric(),
                           hi = numeric(), n_weeks = integer(), verdict = character()),
    window = list(first_week = as.Date(NA), last_week = as.Date(NA)))
  if (nrow(daily) == 0) return(empty)
  d <- clean_daily(daily, today = today)
  d$date <- as.Date(d$date)
  if (all(d$partial)) return(empty)
  last_day <- max(d$date[!d$partial])
  d$week <- d$date - (as.integer(format(d$date, "%u")) - 1)             # Montag der Woche
  full <- d$week[d$week + 6 <= last_day]
  if (length(full) == 0) return(empty)
  last_wk <- max(full); first_wk <- last_wk - 7 * (weeks - 1)
  d$ann <- if ("ann_note" %in% names(d)) !is.na(d$ann_note) else FALSE
  d <- d[d$week >= first_wk & d$week <= last_wk, ]
  weekly <- list(); trend <- list()
  for (i in seq_len(nrow(TREND_METRICS))) {
    m <- TREND_METRICS$col[i]
    if (!m %in% names(d)) next
    v <- d[[m]]; v[d$partial] <- NA
    if (TREND_METRICS$log[i]) v <- ifelse(!is.na(v) & v > 0, log(v), NA_real_)
    wk <- d |> dplyr::mutate(v = v) |> dplyr::group_by(week) |>
      dplyr::summarise(n = sum(!is.na(v)), m = mean(v, na.rm = TRUE), ann = sum(ann) / 7, .groups = "drop") |>
      dplyr::filter(n >= min_days, ann < max_ann_share)
    bk <- if (TREND_METRICS$log[i]) exp else identity
    row <- list(metric = m, slope_unit = TREND_METRICS$unit[i], slope = NA_real_, lo = NA_real_, hi = NA_real_,
                n_weeks = nrow(wk), verdict = "zu wenig Daten")
    fit <- rep(NA_real_, nrow(wk))
    if (nrow(wk) >= min_weeks) {
      x <- as.numeric(wk$week - first_wk) / 7
      f <- stats::lm(wk$m ~ x); ci <- stats::confint(f)["x", ]; b <- unname(coef(f)["x"])
      tf <- if (TREND_METRICS$log[i]) function(z) 100 * (exp(z) - 1) else identity
      row[c("slope", "lo", "hi")] <- list(tf(b), tf(unname(ci[1])), tf(unname(ci[2])))
      row$verdict <- if (ci[1] > 0) "steigend" else if (ci[2] < 0) "fallend" else "kein klarer Trend"
      fit <- bk(unname(stats::fitted(f)))
    }
    trend[[m]] <- tibble::as_tibble(row)
    weekly[[m]] <- tibble::tibble(metric = m, week = wk$week, value = bk(wk$m), n_days = as.integer(wk$n), fit = fit)
  }
  if (length(trend) == 0) return(empty)
  list(weekly = dplyr::bind_rows(weekly), trend = dplyr::bind_rows(trend),
       window = list(first_week = first_wk, last_week = last_wk))
}
