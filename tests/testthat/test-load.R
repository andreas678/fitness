source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

p <- list(rhr_ref = 54, hrmax = 182, trimp_b = 1.92)

# Garmin-Zonen: Untergrenzen in bpm, Zeit in Sekunden
zone_row <- function(id, secs) {
  tibble(activity_id = id, z1_low = 89, z2_low = 107, z3_low = 125, z4_low = 142, z5_low = 160,
         z1_s = secs[1], z2_s = secs[2], z3_s = secs[3], z4_s = secs[4], z5_s = secs[5])
}
zones <- bind_rows(zone_row("1", c(0, 600, 0, 0, 0)), zone_row("2", c(0, 0, 600, 0, 0)))

hrr_mid <- function(lo, hi) ((lo + hi) / 2 - 54) / (182 - 54)

act <- function(id, dur, hr, ids = NULL) {
  a <- tibble(activity_id = id, start = as.POSIXct("2026-01-01 08:00:00", tz = "UTC"),
              type_key = "cycling", duration_min = dur, avg_hr = hr, te_aerobic = NA_real_)
  if (!is.null(ids)) a$segment_ids <- ids
  a
}

test_that("Zonen-TRIMP einer Einzelfahrt entspricht der Banister-Formel je Zone", {
  out <- session_load(act("1", 10, 116), p, zones = zones)
  expect_equal(out$trimp, banister(10, hrr_mid(107, 125), 1.92))
  expect_equal(out$trimp_src, "zonen")
  expect_equal(out$z2_min, 10)
})

test_that("Zonen gemergter Fahrten werden über alle Segmente summiert", {
  out <- session_load(act("1", 20, 125, ids = "1;2"), p, zones = zones)
  expect_equal(out$trimp, banister(10, hrr_mid(107, 125), 1.92) + banister(10, hrr_mid(125, 142), 1.92))
  expect_equal(out$z_min, 20)
  expect_equal(c(out$z2_min, out$z3_min), c(10, 10))
  expect_equal(out$pct_z45, 0)
})

test_that("Ohne segment_ids verhält sich session_load wie bisher", {
  expect_equal(session_load(act("1", 10, 116), p, zones = zones)$trimp,
               session_load(act("1", 10, 116, ids = "1"), p, zones = zones)$trimp)
})

# ---- Pendel-Intensität, Wear-Erkennung, ACWR nur aus gemessener Last, Sensitivität -------------
test_that("derive_commute_hrr nimmt den Median der gemessenen Fahrten, sonst den Standardwert", {
  rides <- tibble(type_key = "cycling", avg_hr = c(113, 126, 108, 86, 113, 130))    # HFR .46 .56 .42 .25 .46 .59
  r <- derive_commute_hrr(rides, p, default = 0.40)
  expect_equal(r$value, 0.46); expect_equal(r$n, 6); expect_equal(r$source, "abgeleitet")
  expect_equal(c(r$lo, r$hi), c(0.25, 0.59))
  few <- derive_commute_hrr(rides[1:3, ], p, default = 0.40)
  expect_equal(few$value, 0.40); expect_equal(few$source, "Annahme")
  other <- derive_commute_hrr(bind_rows(rides, tibble(type_key = "hiit", avg_hr = 170)), p)
  expect_equal(other$n, 6)                                            # nur Radfahrten zählen
})

# 40 Tage Daten; Aktivitäten außer in der Lücke [gap]; steps_gap steuert die Wear-Evidenz
mk_gap <- function(gap, steps_gap, today_offset = 100) {
  days <- as.Date("2026-01-01") + 0:39
  daily <- tibble(date = days, steps = ifelse(seq_along(days) %in% gap, steps_gap, 8000),
                  resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80)
  act_days <- days[!seq_along(days) %in% gap]
  acts <- tibble(start = as.POSIXct(paste(act_days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  daily_load_recovery(daily, acts)
}

test_that("Lange Lücke mit Schritten = Last unbekannt, ohne Schritte = Uhr nicht getragen", {
  worn <- mk_gap(10:21, steps_gap = 3000)
  expect_true(all(worn$load_unknown[10:21])); expect_false(any(worn$no_wear))
  off <- mk_gap(10:21, steps_gap = NA_real_)
  expect_true(all(off$no_wear[10:21])); expect_false(any(off$load_unknown))
  expect_true(all(worn$unrecorded[10:21]) && all(off$unrecorded[10:21]))
  expect_true(all(is.na(worn$load[10:21])))
})

test_that("Kurze Lücke bleibt Nulllast", {
  short <- mk_gap(10:14, steps_gap = 3000)
  expect_false(any(short$unrecorded)); expect_equal(short$load[10:14], rep(0, 5))
})

test_that("Annotation 'Last unbekannt' macht die Last NA, auch ohne lange Lücke", {
  days <- as.Date("2026-01-01") + 0:39
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80)
  ann <- read_annotations(local({ f <- tempfile(fileext = ".csv")
    writeLines(c("from,to,note,load_unknown,short_sleep_real", "2026-01-20,2026-01-23,Segeln,TRUE,FALSE"), f); f }))
  acts <- tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  d <- daily_load_recovery(apply_annotations(daily, ann), acts)
  idx <- which(days >= as.Date("2026-01-20") & days <= as.Date("2026-01-23"))
  expect_true(all(d$load_unknown[idx])); expect_true(all(is.na(d$load[idx])))
  expect_false(any(d$load_unknown[-idx]))
})

test_that("acwr_meas rechnet nur mit gemessener Last", {
  n <- 40; days <- Sys.Date() - (n - 1):0 - 2                                    # heute ausgeschlossen
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80)
  acts <- bind_rows(
    tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 40, est = FALSE, te_aerobic = NA_real_, type_key = "hiit"),
    tibble(start = as.POSIXct(paste(days, "17:00:00"), tz = "UTC"), trimp = 10, est = TRUE,  te_aerobic = NA_real_, type_key = "cycling"))
  d <- daily_load_recovery(daily, acts)
  expect_equal(tail(d$acwr_meas, 1), 1)                                          # gleichmäßige Last
  acts$trimp[acts$est & as.Date(acts$start) > max(days) - 7] <- 100              # nur geschätzte Last steigt
  d2 <- daily_load_recovery(daily, acts)
  expect_equal(tail(d2$acwr_meas, 1), 1)                                         # gemessene ACWR unverändert
  expect_gt(tail(d2$acwr, 1), 1.2)                                               # Gesamt-ACWR steigt
})

test_that("trimp_sensitivity variiert HFmax und Pendel-HFR einzeln", {
  acts <- bind_rows(act("1", 60, 140), act("2", 30, NA)) |> mutate(type_key = "cycling")
  s <- trimp_sensitivity(acts, p, commute_hrr = 0.46, zones = NULL, hrmax_delta = c(-10, 0, 10), commute = c(0.3, 0.46, 0.5))
  expect_equal(nrow(s), 6)
  expect_true(all(c("parameter", "value", "trimp_total", "share_est") %in% names(s)))
  hm <- s[s$parameter == "HFmax", ]
  expect_true(hm$trimp_total[1] > hm$trimp_total[2] && hm$trimp_total[2] > hm$trimp_total[3])   # höhere HFmax = weniger TRIMP
  cm <- s[s$parameter == "Pendel-HFR", ]
  expect_true(all(diff(cm$trimp_total) > 0))
  expect_true(all(s$share_est > 0 & s$share_est < 1))
})

test_that("trimp_sensitivity leitet die Pendel-HFR bei jeder HFmax-Variante neu aus den gemessenen Fahrten ab", {
  rides <- bind_rows(lapply(1:6, function(i) act(as.character(i), 40, 100 + 4 * i))) |> mutate(type_key = "cycling")
  commute_ride <- bind_rows(rides, act("99", 30, NA) |> mutate(type_key = "cycling"))     # eine Fahrt ohne Puls
  s <- trimp_sensitivity(commute_ride, p, commute_hrr = derive_commute_hrr(commute_ride, p)$value,
                         zones = NULL, hrmax_delta = c(-10, 0, 10), commute = c(0.3, 0.4, 0.5))
  hm <- s[s$parameter == "HFmax", ]
  for (i in seq_len(nrow(hm))) {
    pp <- p; pp$hrmax <- hm$value[i]
    expected <- sum(session_load(commute_ride, pp, derive_commute_hrr(commute_ride, pp)$value)$trimp, na.rm = TRUE)
    expect_equal(hm$trimp_total[i], expected)
  }
})
