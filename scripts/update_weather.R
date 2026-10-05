#!/usr/bin/env Rscript
# Tagestemperaturen für den Wohnort nachladen (data/weather.csv), ohne Garmin-Abruf.
# Aufruf (aus dem Projektordner):  Rscript scripts/update_weather.R
suppressPackageStartupMessages({ library(here); library(dplyr); library(readr); library(tibble) })
source(here("scripts", "helpers.R")); source(here("scripts", "weather.R"))
daily <- read_csv(here("data", "garmin_daily.csv"), show_col_types = FALSE, col_types = cols(date = col_date(), .default = col_guess()))
w <- update_weather_env(min(daily$date))
message(sprintf("Wetterdaten %s: %d Tage (%s bis %s)", weather_place()$place, nrow(w), format(min(w$date)), format(max(w$date))))
