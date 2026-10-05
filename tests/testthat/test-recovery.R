source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

# Simulierte Tageswerte mit bekanntem Effekt: Der Schlaf-Score der Nacht NACH einem HIIT-Tag ist um
# `effect` niedriger. HIIT liegt bewusst auf wenigen Wochentagen (wie in den echten Daten), und der
# Wochentag der Messung hat einen eigenen Effekt: roher Vergleich verzerrt, adjustierter nicht.
sim_daily <- function(n = 360, effect = -5, seed = 1) {
  set.seed(seed)
  date <- as.Date("2026-01-05") + 0:(n - 1)                        # 2026-01-05 = Montag
  wd   <- as.integer(format(date, "%u"))
  p_h  <- c(`1` = 0.95, `2` = 0.02, `3` = 0.5, `4` = 0.02, `5` = 0.5, `6` = 0.02, `7` = 0.02)[as.character(wd)]
  hiit <- runif(n) < p_h
  wd_eff <- c(`1` = 0, `2` = 6, `3` = 0, `4` = 2, `5` = 0, `6` = 8, `7` = 3)   # Effekt des Messtags
  noise <- as.numeric(arima.sim(list(ar = 0.5), n))
  score <- 80 + wd_eff[as.character(wd)] + 2 * noise
  score[-1] <- score[-1] + effect * hiit[-n]                       # Nacht nach dem HIIT-Tag
  tibble(date = date, hiit = hiit, unrecorded = FALSE, steps = 8000, resting_hr = 54, sleep_h = 7,
         sleep_score = as.numeric(score))
}

test_that("recovery_data stellt Folgetag-Werte und den Messwochentag bereit", {
  x <- recovery_data(sim_daily(60))
  expect_true(all(c("date", "hiit", "wd", "sleep_score_n") %in% names(x)))
  expect_equal(as.integer(as.character(x$wd[1])), as.integer(format(x$date[1] + 1, "%u")))   # Messtag = Tag nach HIIT-Tag
})

test_that("recovery_model schätzt den wahren Effekt nach Adjustierung für den Wochentag", {
  x   <- recovery_data(sim_daily())
  res <- recovery_model(x)
  r   <- res[res$metric == "Schlaf-Score", ]
  raw_bias <- abs(r$diff - (-5))
  expect_gt(raw_bias, 1.5)                                       # roher Vergleich ist durch den Wochentag verzerrt
  expect_lt(abs(r$adj_diff - (-5)), 1.5)                         # adjustiert nahe dem wahren Effekt
  expect_true(r$ci_lo < -5 && -5 < r$ci_hi)                      # Konfidenzintervall deckt den wahren Wert
  expect_lt(r$p, 0.01); expect_lt(r$p_holm, 0.05)
  expect_lt(r$d, 0)                                              # standardisierte Effektgröße, gleiche Richtung
})

test_that("Ohne Effekt liegt das Konfidenzintervall um Null", {
  res <- recovery_model(recovery_data(sim_daily(effect = 0, seed = 3)))
  r <- res[res$metric == "Schlaf-Score", ]
  expect_true(r$ci_lo < 0 && 0 < r$ci_hi)
})

test_that("Training Readiness gilt als nicht unabhängig und fließt nicht in die Holm-Korrektur", {
  d <- sim_daily(); d$ready_score <- d$sleep_score; d$deep_h <- rnorm(nrow(d))
  res <- recovery_model(recovery_data(d))
  rd <- res[res$metric == "Training Readiness", ]
  expect_false(rd$independent); expect_true(is.na(rd$p_holm))
  ind <- res[res$independent, ]
  expect_equal(ind$p_holm, p.adjust(ind$p, "holm"))
  expect_true(all(ind$p_holm >= ind$p))
})

test_that("Metriken mit zu wenig Beobachtungen entfallen", {
  d <- sim_daily(); d$hrv_night <- NA_real_
  res <- recovery_model(recovery_data(d))
  expect_false("HRV nachts (ms)" %in% res$metric)
})

test_that("recovery_design zeigt, auf welchen Messwochentagen beide Gruppen vorkommen", {
  des <- recovery_design(recovery_data(sim_daily()))
  expect_equal(nrow(des), 7)
  expect_equal(sum(des$n_hiit) + sum(des$n_other), nrow(recovery_data(sim_daily())))
  # HIIT fast nur Mo/Mi/Fr: Messtag Do (nach Mi) und Sa (nach Fr) haben HIIT UND Vergleichstage,
  # Messtag Di (nach Mo, 95 % HIIT) hat kaum Vergleichstage, Messtag Mo/Mi/So kaum HIIT-Folgetage
  expect_true(all(des$both[des$wd %in% c(4, 6)]))
  expect_false(any(des$both[des$wd %in% c(1, 2, 3, 7)]))
})

test_that("Sensitivität nur auf Wochentagen mit beiden Gruppen liefert ein eigenes Ergebnis", {
  res <- recovery_model(recovery_data(sim_daily()))
  r <- res[res$metric == "Schlaf-Score", ]
  expect_true(all(c("r_diff", "r_lo", "r_hi") %in% names(r)))
  expect_false(is.na(r$r_diff))
})

test_that("recovery_model setzt den globalen Zufallszahlen-Zustand nicht zurück", {
  set.seed(123); a <- runif(1)
  set.seed(123); invisible(recovery_model(recovery_data(sim_daily(seed = 9)))); b <- runif(1)
  # sim_daily nutzt set.seed selbst; geprüft wird nur, dass recovery_model keinen Seed setzt
  expect_false(any(grepl("set.seed", deparse(body(recovery_model)))))
  expect_false(any(grepl("set.seed", deparse(body(recovery_data)))))
})

# ---- Annotierte Tage ---------------------------------------------------------------------------
test_that("recovery_data schließt Zeilen aus, deren Messtag annotiert ist", {
  d <- sim_daily(60)
  d$ann_note <- NA_character_
  ann_days <- as.Date("2026-02-10") + 0:2                                      # Messtage 10.-12.2.
  d$ann_note[d$date %in% ann_days] <- "Segeltörn"
  x <- recovery_data(d)
  expect_false(any((x$date + 1) %in% ann_days))                                # keine Zeile mit annotiertem Messtag
  expect_false(as.Date("2026-02-09") %in% x$date)                              # Trainingstag 9.2.: Messtag 10.2. ist annotiert
  expect_true(as.Date("2026-02-12") %in% x$date)                               # Trainingstag 12.2.: Messtag 13.2. gewöhnlich, Zeile bleibt
  # genau drei Zeilen weniger als ohne Annotation
  expect_equal(nrow(recovery_data(sim_daily(60))) - nrow(x), 3)
})

test_that("recovery_data: ohne ann_note-Spalte oder ohne annotierte Tage bleibt alles wie bisher", {
  d <- sim_daily(60); x0 <- recovery_data(d)
  d$ann_note <- NA_character_
  expect_equal(recovery_data(d), x0)
  expect_false("ann_n" %in% names(x0))                                         # Hilfsspalte wird nicht ausgegeben
})

test_that("recovery_data: ein annotierter Trainingstag mit bekannter Last bleibt, seine Folgenacht zählt", {
  d <- sim_daily(60); d$ann_note <- NA_character_
  d$ann_note[d$date == as.Date("2026-02-10")] <- "Nachtwache"                  # nur dieser Tag annotiert, Last bekannt
  x <- recovery_data(d)
  expect_true(as.Date("2026-02-10") %in% x$date)                               # Trainingstag annotiert, Messtag (11.2.) nicht
  expect_false(as.Date("2026-02-09") %in% x$date)                              # Messtag 10.2. ist annotiert
})
