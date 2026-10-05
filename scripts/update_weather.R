#!/usr/bin/env Rscript
# Tagestemperaturen für den Wohnort nachladen (data/weather.csv), ohne Garmin-Abruf.
# Aufruf (aus dem Projektordner):  Rscript scripts/update_weather.R
suppressPackageStartupMessages({ library(here); library(dplyr); library(readr); library(tibble) })
source(here("scripts", "helpers.R")); source(here("scripts", "weather.R"))
daily <- read_daily_cache()
if (is.null(daily)) stop("data/garmin_daily.csv fehlt: erst Rscript scripts/garmin_fitness.R ausführen.")
w <- update_weather_env(min(daily$date))
message(sprintf("Wetterdaten %s: %d Tage (%s bis %s)", weather_place()$place, nrow(w), format(min(w$date)), format(max(w$date))))
