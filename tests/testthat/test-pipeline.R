source(here::here("scripts", "helpers.R"))
source(here::here("scripts", "load_recovery.R"))

today <- as.Date("2026-10-05")
mk_cache <- function(n = 10, ...) {
  tibble(date = today - (n + 1):2, steps = 8000, sleep_h = 7, fx_stats = TRUE, fx_sleep = TRUE,
         fx_hrv = TRUE, fx_ready = TRUE, fx_status = TRUE) |> mutate(...)
}

# ---- Nachlade-Regel ---------------------------------------------------------------------------
test_that("days_to_fetch lädt ohne Cache alles", {
  w <- days_to_fetch(NULL, today, days_back = 5)
  expect_equal(w, seq(today - 5, today, by = "day"))
})

test_that("days_to_fetch lädt fehlende Tage sowie heute und gestern", {
  old <- mk_cache(10)                                         # Tage today-11 .. today-2
  todo <- days_to_fetch(old, today, days_back = 11)
  expect_true(all(c(today - 1, today) %in% todo))
  expect_false(any(old$date %in% todo))                       # vollständige Tage bleiben im Cache
})

test_that("days_to_fetch holt Tage mit gescheitertem Teilaufruf nach, aber nicht echte 'keine Daten'-Tage", {
  old <- mk_cache(10)
  old$fx_sleep[3] <- FALSE                                    # Aufruf gescheitert
  old$sleep_h[5] <- NA                                        # Garmin hatte keine Schlafdaten (Aufruf gelungen)
  todo <- days_to_fetch(old, today, days_back = 11)
  expect_true(old$date[3] %in% todo)
  expect_false(old$date[5] %in% todo)
})

test_that("days_to_fetch behandelt alte Caches ohne fx-Spalten: nur junge Tage ohne Schlaf nachladen", {
  old <- mk_cache(30) |> select(-starts_with("fx_"))
  old$sleep_h[old$date == today - 5] <- NA                    # jung, ohne Schlaf: nachladen
  old$sleep_h[old$date == today - 25] <- NA                   # alt: bleibt
  todo <- days_to_fetch(old, today, days_back = 31)
  expect_true((today - 5) %in% todo); expect_false((today - 25) %in% todo)
})

test_that("days_to_fetch: Tag ohne Schritte, aber gelungenem Statistik-Aufruf, wird nicht dauernd neu geholt", {
  old <- mk_cache(10)
  old$steps[4] <- NA                                          # Uhr hat nichts aufgezeichnet, Aufruf gelang (fx_stats = TRUE)
  expect_false(old$date[4] %in% days_to_fetch(old, today, days_back = 11))
  old$fx_stats[4] <- NA                                       # Altbestand: unbekannt, ob Aufruf gelang
  expect_true(old$date[4] %in% days_to_fetch(old, today, days_back = 11))
  old$fx_stats[4] <- FALSE                                    # Aufruf gescheitert
  expect_true(old$date[4] %in% days_to_fetch(old, today, days_back = 11))
})

test_that("days_to_fetch: Tage mit fx=NA (Altbestand) gelten nicht als gescheitert", {
  old <- mk_cache(10); old$fx_sleep[3] <- NA
  expect_false(old$date[3] %in% days_to_fetch(old, today, days_back = 11))
})

# ---- Plausibilitätsprüfung --------------------------------------------------------------------
test_that("validate_daily findet Lücken, Dubletten und unmögliche Werte", {
  d <- tibble(date = today - 9:0, steps = 5000, resting_hr = 54, sleep_h = 7)
  expect_equal(sum(validate_daily(d)$n), 0)
  d2 <- d[-5, ]; d2$steps[1] <- -1; d2$resting_hr[2] <- 150; d2$sleep_h[3] <- 20
  d2 <- bind_rows(d2, d2[1, ])
  v <- validate_daily(d2)
  expect_equal(v$n[v$check == "Datumslücken"], 1)
  expect_equal(v$n[v$check == "doppelte Tage"], 1)
  expect_gte(v$n[v$check == "Schritte < 0"], 1)
  expect_equal(v$n[v$check == "Ruhepuls außerhalb 30-100"], 1)
  expect_equal(v$n[v$check == "Schlaf außerhalb 0-16 h"], 1)
})

test_that("validate_daily kommt mit fehlenden Spalten zurecht", {
  expect_equal(sum(validate_daily(tibble(date = today - 2:0, steps = 1))$n), 0)
})

test_that("validate_acts findet Dubletten und unmögliche Werte", {
  a <- tibble(activity_id = c("1", "2", "2"), start = as.POSIXct("2026-01-01 08:00:00", tz = "UTC"),
              duration_min = c(30, -5, 30), avg_hr = c(120, 120, 250), max_hr = c(150, 110, 260), distance_km = c(5, 1, -1))
  v <- validate_acts(a)
  expect_equal(v$n[v$check == "doppelte activity_id"], 1)
  expect_equal(v$n[v$check == "Dauer <= 0 oder > 24 h"], 1)
  expect_equal(v$n[v$check == "Puls außerhalb 30-230"], 1)
  expect_equal(v$n[v$check == "max_hr < avg_hr"], 1)
  expect_equal(v$n[v$check == "Strecke < 0"], 1)
  expect_equal(sum(validate_acts(a[1, ])$n), 0)
})

test_that("report_validation meldet nur Auffälligkeiten", {
  expect_message(report_validation(tibble(check = "x", n = 0, example = ""), "Tageswerte"), "keine Auffälligkeiten")
  expect_message(report_validation(tibble(check = "x", n = 2, example = "a"), "Tageswerte"), "2")
})

# ---- Feste Referenzwerte ----------------------------------------------------------------------
test_that("resolve_rhr_ref: Umgebungsvariable vor gespeichertem Wert vor Neuberechnung", {
  r <- resolve_rhr_ref(list(rhr_ref = 54), candidate = 56, env = 50)
  expect_equal(r$value, 50); expect_false(r$save)
  r <- resolve_rhr_ref(list(rhr_ref = 54), candidate = 56, env = NA)
  expect_equal(r$value, 54); expect_equal(r$source, "gespeichert"); expect_false(r$save)
  r <- resolve_rhr_ref(list(), candidate = 56, env = NA)
  expect_equal(r$value, 56); expect_true(r$save)
  r <- resolve_rhr_ref(list(rhr_ref = 54), candidate = 56, env = NA, recalc = TRUE)
  expect_equal(r$value, 56); expect_true(r$save)
})

rides <- bind_rows(lapply(1:6, function(i) tibble(type_key = "cycling", avg_hr = 100 + 4 * i)))   # Median 114
p192 <- list(rhr_ref = 54, hrmax = 192, trimp_b = 1.92)
p182 <- list(rhr_ref = 54, hrmax = 182, trimp_b = 1.92)

test_that("resolve_commute speichert den Puls in bpm und rechnet die HFR mit dem aktuellen HFmax", {
  first <- resolve_commute(list(), rides, p192)
  expect_true(first$save); expect_equal(first$hr, 114); expect_equal(first$source, "abgeleitet")
  ref <- list(commute_hr = first$hr, commute_hr_lo = first$hr_lo, commute_hr_hi = first$hr_hi, commute_n = first$n)
  again <- resolve_commute(ref, rides[1:2, ], p182)           # andere Daten, anderer HFmax
  expect_false(again$save); expect_equal(again$source, "gespeichert")
  expect_equal(again$hr, 114)                                 # Puls bleibt fest
  expect_equal(again$value, round((114 - 54) / (182 - 54), 2))   # HFR folgt dem neuen HFmax
  expect_equal(first$value, round((114 - 54) / (192 - 54), 2))
})

test_that("resolve_commute ohne genug Fahrten: Annahme, nichts speichern; recalc überschreibt", {
  few <- resolve_commute(list(), rides[1:3, ], p192)
  expect_equal(few$source, "Annahme"); expect_equal(few$value, 0.40); expect_false(few$save)
  ref <- list(commute_hr = 100, commute_n = 6)
  expect_equal(resolve_commute(ref, rides, p192, recalc = TRUE)$hr, 114)
})

test_that("read_ref/write_ref: Rundlauf und fehlende oder kaputte Datei", {
  f <- tempfile(fileext = ".json")
  expect_equal(read_ref(f), list())
  write_ref(list(rhr_ref = 54, note = "x"), f)
  expect_equal(read_ref(f)$rhr_ref, 54)
  writeLines("{kaputt", f); expect_equal(read_ref(f), list())
})
