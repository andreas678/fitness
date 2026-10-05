source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

# Vier Signal-z-Werte, so ausgerichtet, dass niedriger = schlechter
zmat <- function(n = 4000, rho = 0, seed = 3) {
  set.seed(seed)
  g <- rnorm(n); e <- matrix(rnorm(n * 4), n, 4)
  sqrt(rho) * g + sqrt(1 - rho) * e                       # paarweise Korrelation rho
}

test_that("effective_signals: identische Signale zählen einfach, unabhängige vierfach", {
  expect_equal(effective_signals(zmat(rho = 1)), 1, tolerance = 0.01)
  expect_equal(effective_signals(zmat(rho = 0)), 4, tolerance = 0.15)
  expect_equal(effective_signals(zmat(rho = 0.5)), 16 / (4 + 12 * 0.5), tolerance = 0.15)   # 1,6
})

test_that("recovery_index: Mittel der Signale, auf Standardabweichung 1 skaliert", {
  z <- zmat(rho = 0.4)
  r <- recovery_index(z)
  expect_equal(sd(r$index), 1, tolerance = 1e-8)
  expect_equal(unname(r$index), unname(rowMeans(z) / sd(rowMeans(z))), tolerance = 1e-8)
  expect_equal(r$n_eff, effective_signals(z))
})

test_that("recovery_index: gleiche Abweichung zählt bei redundanten Signalen weniger", {
  day <- matrix(-1.5, 1, 4)                                # alle vier Signale bei -1,5
  ind <- recovery_index(rbind(zmat(rho = 0), day))$index
  red <- recovery_index(rbind(zmat(rho = 0.9), day))$index
  expect_lt(tail(ind, 1), -2.5)                            # unabhängig: sehr ungewöhnlich
  expect_gt(tail(red, 1), -1.8)                            # fast identisch: kaum mehr als ein Signal
})

test_that("recovery_index braucht mindestens 3 von 4 Signalen", {
  z <- zmat(200); z[1, 1:2] <- NA; z[2, 1] <- NA
  r <- recovery_index(z)$index
  expect_true(is.na(r[1])); expect_false(is.na(r[2]))
})

test_that("recovery_index kommt mit zu wenigen Daten zurecht", {
  r <- recovery_index(matrix(NA_real_, 5, 4))
  expect_true(all(is.na(r$index))); expect_true(is.na(r$n_eff))
})

test_that("HRV-z wird auf der ln-Skala gebildet", {
  n <- 60; days <- as.Date("2026-06-01") + 0:(n - 1)
  hrv <- 40 * exp(0.25 * sin(seq_len(n) / 3))              # multiplikative Schwankung, rechtsschief
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80, hrv_night = hrv)
  acts <- tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  dl <- daily_load_recovery(daily, acts)
  lg <- log(hrv); m <- roll_apply(lg, days, 28, mean, 14, lag_by = 1); s <- roll_apply(lg, days, 28, sd, 14, lag_by = 1)
  expect_equal(dl$hrv_z, (lg - m) / s)
})

test_that("daily_load_recovery liefert Index, Schwellenmarke und Redundanz-Kennzahl", {
  set.seed(5); n <- 120; days <- as.Date("2026-03-01") + 0:(n - 1)
  daily <- tibble(date = days, steps = 8000, resting_hr = 54 + rnorm(n), sleep_h = 7, sleep_score = 80 + 5 * rnorm(n),
                  bb_high = 80 + 5 * rnorm(n), hrv_night = 40 * exp(0.1 * rnorm(n)))
  acts <- tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  dl <- daily_load_recovery(daily, acts)
  expect_true(all(c("rec_index", "rec_low") %in% names(dl)))
  expect_equal(dl$rec_low, coalesce(dl$rec_index <= REC_INDEX_THRESHOLD, FALSE))
  info <- attr(dl, "rec_index_info")
  expect_true(info$n_eff > 3 && info$n_eff <= 4)           # unabhängiges Rauschen: fast vier eigenständige Signale
})
