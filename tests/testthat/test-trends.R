source(here::here("scripts", "helpers.R"))

TODAY <- as.Date("2026-10-05")                                   # Montag; letzte vollständige Woche endet am 04.10.
# 18 Wochen Tageswerte (Mo 01.06. bis So 04.10.), Wochenindex 0, 1, ... als Zeitachse
mk_tr <- function(slope = 0, base = 56, sd = 0.4, seed = 1, n_days = 126, fun = identity) {
  set.seed(seed)
  date <- as.Date("2026-06-01") + 0:(n_days - 1)
  wk <- as.numeric(date - as.Date("2026-06-01")) / 7
  tibble(date = date, steps = 8000, sleep_h = 7,
         resting_hr = base + slope * wk + rnorm(n_days, 0, sd),
         hrv_night = fun(40 + 0 * wk + rnorm(n_days, 0, 0.1)), sleep_hr = 50 + rnorm(n_days, 0, sd))
}
tr_of <- function(res, m) res$trend[res$trend$metric == m, ]

test_that("adaptation_trends findet eine bekannte Steigung des Ruhepulses", {
  r <- tr_of(adaptation_trends(mk_tr(slope = -0.2), today = TODAY), "resting_hr")
  expect_equal(r$slope, -0.2, tolerance = 0.2)
  expect_true(r$lo < -0.2 && -0.2 < r$hi)
  expect_equal(r$verdict, "fallend"); expect_equal(r$n_weeks, 12); expect_equal(r$slope_unit, "bpm/Woche")
})

test_that("adaptation_trends meldet bei flacher Reihe keinen klaren Trend", {
  r <- tr_of(adaptation_trends(mk_tr(slope = 0, sd = 1, seed = 7), today = TODAY), "resting_hr")
  expect_true(r$lo < 0 && 0 < r$hi); expect_equal(r$verdict, "kein klarer Trend")
})

test_that("adaptation_trends: Wochen mit zu wenigen gültigen Tagen entfallen", {
  d <- mk_tr(); wk <- as.Date("2026-09-14")                     # Woche im Fenster: nur 3 gültige Tage
  d$resting_hr[d$date >= wk & d$date < wk + 4] <- NA
  res <- adaptation_trends(d, today = TODAY)
  expect_equal(tr_of(res, "resting_hr")$n_weeks, 11)
  expect_false(wk %in% res$weekly$week[res$weekly$metric == "resting_hr"])
})

test_that("adaptation_trends: Ruhepuls-Artefakte (unter Schwelle) zählen nicht als gültige Tage", {
  d <- mk_tr(); wk <- as.Date("2026-09-14")
  d$resting_hr[d$date >= wk & d$date < wk + 4] <- 38           # Artefakt statt NA
  expect_equal(tr_of(adaptation_trends(d, today = TODAY), "resting_hr")$n_weeks, 11)
})

test_that("adaptation_trends: unvollständige letzte Woche entfällt", {
  d <- mk_tr(n_days = 124)                                      # Daten bis Freitag 02.10.
  res <- adaptation_trends(d, today = TODAY)
  expect_equal(max(res$weekly$week), as.Date("2026-09-21"))
})

test_that("adaptation_trends: überwiegend annotierte Wochen entfallen, knapp darunter bleiben sie", {
  d <- mk_tr(); d$ann_note <- NA_character_
  d$ann_note[d$date >= as.Date("2026-09-14") & d$date < as.Date("2026-09-18")] <- "Segeln"   # 4 von 7
  d$ann_note[d$date >= as.Date("2026-09-21") & d$date < as.Date("2026-09-24")] <- "Segeln"   # 3 von 7
  res <- adaptation_trends(d, today = TODAY); w <- res$weekly$week[res$weekly$metric == "resting_hr"]
  expect_false(as.Date("2026-09-14") %in% w); expect_true(as.Date("2026-09-21") %in% w)
})

test_that("adaptation_trends: unter 6 Wochen kein Trend", {
  d <- mk_tr(n_days = 126); d <- d[d$date >= as.Date("2026-08-31"), ]    # 5 Wochen
  r <- tr_of(adaptation_trends(d, today = TODAY), "resting_hr")
  expect_true(is.na(r$slope)); expect_equal(r$verdict, "zu wenig Daten"); expect_equal(r$n_weeks, 5)
})

test_that("adaptation_trends: HRV wird logarithmisch gefittet, Steigung in Prozent je Woche", {
  d <- mk_tr(); wk <- as.numeric(d$date - as.Date("2026-06-01")) / 7
  d$hrv_night <- 40 * 1.01^wk * exp(rnorm(nrow(d), 0, 0.02))
  r <- tr_of(adaptation_trends(d, today = TODAY), "hrv_night")
  expect_equal(r$slope, 1, tolerance = 0.15); expect_equal(r$slope_unit, "%/Woche")
  expect_equal(r$verdict, "steigend")
  w <- adaptation_trends(d, today = TODAY)$weekly; w <- w[w$metric == "hrv_night", ]
  expect_true(all(w$value > 30 & w$value < 60))                 # Wochenwerte in ms (Rücktransformation)
})

test_that("adaptation_trends: Wochenwert ist das Mittel der gültigen Tage", {
  d <- mk_tr(); res <- adaptation_trends(d, today = TODAY)
  w <- res$weekly[res$weekly$metric == "resting_hr" & res$weekly$week == as.Date("2026-09-28"), ]
  expect_equal(w$value, mean(d$resting_hr[d$date >= as.Date("2026-09-28") & d$date <= as.Date("2026-10-04")]))
  expect_equal(w$n_days, 7)
})

test_that("adaptation_trends: fehlende Spalten und leere Daten lassen den Lauf nicht abbrechen", {
  d <- mk_tr()[, c("date", "steps", "resting_hr")]
  res <- adaptation_trends(d, today = TODAY)
  expect_equal(res$trend$metric, "resting_hr")
  e <- adaptation_trends(d[0, ], today = TODAY)
  expect_equal(nrow(e$trend), 0); expect_equal(nrow(e$weekly), 0)
})
