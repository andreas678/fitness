source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

today <- as.Date("2026-10-05")
mk_daily <- function(...) {
  tibble(date = today - 5:0, steps = 8000, resting_hr = 54, sleep_h = 7, deep_h = 1, sleep_score = 80,
         bb_high = 80, ready_score = 60, hrv_night = 33) |> mutate(...)
}

test_that("flag_daily markiert Nächte unter der Schwelle und Ruhepuls-Artefakte", {
  d <- mk_daily(sleep_h = c(4.9, 5, NA, 7, 7, 7), resting_hr = c(39, 45, 54, NA, 54, 54))
  f <- flag_daily(d, today = today)
  expect_equal(f$sleep_bad, c(TRUE, FALSE, FALSE, FALSE, FALSE, FALSE))   # 5,0 h gilt, NA ist nicht "schlecht"
  expect_equal(f$rhr_bad,   c(TRUE, FALSE, FALSE, FALSE, FALSE, FALSE))
})

test_that("flag_daily markiert unvollständige Tage: heute und Tage ohne Trage-Evidenz", {
  d <- mk_daily(steps = c(8000, 25, 25, 3000, 8000, 270),
                sleep_h = c(7, NA, 7, NA, 7, 8))                          # letzte Zeile = heute
  f <- flag_daily(d, today = today)
  expect_equal(f$partial, c(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE))     # 25 Schritte + Schlaf vorhanden: echter Tag
})

test_that("flag_daily kommt mit fehlenden Spalten zurecht (Demo-Daten)", {
  f <- flag_daily(tibble(date = today - 1:0, steps = c(5000, 100)), today = today)
  expect_equal(f$sleep_bad, c(FALSE, FALSE)); expect_equal(f$rhr_bad, c(FALSE, FALSE))
  expect_equal(f$partial, c(FALSE, TRUE))
})

test_that("clean_daily maskiert nur betroffene Zeilen und lässt Schritte unberührt", {
  d <- mk_daily(sleep_h = c(4, 7, 7, 7, 7, 7), resting_hr = c(54, 39, 54, 54, 54, 54))
  cl <- clean_daily(d, today = today)
  expect_true(is.na(cl$sleep_h[1]) && is.na(cl$deep_h[1]) && is.na(cl$sleep_score[1]) && is.na(cl$hrv_night[1]))
  expect_equal(cl$sleep_h[2:6], rep(7, 5))
  expect_true(is.na(cl$resting_hr[2])); expect_equal(cl$resting_hr[-2], rep(54, 5))
  expect_equal(cl$steps, d$steps)
  expect_equal(cl$bb_high, d$bb_high)                      # nur auf Wunsch (extra_cols) maskiert
  expect_true(all(c("sleep_bad", "rhr_bad", "partial") %in% names(cl)))
})

test_that("clean_daily maskiert zusätzliche Spalten über extra_cols", {
  d <- mk_daily(sleep_h = c(4, 7, 7, 7, 7, 7))
  cl <- clean_daily(d, extra_cols = c("bb_high", "ready_score", "gibt_es_nicht"), today = today)
  expect_true(is.na(cl$bb_high[1]) && is.na(cl$ready_score[1]))
  expect_equal(cl$bb_high[-1], rep(80, 5))
})

test_that("Unvollständige Tage zählen nicht in den ACWR, ihre Last bleibt sichtbar", {
  n <- 40; days <- Sys.Date() - (n - 1):0
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80)
  acts <- function(last_trimp) tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"),
                                      trimp = c(rep(50, n - 1), last_trimp), est = FALSE,
                                      te_aerobic = NA_real_, type_key = "cycling")
  low  <- daily_load_recovery(daily, acts(50))
  high <- daily_load_recovery(daily, acts(500))           # letzter Tag = heute = unvollständig
  expect_equal(tail(high$acwr, 1), tail(low$acwr, 1))
  expect_equal(tail(high$load_meas, 1), 500)
  expect_true(tail(high$partial, 1))
})
