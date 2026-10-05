source(here::here("scripts", "helpers.R"))

mk_w <- function(n = 40, slope = -0.01, sd = 0.8, seed = 1) {
  set.seed(seed)
  day <- sort(sample(0:180, n))
  tibble(date = as.Date("2026-04-01") + day, weight_kg = 91 + slope * day + rnorm(n, 0, sd))
}

test_that("weight_trend liefert keinen Trend bei zu wenigen Wiegungen", {
  expect_null(weight_trend(mk_w(7)))
  expect_null(weight_trend(tibble(date = as.Date(character()), weight_kg = numeric())))
})

test_that("weight_trend extrapoliert nicht und hat ein plausibles Band", {
  w <- mk_w(); tr <- weight_trend(w)
  expect_equal(range(tr$date), range(w$date))
  expect_equal(nrow(tr), as.integer(diff(range(w$date))) + 1)
  expect_true(all(tr$lo < tr$fit & tr$fit < tr$hi))
  expect_true(all(tr$fit > min(w$weight_kg) - 1 & tr$fit < max(w$weight_kg) + 1))
})

test_that("weight_trend folgt dem wahren Verlauf besser als die Einzelwerte streuen", {
  w <- mk_w(60, slope = -0.02, sd = 0.9, seed = 4); tr <- weight_trend(w)
  truth <- 91 - 0.02 * as.numeric(tr$date - as.Date("2026-04-01"))
  expect_lt(mean(abs(tr$fit - truth)), 0.5)          # Trend näher am Verlauf als die Tagesstreuung (0,9)
})

test_that("weight_trend: mehrere Wiegungen am selben Tag werden gemittelt", {
  w <- mk_w(20); w2 <- bind_rows(w, mutate(w[1, ], weight_kg = weight_kg + 0.4))
  expect_equal(nrow(weight_trend(w2)), nrow(weight_trend(w)))
})
