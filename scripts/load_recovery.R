# =============================================================================
# load_recovery.R  –  Athletenprofil, Einheiten-Belastung (TRIMP) und Erholungs-Signale
# (benötigt dplyr, tibble; setzt helpers.R voraus; wird per source() eingebunden)
# =============================================================================
# Benötigte Variablen in ~/.Renviron:
#   BIRTHDAY="26-07-1974"   (TT-MM-JJJJ; Beispielwert, nicht echt)      GENDER="male"|"female"
# Optional:
#   HRMAX="190"   dein HFmax-Wert (am besten per Feldtest oder mit Brustgurt ermittelt); ohne
#                 Angabe wird er nach Tanaka geschätzt (208 - 0.7 * Alter, Streuung etwa +-10 bpm).
#                 Das Dashboard prüft ihn gegen die 30-Sekunden-Spitzenwerte der Einheiten.
# Die Werte werden nur zur Berechnung genutzt; das Geburtsdatum wird nicht ausgegeben.
# =============================================================================

# ---- Profil, Zonen ---------------------------------------------------------------
# Tanaka-Schätzung der HFmax aus dem Alter (Streuung etwa +-10 bpm)
tanaka_hrmax <- function(age) round(208 - 0.7 * age)
# Herzfrequenzreserve-Anteil (HF - HFruhe) / (HFmax - HFruhe) aus dem Profil `p` (rhr_ref, hrmax);
# clip = TRUE begrenzt auf 0 bis 1 (Standard), clip = FALSE lässt Werte außerhalb stehen (für die Zonenzuordnung).
hrr_frac <- function(hr, p, clip = TRUE) {
  f <- (hr - p$rhr_ref) / (p$hrmax - p$rhr_ref)
  if (clip) pmin(pmax(f, 0), 1) else f
}
# Untergrenzen der Zonen Z1-Z5 als Anteil der Herzfrequenzreserve (Karvonen); Z5 reicht bis 100 %
ZONE_EDGES <- c(.5, .6, .7, .8, .9)

athlete_profile <- function(rhr_ref, today = Sys.Date()) {
  bd <- suppressWarnings(as.Date(Sys.getenv("BIRTHDAY"),
                                 tryFormats = c("%d-%m-%Y", "%Y-%m-%d", "%d.%m.%Y")))
  age <- if (is.na(bd)) NA_real_ else floor(as.numeric(today - bd) / 365.2425)
  hr_env <- suppressWarnings(as.numeric(Sys.getenv("HRMAX")))
  if (is.finite(hr_env) && hr_env > 0) {
    hrmax <- hr_env; src <- "eingestellt via HRMAX"   # nicht automatisch "gemessen": Wert stammt aus der Konfiguration
  } else if (!is.na(age)) {
    hrmax <- tanaka_hrmax(age); src <- "geschätzt (Tanaka)"
  } else stop("BIRTHDAY (TT-MM-JJJJ) oder HRMAX in ~/.Renviron setzen.")
  male <- !tolower(Sys.getenv("GENDER")) %in% c("female", "f", "w", "weiblich")
  hrr  <- hrmax - rhr_ref
  # Plausibilitätsgrenze für Pulsspitzen: Tanaka-Schätzung + 30 bpm (etwa 3 Streuungen der individuellen
  # HFmax). Ein 30-Sekunden-Mittel darüber gilt als Artefakt (z. B. optischer Sensor rastet auf die Bewegung ein).
  hr_ceiling <- if (is.na(age)) NA_real_ else tanaka_hrmax(age) + 30
  list(age = age, male = male, hrmax = hrmax, hrmax_source = src, hr_ceiling = hr_ceiling, rhr_ref = rhr_ref,
       trimp_b = if (male) 1.92 else 1.67,                   # Banister-TRIMP-Faktor
       zones = tibble(zone = paste0("Z", 1:5),
                      lo = round(rhr_ref + hrr * ZONE_EDGES),
                      hi = round(rhr_ref + hrr * c(ZONE_EDGES[-1], 1))))
}

# ---- Spitzenpuls prüfen: HFmax gegen die 30-Sekunden-Spitzen der Einheiten ---------------------------
# acts: Aktivitäten mit max_hr; hr: Cache garmin_activity_hr.csv (activity_id, hr_peak30, hr_max_raw) oder NULL.
#   n_exceed_raw  Einheiten, deren Einzelwert-Maximum über HFmax liegt (anfällig für Sensor-Ausreißer)
#   n_exceed      Einheiten mit 30-s-Spitze über HFmax, aber unter der Plausibilitätsgrenze
#   n_artifact    Einheiten mit 30-s-Spitze über der Plausibilitätsgrenze (vermutlich Artefakt)
#   obs_max       höchste 30-s-Spitze ohne Artefakte: HFmax kann nicht darunter liegen
#   low           obs_max liegt mehr als tol bpm über HFmax (tol = übliche Messgenauigkeit des Handgelenk-Sensors)
hr_peak_stats <- function(acts, hr, p, tol = 3) {
  ceil <- if (is.null(p$hr_ceiling) || is.na(p$hr_ceiling)) Inf else p$hr_ceiling
  with_hr <- acts[!is.na(acts$max_hr), ]
  out <- list(n_hr = nrow(with_hr), n_exceed_raw = sum(with_hr$max_hr > p$hrmax), n_peak = 0L,
              n_exceed = NA_integer_, n_artifact = NA_integer_, obs_max = NA_real_, low = FALSE, ceiling = p$hr_ceiling)
  if (is.null(hr) || nrow(hr) == 0) return(out)
  pk <- hr$hr_peak30[hr$activity_id %in% with_hr$activity_id]; pk <- pk[!is.na(pk)]
  out$n_peak     <- length(pk)
  out$n_exceed   <- sum(pk > p$hrmax & pk <= ceil)
  out$n_artifact <- sum(pk > ceil)
  out$obs_max    <- if (any(pk <= ceil)) max(pk[pk <= ceil]) else NA_real_
  out$low        <- !is.na(out$obs_max) && out$obs_max > p$hrmax + tol
  out
}

# ---- Belastung je Einheit ----------------------------------------------------------
# Banister-TRIMP = Dauer(min) * HRR * 0.64 * exp(b * HRR), HRR = (HF - HFruhe)/(HFmax - HFruhe).
# Mit Zeit-in-Zonen (garmin_activity_zones.csv, Garmin-Zonen) wird je Zone mit der Zonenmitte
# gerechnet, das bildet Intervalle richtig ab. Ohne Zonendaten zählt nur der Durchschnittspuls.
# Radfahrten ohne Pulsdaten (Pendeln) bekommen eine ANNAHME (commute_hrr) und sind als
# "geschätzt" markiert.
banister <- function(minutes, hrr, b) minutes * hrr * 0.64 * exp(b * hrr)

# Garmin-Zonen (% der in Garmin eingestellten HFmax; Untergrenze Z1 = 50 %)
zone_trimp <- function(zones, p) {
  if (is.null(zones) || nrow(zones) == 0) return(NULL)
  hrmax_g <- 2 * zones$z1_low                                    # Garmin-HFmax aus Z1-Untergrenze
  mids <- cbind((zones$z1_low + zones$z2_low) / 2, (zones$z2_low + zones$z3_low) / 2,
                (zones$z3_low + zones$z4_low) / 2, (zones$z4_low + zones$z5_low) / 2,
                (zones$z5_low + hrmax_g) / 2)
  hrr  <- hrr_frac(mids, p)
  secs <- as.matrix(zones[paste0("z", 1:5, "_s")]); secs[is.na(secs)] <- 0
  tibble(activity_id = zones$activity_id,
         trimp_z = rowSums(banister(secs / 60, hrr, p$trimp_b)),
         z_min   = rowSums(secs) / 60,
         pct_z45 = ifelse(rowSums(secs) > 0, (secs[, 4] + secs[, 5]) / rowSums(secs) * 100, NA_real_),
         z1_min = secs[, 1] / 60, z2_min = secs[, 2] / 60, z3_min = secs[, 3] / 60,
         z4_min = secs[, 4] / 60, z5_min = secs[, 5] / 60)
}

# Zonen-Kennwerte je Aktivität: gemergte Fahrten (segment_ids "id1;id2") summieren die Zonen
# ihrer Segmente. Ohne Spalte segment_ids zählt activity_id als einziges Segment.
# Grenzfall: Hat nur ein Teil der Segmente Zonendaten, deckt die Zonenzeit nur diesen Teil ab.
zone_by_activity <- function(zt, acts) {
  if (is.null(zt)) return(NULL)
  ids <- if ("segment_ids" %in% names(acts)) acts$segment_ids else acts$activity_id
  sp  <- strsplit(ifelse(is.na(ids), acts$activity_id, ids), ";", fixed = TRUE)
  map <- tibble(activity_id = rep(acts$activity_id, lengths(sp)), segment = unlist(sp))
  num <- c("trimp_z", "z_min", paste0("z", 1:5, "_min"))
  out <- map |>
    inner_join(zt, by = c("segment" = "activity_id")) |>
    group_by(activity_id) |>
    summarise(across(all_of(num), sum_na), .groups = "drop")
  out$pct_z45 <- ifelse(out$z_min > 0, (out$z4_min + out$z5_min) / out$z_min * 100, NA_real_)
  out
}

# Pendel-Intensität aus den Radfahrten MIT Pulsdaten ableiten (Median der Herzfrequenzreserve).
# Weniger als min_n gemessene Fahrten: Standardwert (Annahme). Kleine Stichprobe: die Spannweite
# wird mit ausgegeben, damit die Unsicherheit sichtbar bleibt.
derive_commute_hrr <- function(acts, p, default = 0.40, min_n = 5) {
  r <- acts[is_ride_type(acts$type_key) & !is.na(acts$avg_hr), ]
  hrr <- hrr_frac(r$avg_hr, p)
  if (length(hrr) < min_n)
    return(list(value = default, n = length(hrr), lo = NA_real_, hi = NA_real_, hr = NA_real_, hr_lo = NA_real_,
                hr_hi = NA_real_, source = "Annahme"))
  list(value = round(median(hrr), 2), n = length(hrr), lo = round(min(hrr), 2), hi = round(max(hrr), 2),
       hr = median(r$avg_hr), hr_lo = min(r$avg_hr), hr_hi = max(r$avg_hr),   # Puls in bpm: das ist die feste Größe
       source = "abgeleitet")
}

# Pendel-Intensität mit festem Pendel-Puls: gespeichert wird der Puls in bpm, die HFR wird bei jedem Lauf
# mit dem aktuellen HFmax/Ruhepuls neu berechnet (ändert sich HFmax, bleibt die Auswertung konsistent).
# Gespeichert wird nur ein abgeleiteter Wert (save = TRUE); die Annahme 0,40 bleibt ungespeichert, damit
# später abgeleitet werden kann.
resolve_commute <- function(ref, acts, p, recalc = FALSE, default = 0.40, min_n = 5) {
  to_hrr <- function(hr) hrr_frac(hr, p)
  if (!recalc && !is.null(ref$commute_hr) && is.finite(ref$commute_hr)) {
    num <- function(x) if (is.null(x)) NA_real_ else x
    return(list(value = round(to_hrr(ref$commute_hr), 2), n = num(ref$commute_n),
                lo = round(to_hrr(num(ref$commute_hr_lo)), 2), hi = round(to_hrr(num(ref$commute_hr_hi)), 2),
                hr = ref$commute_hr, hr_lo = num(ref$commute_hr_lo), hr_hi = num(ref$commute_hr_hi),
                source = "gespeichert", save = FALSE))
  }
  d <- derive_commute_hrr(acts, p, default, min_n)
  d$save <- d$source == "abgeleitet"
  d
}

session_load <- function(acts, p, commute_hrr = 0.40, zones = NULL) {
  zt <- zone_by_activity(zone_trimp(zones, p), acts)
  out <- acts |> mutate(
    hrr       = hrr_frac(avg_hr, p, clip = FALSE),
    est       = is.na(avg_hr) & is_ride_type(type_key),
    hrr_use   = pmin(pmax(ifelse(est, commute_hrr, hrr), 0), 1),
    trimp     = ifelse(is.na(hrr_use), NA_real_, banister(duration_min, hrr_use, p$trimp_b)),
    zone      = as.character(cut(hrr, c(-Inf, ZONE_EDGES, Inf),
                                 labels = c("<Z1", paste0("Z", 1:5)))),
    pct_hrmax = avg_hr / p$hrmax * 100
  ) |> select(-hrr, -hrr_use)
  if (!is.null(zt)) {
    out <- out |> left_join(zt, by = "activity_id") |>
      mutate(trimp_src = ifelse(!is.na(trimp_z), "zonen", ifelse(est, "geschätzt", ifelse(is.na(trimp), NA, "durchschnitt"))),
             trimp = ifelse(!is.na(trimp_z), trimp_z, trimp)) |>
      select(-trimp_z)
  } else {
    out <- out |> mutate(trimp_src = ifelse(est, "geschätzt", ifelse(is.na(trimp), NA, "durchschnitt")),
                         z_min = NA_real_, pct_z45 = NA_real_, z1_min = NA_real_, z2_min = NA_real_,
                         z3_min = NA_real_, z4_min = NA_real_, z5_min = NA_real_)
  }
  out
}

# Wie stark hängt die Gesamt-TRIMP von den Annahmen ab? Variiert HFmax und Pendel-HFR je einzeln.
# Bei HFmax-Varianten wird die Pendel-HFR aus den gemessenen Fahrten neu abgeleitet (gleicher Puls in bpm).
trimp_sensitivity <- function(acts, p, commute_hrr, zones = NULL, hrmax_delta = c(-10, 0, 10),
                              commute = c(0.3, commute_hrr, 0.5)) {
  run <- function(pp, ch) {
    s <- session_load(acts, pp, ch, zones)
    tibble(trimp_total = sum(s$trimp, na.rm = TRUE), share_est = sum(s$trimp[s$est], na.rm = TRUE) / sum(s$trimp, na.rm = TRUE))
  }
  hm <- bind_rows(lapply(hrmax_delta, function(dl) { pp <- p; pp$hrmax <- p$hrmax + dl
    # Pendel-Puls ist in bpm gemessen: die HFR wird für jeden HFmax-Wert neu abgeleitet
    bind_cols(tibble(parameter = "HFmax", value = pp$hrmax), run(pp, derive_commute_hrr(acts, pp, default = commute_hrr)$value)) }))
  cm <- bind_rows(lapply(commute, function(ch) bind_cols(tibble(parameter = "Pendel-HFR", value = ch), run(p, ch))))
  bind_rows(hm, cm)
}

# ---- Tageswerte: Last, ACWR, Baselines, Erholungs-Signale -------------------------------
# roll_apply() (rollierende Statistik über Kalendertage) steht in helpers.R

# ---- Aufbau und Ermüdung (Banister / Performance-Management-Chart) -----------------------------
# Zwei exponentiell gewichtete Mittel der Tageslast: "Fitness" (CTL, lange Zeitkonstante) und "Ermüdung"
# (ATL, kurze); Form = Fitness minus Ermüdung vom Vortag. Aufbau X_t = X_{t-1} + (L_t - X_{t-1}) (1 - exp(-1/tau)).
# Das misst aufgebaute Trainingslast, keine gemessene Leistung. Die Last ist TRIMP, nicht TSS: Schwellen
# aus TrainingPeaks-Beschreibungen gelten hier nicht.
# Unbekannte Tage (usable = FALSE: Last unbekannt, Uhr nicht getragen, unvollständiger Tag) ändern den Zustand
# nicht (eingefroren, pmc_gap = TRUE); sie werden nicht als Last 0 gerechnet. Start: Mittel der ersten
# init_days nutzbaren Tage (init_days = 0: Start bei 0), die ersten tau_fit Tage gelten als Einschwingphase.
fitness_fatigue <- function(load, usable, tau_fit = 42, tau_fat = 7, init_days = 14) {
  if (!is.numeric(load)) stop("fitness_fatigue: load muss numerisch sein (Tageslast, NA erlaubt)")
  if (length(usable) != length(load))
    stop(sprintf("fitness_fatigue: load (%d) und usable (%d) müssen gleich lang sein", length(load), length(usable)))
  if (!(is.numeric(tau_fit) && is.numeric(tau_fat) && tau_fit > 0 && tau_fat > 0)) stop("fitness_fatigue: tau_fit und tau_fat müssen positiv sein")
  if (!(is.numeric(init_days) && init_days >= 0)) stop("fitness_fatigue: init_days muss 0 oder größer sein")
  usable <- !is.na(usable) & usable                          # NA = nicht nutzbar
  n <- length(load)
  out <- tibble(ctl = rep(NA_real_, n), atl = NA_real_, tsb = NA_real_,
                pmc_gap = !usable, pmc_warmup = seq_len(n) <= tau_fit)
  if (n == 0 || !any(usable)) return(out)
  x <- ifelse(usable, load, NA_real_)
  start <- if (init_days > 0) mean(head(x[usable], init_days)) else 0
  a_fit <- 1 - exp(-1 / tau_fit); a_fat <- 1 - exp(-1 / tau_fat)
  ctl <- atl <- start
  for (t in seq_len(n)) {
    out$tsb[t] <- ctl - atl                                  # Vortagswerte
    if (usable[t]) { ctl <- ctl + (x[t] - ctl) * a_fit; atl <- atl + (x[t] - atl) * a_fat }
    out$ctl[t] <- ctl; out$atl[t] <- atl
  }
  out
}

# Wie stark hängt der Endstand von der Behandlung unbekannter Tage ab? (nur zum Ausweisen der Spannweite)
pmc_sensitivity <- function(load, usable, ...) {
  med <- median(load[usable], na.rm = TRUE)
  last <- function(l, u) { r <- fitness_fatigue(l, u, ...); c(ctl = tail(r$ctl, 1), atl = tail(r$atl, 1), tsb = tail(r$tsb, 1)) }
  v <- list("einfrieren" = last(load, usable),
            "Median auffüllen" = last(ifelse(usable, load, med), rep(TRUE, length(load))),
            "0 setzen" = last(ifelse(usable, load, 0), rep(TRUE, length(load))))
  tibble(variante = names(v), ctl = vapply(v, `[`, 0, "ctl"), atl = vapply(v, `[`, 0, "atl"),
         tsb = vapply(v, `[`, 0, "tsb"))
}

daily_load_recovery <- function(daily, acts_s, min_gap_days = 10) {
  daily <- flag_daily(arrange(daily, date))
  per_day <- acts_s |>
    mutate(date = as.Date(start)) |>
    group_by(date) |>
    summarise(load_meas = sum(trimp[!est], na.rm = TRUE),
              load_est  = sum(trimp[est],  na.rm = TRUE),
              te_max    = max_na(te_aerobic),
              hiit      = any(type_key == "hiit"), .groups = "drop")
  d <- daily |> left_join(per_day, by = "date")

  # Zeiträume ohne jede Aktivität (>= min_gap_days Tage): Last unbekannt (Uhr getragen, Schritte
  # vorhanden) oder Uhr nicht getragen (kaum Schritte). Beide Fälle: Last = NA (nicht 0).
  # Annotierte Zeiträume (ann_load_unknown, data/annotations.csv) zählen immer als "Last unbekannt".
  no_act <- is.na(d$load_meas)
  worn   <- !is.na(d$steps) & d$steps >= MIN_STEPS
  r <- rle(no_act); ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1
  d$no_wear <- FALSE; d$load_unknown <- FALSE
  for (j in which(r$values & r$lengths >= min_gap_days)) {
    idx <- starts[j]:ends[j]
    if (mean(worn[idx]) >= 0.5) d$load_unknown[idx] <- TRUE else d$no_wear[idx] <- TRUE
  }
  if ("ann_load_unknown" %in% names(d)) {
    ann <- coalesce(d$ann_load_unknown, FALSE)
    d$load_unknown <- d$load_unknown | ann
    d$no_wear      <- d$no_wear & !ann
  }
  d$unrecorded <- d$no_wear | d$load_unknown      # Sammelmarke für Weiterverwendung (Last = NA)

  d <- d |> mutate(
    load_meas = ifelse(unrecorded, NA_real_, coalesce(load_meas, 0)),
    load_est  = ifelse(unrecorded, NA_real_, coalesce(load_est, 0)),
    load      = load_meas + load_est,
    hiit      = coalesce(hiit, FALSE),
    # unvollständige Tage (heute, Uhr nicht getragen) zählen nicht in die Mittel; ihre Last bleibt sichtbar
    load_acwr = ifelse(partial, NA_real_, load),
    acute_d   = roll_apply(load_acwr, date, 7, mean, 5),      # mittlere Tageslast, letzte 7 Tage
    chronic_d = roll_apply(load_acwr, date, 28, mean, 14),    # mittlere Tageslast, letzte 28 Tage
    acwr      = ifelse(!is.na(chronic_d) & chronic_d >= 1, acute_d / chronic_d, NA_real_),
    # Variante nur mit gemessener Last (ohne die pauschal geschätzten Pendelfahrten)
    load_meas_acwr = ifelse(partial, NA_real_, load_meas),
    acute_m   = roll_apply(load_meas_acwr, date, 7, mean, 5),
    chronic_m = roll_apply(load_meas_acwr, date, 28, mean, 14),
    acwr_meas = ifelse(!is.na(chronic_m) & chronic_m >= 1, acute_m / chronic_m, NA_real_)
  )
  d <- bind_cols(d, fitness_fatigue(d$load, !d$unrecorded & !d$partial))

  # persönliche Baselines (28 Tage vor dem jeweiligen Tag, mind. 14 Werte), aus bereinigten Werten
  cl    <- clean_daily(d, extra_cols = "bb_high")   # Artefakt-Ruhepuls und ungültige Nächte = NA
  rhr   <- cl$resting_hr
  sleep <- cl$sleep_score
  bb    <- cl$bb_high
  z <- function(x, k = 28, min_n = 14) {
    m <- roll_apply(x, d$date, k, mean, min_n, lag_by = 1); s <- roll_apply(x, d$date, k, sd, min_n, lag_by = 1)
    list(m = m, s = s, z = ifelse(!is.na(s) & s > 0, (x - m) / s, NA_real_))
  }
  hrv   <- if ("hrv_night" %in% names(cl)) cl$hrv_night else rep(NA_real_, nrow(d))
  hrv   <- ln_or_na(hrv)                                       # HRV schwankt multiplikativ: z auf der ln-Skala
  zr <- z(rhr); zs <- z(sleep); zb <- z(bb); zh <- z(hrv)
  d$rhr_base <- zr$m; d$rhr_lo <- zr$m - 1.5 * zr$s; d$rhr_hi <- zr$m + 1.5 * zr$s
  d$rhr_z <- zr$z; d$sleep_z <- zs$z; d$bb_z <- zb$z; d$hrv_z <- zh$z
  d$sig_rhr   <- coalesce(zr$z >= 1.5, FALSE)    # Ruhepuls deutlich erhöht
  d$sig_sleep <- coalesce(zs$z <= -1, FALSE)     # Schlaf-Score deutlich niedriger
  d$sig_bb    <- coalesce(zb$z <= -1, FALSE)     # Body-Battery-Höchstwert deutlich niedriger
  d$sig_hrv   <- coalesce(zh$z <= -1, FALSE)     # nächtliche HRV deutlich niedriger
  d$flags <- d$sig_rhr + d$sig_sleep + d$sig_bb + d$sig_hrv
  # Die vier Signale sind nicht unabhängig (Schlaf-Score und Body Battery hängen eng zusammen, Ruhepuls und
  # HRV gegenläufig); der Index fasst sie zusammen und berücksichtigt das über die Streuung des Mittels.
  ri <- recovery_index(cbind(-d$rhr_z, d$sleep_z, d$bb_z, d$hrv_z))
  d$rec_index <- ri$index
  d$rec_low   <- coalesce(ri$index <= REC_INDEX_THRESHOLD, FALSE)
  attr(d, "rec_index_info") <- list(n_eff = ri$n_eff, sd = ri$sd, cor = ri$cor)
  d
}

# ---- Erholungs-Index: die vier Signale gemeinsam ---------------------------------------------
# Warn-Signale (Ruhepuls, Schlaf-Score, Body-Battery-Höchstwert, HRV) messen zum Teil dieselbe Erholung. Die
# bloße Anzahl "mindestens 2 von 4" zählt diese Information mehrfach. Der Index ist das Mittel der vier
# z-Werte (alle so ausgerichtet, dass niedriger = schlechter) geteilt durch seine eigene Standardabweichung
# über alle Tage: Redundante Signale streuen im Mittel stärker und zählen dadurch weniger. Für die
# Kennzahl n_eff gilt: n_eff = m^2 / Summe der Korrelationsmatrix (m Signale; 1 = alle identisch, m = unabhängig).
# Näherung: Standardabweichung und Korrelation stammen aus dem gesamten Zeitraum (beschreibend, kein Test).
# Die Schwelle ist nicht an einem Ergebnis (Krankheit, Leistungsabfall) validiert.
REC_INDEX_MIN_SIGNALS <- 3
REC_INDEX_THRESHOLD   <- -1.5

effective_signals <- function(z) {
  R <- suppressWarnings(cor(z, use = "pairwise.complete.obs"))
  if (anyNA(R)) return(NA_real_)
  unname(min(ncol(z), ncol(z)^2 / sum(R)))   # zufällig negative Korrelationen ergäben mehr als m
}

recovery_index <- function(z, min_signals = REC_INDEX_MIN_SIGNALS) {
  k   <- rowSums(!is.na(z))
  raw <- ifelse(k >= min_signals, rowMeans(z, na.rm = TRUE), NA_real_)
  s   <- if (sum(!is.na(raw)) >= 2) sd(raw, na.rm = TRUE) else NA_real_
  list(index = if (is.na(s) || s == 0) rep(NA_real_, nrow(z)) else raw / s, sd = s,
       n_eff = effective_signals(z), cor = suppressWarnings(cor(z, use = "pairwise.complete.obs")))
}

# ---- Erholung nach HIIT: Vergleich der Folgetag-Werte -------------------------------------
# Aufbau: recovery_data() (eine Zeile je HIIT-/Nicht-HIIT-Tag mit den Werten des Folgetags),
# recovery_model() (adjustierter Effekt je Kennwert) und recovery_design() (wie gut sind HIIT-
# und Vergleichstage über die Messwochentage verteilt?).
# Ausgeschlossen werden Tage mit unbekannter Last (unrecorded: Trainingstag) und Zeilen, deren Messtag (Folgetag)
# annotiert ist (data/annotations.csv, z. B. Segeltörn mit Nachtwachen): Dort stammen die Werte nicht aus dem
# gewöhnlichen Alltag. Ein annotierter Trainingstag mit bekannter Last bleibt, seine Folgenacht zählt.
# Hinweis zur Methode: HIIT liegt auf wenigen Wochentagen, und der Wochentag der Messung beeinflusst
# die Werte (z. B. Wochenende). Ein roher Gruppenvergleich ist deshalb konfundiert; das Modell
# adjustiert für den Wochentag. Aussage bleibt ein Zusammenhang, kein Kausalbeweis.
RECOVERY_METRICS <- tibble(
  col = c("sleep_score_n", "deep_h_n", "bb_high_n", "resting_hr_n", "hrv_n", "sleep_hr_n", "ready_n"),
  metric = c("Schlaf-Score", "Tiefschlaf (h)", "Body-Battery-Höchstwert", "Ruhepuls (bpm)",
             "HRV nachts (ms)", "Puls im Schlaf (bpm)", "Training Readiness"),
  independent = c(rep(TRUE, 6), FALSE))   # Readiness enthält Garmins Last und Erholungszeit: nicht unabhängig

recovery_data <- function(d) {
  d  <- flag_daily(d)
  cl <- clean_daily(d, extra_cols = c("bb_high", "ready_score"))
  sleep_ok <- !is.na(d$sleep_h) & !d$sleep_bad       # Nacht vorhanden und gültig
  has <- function(col) col %in% names(cl)
  ok  <- function(col) if (has(col)) ifelse(sleep_ok, cl[[col]], NA) else rep(NA_real_, nrow(d))
  ann <- if ("ann_note" %in% names(d)) !is.na(d$ann_note) else rep(FALSE, nrow(d))   # annotierter Messtag
  nx <- tibble(date = d$date - 1, ann_n = ann,
               sleep_score_n = ok("sleep_score"), deep_h_n = ok("deep_h"), bb_high_n = ok("bb_high"),
               resting_hr_n = if (has("resting_hr")) cl$resting_hr else rep(NA_real_, nrow(d)),
               hrv_n = ok("hrv_night"), sleep_hr_n = ok("sleep_hr"), ready_n = ok("ready_score"))
  d |> filter(!unrecorded) |> select(date, hiit) |> inner_join(nx, by = "date") |>
    filter(!ann_n) |> select(-ann_n) |> arrange(date) |>
    mutate(wd = factor(format(date + 1, "%u"), levels = as.character(1:7)))   # Wochentag der Messung (Mo = 1)
}

# Schätzt je Kennwert: Mittel nach HIIT/sonst, roher Unterschied, wochentag-adjustierter Unterschied mit
# 95-%-Konfidenzintervall (Newey-West, robust gegen Autokorrelation der Tageswerte), standardisierte
# Effektgröße d (adjustierter Unterschied / gepoolte Standardabweichung der Gruppen) und p-Wert, Holm-
# korrigiert über die unabhängigen Kennwerte. r_*: dieselbe Schätzung nur für Messwochentage, an denen
# HIIT- und Vergleichstage vorkommen (Sensitivität).
# Näherung: Lücken im Kalender (ausgeschlossene Tage, fehlende Werte) bleiben unberücksichtigt, die
# Beobachtungen gelten für die Autokorrelation als aufeinanderfolgend.
recovery_model <- function(x, lag = 3, min_n = 5) {
  rd <- recovery_design(x); both_days <- rd$wd[rd$both]
  fit <- function(dat, m) {
    dat$y <- dat[[m]]; dat <- dat[!is.na(dat$y), ]
    a <- dat$y[dat$hiit]; b <- dat$y[!dat$hiit]
    if (length(a) < min_n || length(b) < min_n || sd(dat$y) == 0) return(NULL)   # konstanter Kennwert: kein Effekt schätzbar
    multi <- nlevels(droplevels(dat$wd)) > 1
    f <- if (multi) lm(y ~ hiit + droplevels(wd), data = dat) else lm(y ~ hiit, data = dat)
    if (is.na(coef(f)["hiitTRUE"])) return(NULL)
    e <- nw_effect(f, "hiitTRUE", lag)   # Lag 3: Folgetag-Werte sind über wenige Tage autokorreliert (Faustregel n^(1/4), bei 100-180 Tagen etwa 3-4); gewählt, nicht an den Daten geprüft
    sp <- sqrt(((length(a) - 1) * var(a) + (length(b) - 1) * var(b)) / (length(a) + length(b) - 2))
    list(a = a, b = b, est = e$est, lo = e$lo, hi = e$hi, p = e$p, d = e$est / sp)
  }
  rows <- lapply(seq_len(nrow(RECOVERY_METRICS)), function(i) {
    m <- RECOVERY_METRICS$col[i]
    full <- fit(x, m)
    if (is.null(full)) return(NULL)
    rest <- fit(x[x$wd %in% both_days, ], m)
    tibble(metric = RECOVERY_METRICS$metric[i], independent = RECOVERY_METRICS$independent[i],
           hiit = mean(full$a), other = mean(full$b), diff = mean(full$a) - mean(full$b),
           adj_diff = full$est, ci_lo = full$lo, ci_hi = full$hi, d = full$d, p = full$p,
           n_hiit = length(full$a), n_other = length(full$b),
           r_diff = if (is.null(rest)) NA_real_ else rest$est,
           r_lo   = if (is.null(rest)) NA_real_ else rest$lo,
           r_hi   = if (is.null(rest)) NA_real_ else rest$hi)
  })
  out <- bind_rows(rows)
  if (is.null(out) || nrow(out) == 0) return(out)
  out$p_holm <- NA_real_
  out$p_holm[out$independent] <- p.adjust(out$p[out$independent], method = "holm")   # Holm nur über die unabhängigen Kennwerte (Training Readiness enthält Garmins Last und wird nicht bewertet)
  out
}

# Verteilung der Messtage: je Wochentag der Messung Anzahl HIIT-Folgetage und Vergleichstage.
# both = TRUE, wenn beide Gruppen mindestens min_each-mal vorkommen (nur dort trägt die Adjustierung).
recovery_design <- function(x, min_each = 3) {
  tibble(wd = 1:7) |>
    mutate(n_hiit  = vapply(wd, function(w) sum(x$hiit & as.integer(as.character(x$wd)) == w), numeric(1)),
           n_other = vapply(wd, function(w) sum(!x$hiit & as.integer(as.character(x$wd)) == w), numeric(1)),
           both    = n_hiit >= min_each & n_other >= min_each)
}
