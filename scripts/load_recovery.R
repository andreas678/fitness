# =============================================================================
# load_recovery.R  –  Athletenprofil, Einheiten-Belastung (TRIMP) und Erholungs-Signale
# (benötigt dplyr, tibble; setzt helpers.R voraus; wird per source() eingebunden)
# =============================================================================
# Benötigte Variablen in ~/.Renviron:
#   BIRTHDAY="26-07-1974"   (TT-MM-JJJJ)      GENDER="male"|"female"
# Optional:
#   HRMAX="190"   gemessene maximale Herzfrequenz; ohne Angabe wird sie nach
#                 Tanaka geschätzt (208 - 0.7 * Alter, Streuung etwa +-10 bpm).
# Die Werte werden nur zur Berechnung genutzt; das Geburtsdatum wird nicht ausgegeben.
# =============================================================================

# ---- Profil, Zonen ---------------------------------------------------------------
athlete_profile <- function(rhr_ref, today = Sys.Date()) {
  bd <- suppressWarnings(as.Date(Sys.getenv("BIRTHDAY"),
                                 tryFormats = c("%d-%m-%Y", "%Y-%m-%d", "%d.%m.%Y")))
  age <- if (is.na(bd)) NA_real_ else floor(as.numeric(today - bd) / 365.2425)
  hr_env <- suppressWarnings(as.numeric(Sys.getenv("HRMAX")))
  if (is.finite(hr_env) && hr_env > 0) {
    hrmax <- hr_env; src <- "gemessen"
  } else if (!is.na(age)) {
    hrmax <- round(208 - 0.7 * age); src <- "geschätzt (Tanaka)"
  } else stop("BIRTHDAY (TT-MM-JJJJ) oder HRMAX in ~/.Renviron setzen.")
  male <- !tolower(Sys.getenv("GENDER")) %in% c("female", "f", "w", "weiblich")
  hrr  <- hrmax - rhr_ref
  list(age = age, male = male, hrmax = hrmax, hrmax_source = src, rhr_ref = rhr_ref,
       trimp_b = if (male) 1.92 else 1.67,                   # Banister-TRIMP-Faktor
       zones = tibble(zone = paste0("Z", 1:5),
                      lo = round(rhr_ref + hrr * c(.5, .6, .7, .8, .9)),
                      hi = round(rhr_ref + hrr * c(.6, .7, .8, .9, 1))))
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
  hrr  <- pmin(pmax((mids - p$rhr_ref) / (p$hrmax - p$rhr_ref), 0), 1)
  secs <- as.matrix(zones[paste0("z", 1:5, "_s")]); secs[is.na(secs)] <- 0
  tibble(activity_id = zones$activity_id,
         trimp_z = rowSums(banister(secs / 60, hrr, p$trimp_b)),
         z_min   = rowSums(secs) / 60,
         pct_z45 = ifelse(rowSums(secs) > 0, (secs[, 4] + secs[, 5]) / rowSums(secs) * 100, NA_real_),
         z1_min = secs[, 1] / 60, z2_min = secs[, 2] / 60, z3_min = secs[, 3] / 60,
         z4_min = secs[, 4] / 60, z5_min = secs[, 5] / 60)
}

session_load <- function(acts, p, commute_hrr = 0.40, zones = NULL) {
  zt <- zone_trimp(zones, p)
  out <- acts |> mutate(
    hrr       = (avg_hr - p$rhr_ref) / (p$hrmax - p$rhr_ref),
    est       = is.na(avg_hr) & type_key %in% "cycling",
    hrr_use   = pmin(pmax(ifelse(est, commute_hrr, hrr), 0), 1),
    trimp     = ifelse(is.na(hrr_use), NA_real_, banister(duration_min, hrr_use, p$trimp_b)),
    zone      = as.character(cut(hrr, c(-Inf, .5, .6, .7, .8, .9, Inf),
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

# ---- Tageswerte: Last, ACWR, Baselines, Erholungs-Signale -------------------------------
roll_apply <- function(x, k, fun, min_n, lag_by = 0) {
  vapply(seq_along(x), function(i) {
    hi <- i - lag_by; lo <- hi - k + 1
    if (hi < 1) return(NA_real_)
    w <- x[max(1, lo):hi]; w <- w[!is.na(w)]
    if (length(w) >= min_n) fun(w) else NA_real_
  }, numeric(1))
}

daily_load_recovery <- function(daily, acts_s, min_gap_days = 10) {
  daily <- arrange(daily, date)
  per_day <- acts_s |>
    mutate(date = as.Date(start)) |>
    group_by(date) |>
    summarise(load_meas = sum(trimp[!est], na.rm = TRUE),
              load_est  = sum(trimp[est],  na.rm = TRUE),
              te_max    = max_na(te_aerobic),
              hiit      = any(type_key == "hiit"), .groups = "drop")
  d <- daily |> left_join(per_day, by = "date")

  # Zeiträume ohne jede Aktivität (>= min_gap_days Tage) = Uhr vermutlich nicht getragen
  no_act <- is.na(d$load_meas)
  r <- rle(no_act); ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1
  d$unrecorded <- FALSE
  for (j in which(r$values & r$lengths >= min_gap_days)) d$unrecorded[starts[j]:ends[j]] <- TRUE

  d <- d |> mutate(
    load_meas = ifelse(unrecorded, NA_real_, coalesce(load_meas, 0)),
    load_est  = ifelse(unrecorded, NA_real_, coalesce(load_est, 0)),
    load      = load_meas + load_est,
    hiit      = coalesce(hiit, FALSE),
    acute_d   = roll_apply(load, 7, mean, 5),      # mittlere Tageslast, letzte 7 Tage
    chronic_d = roll_apply(load, 28, mean, 14),    # mittlere Tageslast, letzte 28 Tage
    acwr      = ifelse(!is.na(chronic_d) & chronic_d >= 1, acute_d / chronic_d, NA_real_)
  )

  # persönliche Baselines (28 Tage vor dem jeweiligen Tag, mind. 14 Werte)
  rhr   <- ifelse(d$resting_hr >= 45, d$resting_hr, NA)       # < 45 = Artefakt
  bad   <- !is.na(d$sleep_h) & d$sleep_h < 5                  # Uhr nicht getragen
  sleep <- ifelse(bad, NA, d$sleep_score)
  bb    <- ifelse(bad, NA, d$bb_high)
  z <- function(x, k = 28, min_n = 14) {
    m <- roll_apply(x, k, mean, min_n, lag_by = 1); s <- roll_apply(x, k, sd, min_n, lag_by = 1)
    list(m = m, s = s, z = ifelse(!is.na(s) & s > 0, (x - m) / s, NA_real_))
  }
  hrv   <- if ("hrv_night" %in% names(d)) ifelse(bad, NA, d$hrv_night) else rep(NA_real_, nrow(d))
  zr <- z(rhr); zs <- z(sleep); zb <- z(bb); zh <- z(hrv)
  d$rhr_base <- zr$m; d$rhr_lo <- zr$m - 1.5 * zr$s; d$rhr_hi <- zr$m + 1.5 * zr$s
  d$rhr_z <- zr$z; d$sleep_z <- zs$z; d$bb_z <- zb$z; d$hrv_z <- zh$z
  d$sig_rhr   <- coalesce(zr$z >= 1.5, FALSE)    # Ruhepuls deutlich erhöht
  d$sig_sleep <- coalesce(zs$z <= -1, FALSE)     # Schlaf-Score deutlich niedriger
  d$sig_bb    <- coalesce(zb$z <= -1, FALSE)     # Body-Battery-Höchstwert deutlich niedriger
  d$sig_hrv   <- coalesce(zh$z <= -1, FALSE)     # nächtliche HRV deutlich niedriger
  d$flags <- d$sig_rhr + d$sig_sleep + d$sig_bb + d$sig_hrv
  d
}

# ---- Erholung nach HIIT: Vergleich der Folgetag-Werte -------------------------------------
perm_p <- function(x, y, B = 10000) {
  obs <- mean(x) - mean(y); all <- c(x, y); n <- length(x)
  set.seed(42)
  hits <- sum(replicate(B, { s <- sample(all); abs(mean(s[1:n]) - mean(s[-(1:n)])) >= abs(obs) }))
  (hits + 1) / (B + 1)
}

recovery_summary <- function(d) {
  d <- d |> mutate(sleep_ok = !is.na(sleep_h) & sleep_h >= 5)
  has <- function(col) col %in% names(d)
  ok  <- function(col) if (has(col)) ifelse(d$sleep_ok, d[[col]], NA) else rep(NA_real_, nrow(d))
  nx <- tibble(date = d$date - 1,
               sleep_score_n = ok("sleep_score"), deep_h_n = ok("deep_h"), bb_high_n = ok("bb_high"),
               resting_hr_n = ifelse(d$resting_hr >= 45, d$resting_hr, NA),
               hrv_n = ok("hrv_night"), sleep_hr_n = ok("sleep_hr"), ready_n = ok("ready_score"))
  x <- d |> filter(!unrecorded) |> select(date, hiit, te_max) |> inner_join(nx, by = "date")
  mets <- c(sleep_score_n = "Schlaf-Score", deep_h_n = "Tiefschlaf (h)",
            bb_high_n = "Body-Battery-Höchstwert", resting_hr_n = "Ruhepuls (bpm)",
            hrv_n = "HRV nachts (ms)", sleep_hr_n = "Puls im Schlaf (bpm)",
            ready_n = "Training Readiness")
  bind_rows(lapply(names(mets), function(m) {
    a <- x[[m]][x$hiit]; b <- x[[m]][!x$hiit]; a <- a[!is.na(a)]; b <- b[!is.na(b)]
    if (length(a) < 5 || length(b) < 5) return(NULL)
    tibble(metric = mets[[m]], hiit = mean(a), other = mean(b), diff = mean(a) - mean(b),
           p = perm_p(a, b), n_hiit = length(a), n_other = length(b))
  }))
}
