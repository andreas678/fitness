source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

ok <- function(n) rep(TRUE, n)

test_that("fitness_fatigue: konstante Last führt zu CTL = ATL = Last und Form 0", {
  r <- fitness_fatigue(rep(50, 600), ok(600), init_days = 0)
  expect_equal(tail(r$ctl, 1), 50, tolerance = 1e-3)
  expect_equal(tail(r$atl, 1), 50, tolerance = 1e-8)
  expect_equal(tail(r$tsb, 1), 0, tolerance = 1e-3)
})

test_that("fitness_fatigue: Sprungantwort erreicht nach tau Tagen 1 - exp(-1) der Last", {
  r <- fitness_fatigue(rep(100, 60), ok(60), init_days = 0)
  expect_equal(r$atl[7],  100 * (1 - exp(-1)), tolerance = 1e-8)
  expect_equal(r$ctl[42], 100 * (1 - exp(-1)), tolerance = 1e-8)
})

test_that("fitness_fatigue: Form eines Tages nutzt die Werte vom Vortag", {
  set.seed(2); L <- runif(80, 0, 120)
  r <- fitness_fatigue(L, ok(80), init_days = 0)
  expect_equal(r$tsb[-1], r$ctl[-80] - r$atl[-80])
  expect_equal(r$tsb[1], 0)                                  # kein Vortag: Startzustand
})

test_that("fitness_fatigue: unbekannte Tage frieren den Zustand ein und werden markiert", {
  L <- rep(60, 100); usable <- ok(100); usable[41:60] <- FALSE; L[41:60] <- NA
  r <- fitness_fatigue(L, usable, init_days = 0)
  expect_true(all(r$pmc_gap[41:60])); expect_false(any(r$pmc_gap[-(41:60)]))
  expect_equal(r$ctl[41:60], rep(r$ctl[40], 20)); expect_equal(r$atl[41:60], rep(r$atl[40], 20))
  expect_false(anyNA(r$ctl))
  expect_gt(r$ctl[61], r$ctl[40])                            # danach läuft die Rechnung weiter
})

test_that("fitness_fatigue: unbrauchbare Tage zählen auch mit vorhandener Last nicht (unvollständiger Tag)", {
  L <- rep(60, 50); usable <- ok(50); usable[50] <- FALSE; L[50] <- 500
  r <- fitness_fatigue(L, usable, init_days = 0)
  expect_equal(r$atl[50], r$atl[49])
})

test_that("fitness_fatigue: Start beim Mittel der ersten Tage, Einschwingphase markiert", {
  r <- fitness_fatigue(rep(50, 120), ok(120), init_days = 14)
  expect_equal(r$ctl[1], 50); expect_equal(r$atl[1], 50)
  expect_equal(r$ctl, rep(50, 120))
  expect_equal(which(r$pmc_warmup), 1:42)
})

test_that("fitness_fatigue: ohne nutzbare Tage nur NA, ohne Absturz", {
  r <- fitness_fatigue(rep(NA_real_, 10), rep(FALSE, 10))
  expect_true(all(is.na(r$ctl))); expect_true(all(r$pmc_gap))
  expect_equal(nrow(fitness_fatigue(numeric(0), logical(0))), 0)
})

test_that("fitness_fatigue: ohne Lücken keine NA", {
  r <- fitness_fatigue(c(0, 80, 0, 0, 120, 40), ok(6), init_days = 0)
  expect_false(anyNA(r))
})

test_that("pmc_sensitivity: ohne Lücken sind alle Varianten gleich, mit Lücke ist die Spannweite sichtbar", {
  L <- rep(60, 120); u <- ok(120)
  s0 <- pmc_sensitivity(L, u)
  expect_equal(s0$variante, c("einfrieren", "Median auffüllen", "0 setzen"))
  expect_equal(diff(range(s0$ctl)), 0, tolerance = 1e-8)
  L[60:110] <- NA; u[60:110] <- FALSE
  s1 <- pmc_sensitivity(L, u)
  expect_lt(s1$ctl[s1$variante == "0 setzen"], s1$ctl[s1$variante == "Median auffüllen"])
  expect_gt(diff(range(s1$ctl)), 1)
})

test_that("daily_load_recovery liefert ctl/atl/tsb und markiert unbekannte Last", {
  n <- 120; days <- as.Date("2026-03-01") + 0:(n - 1)
  daily <- tibble(date = days, steps = 8000, resting_hr = 54, sleep_h = 7, sleep_score = 80, bb_high = 80,
                  ann_load_unknown = days >= as.Date("2026-04-10") & days <= as.Date("2026-04-30"))
  acts <- tibble(start = as.POSIXct(paste(days, "08:00:00"), tz = "UTC"), trimp = 50, est = FALSE,
                 te_aerobic = NA_real_, type_key = "cycling")
  dl <- daily_load_recovery(daily, acts)
  expect_true(all(c("ctl", "atl", "tsb", "pmc_gap", "pmc_warmup") %in% names(dl)))
  gap <- days >= as.Date("2026-04-10") & days <= as.Date("2026-04-30")
  expect_true(all(dl$pmc_gap[gap]))
  expect_false(any(dl$pmc_gap[!gap]))
  expect_false(anyNA(dl$ctl))
})
