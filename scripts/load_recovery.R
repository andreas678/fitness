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
# Genutzt wird nur die Durchschnitts-HF der Einheit (keine Zeit in Zonen verfügbar).
# Radfahrten ohne Pulsdaten (Pendeln) bekommen eine ANNAHME (commute_hrr) und sind als
# "geschätzt" markiert.
session_load <- function(acts, p, commute_hrr = 0.40) {
  acts |> mutate(
    hrr       = (avg_hr - p$rhr_ref) / (p$hrmax - p$rhr_ref),
    est       = is.na(avg_hr) & type_key %in% "cycling",
    hrr_use   = pmin(pmax(ifelse(est, commute_hrr, hrr), 0), 1),
    trimp     = ifelse(is.na(hrr_use), NA_real_,
                       duration_min * hrr_use * 0.64 * exp(p$trimp_b * hrr_use)),
    zone      = as.character(cut(hrr, c(-Inf, .5, .6, .7, .8, .9, Inf),
                                 labels = c("<Z1", paste0("Z", 1:5)))),
    pct_hrmax = avg_hr / p$hrmax * 100
  ) |> select(-hrr, -hrr_use)
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
  zr <- z(rhr); zs <- z(sleep); zb <- z(bb)
  d$rhr_base <- zr$m; d$rhr_lo <- zr$m - 1.5 * zr$s; d$rhr_hi <- zr$m + 1.5 * zr$s
  d$rhr_z <- zr$z; d$sleep_z <- zs$z; d$bb_z <- zb$z
  d$sig_rhr   <- coalesce(zr$z >= 1.5, FALSE)    # Ruhepuls deutlich erhöht
  d$sig_sleep <- coalesce(zs$z <= -1, FALSE)     # Schlaf-Score deutlich niedriger
  d$sig_bb    <- coalesce(zb$z <= -1, FALSE)     # Body-Battery-Höchstwert deutlich niedriger
  d$flags <- d$sig_rhr + d$sig_sleep + d$sig_bb
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
  nx <- d |> transmute(date = date - 1,
                       sleep_score_n = ifelse(sleep_ok, sleep_score, NA),
                       deep_h_n = ifelse(sleep_ok, deep_h, NA),
                       bb_high_n = ifelse(sleep_ok, bb_high, NA),
                       resting_hr_n = ifelse(resting_hr >= 45, resting_hr, NA))
  x <- d |> filter(!unrecorded) |> select(date, hiit, te_max) |> inner_join(nx, by = "date")
  mets <- c(sleep_score_n = "Schlaf-Score", deep_h_n = "Tiefschlaf (h)",
            bb_high_n = "Body-Battery-Höchstwert", resting_hr_n = "Ruhepuls (bpm)")
  bind_rows(lapply(names(mets), function(m) {
    a <- x[[m]][x$hiit]; b <- x[[m]][!x$hiit]; a <- a[!is.na(a)]; b <- b[!is.na(b)]
    tibble(metric = mets[[m]], hiit = mean(a), other = mean(b), diff = mean(a) - mean(b),
           p = perm_p(a, b), n_hiit = length(a), n_other = length(b))
  }))
}
