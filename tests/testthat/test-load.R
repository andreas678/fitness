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
