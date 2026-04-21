#!/usr/bin/env Rscript
## resourcetracker -- end-to-end pipeline
##
## Per-commodity quarterly physical-tonnage nowcast (iron_ore, coal) from:
##   - IMF PortWatch daily AIS tonnage           (RHS indicator)
##   - DISR Resources & Energy Quarterly Table 16 (LHS target, Mt)
##
## Usage:
##   Rscript run.R              # normal run, skip steps whose rds is up-to-date
##   Rscript run.R --force      # force rerun of every step
##   Rscript run.R --no-report  # skip the briefing HTML render

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
  library(tidyr)
  library(readr)
  library(fs)
  library(stringr)
  library(lubridate)
  library(purrr)
})

R_FILES <- sort(list.files("R", pattern = "\\.R$", full.names = TRUE))
for (f in R_FILES) source(f, local = FALSE)

cfg <- load_config("config.R")
init_logger(cfg)
warehouse_init_schema(cfg)

args <- commandArgs(trailingOnly = TRUE)
FORCE       <- "--force"     %in% args
SKIP_REPORT <- "--no-report" %in% args

# --- skip-if-up-to-date helpers --------------------------------------------
#
# `.CODE_DEPS` (all R/ sources + config.R) invalidates derived steps.
# `.INGEST_DEPS` is just config.R — ingest steps are expensive network
# fetches; we don't want them invalidated by arbitrary R-source edits.

.CODE_DEPS   <- c(R_FILES, "config.R")
.INGEST_DEPS <- "config.R"

.step_cached <- function(out_path, deps, include_code = TRUE) {
  base_deps <- if (include_code) .CODE_DEPS else .INGEST_DEPS
  all_deps  <- unique(c(deps, base_deps))
  existing  <- all_deps[fs::file_exists(all_deps)]
  if (!fs::file_exists(out_path) || length(existing) == 0L) return(FALSE)
  out_mtime <- as.numeric(fs::file_info(out_path)$modification_time)
  dep_mtime <- max(as.numeric(fs::file_info(existing)$modification_time))
  out_mtime > dep_mtime
}

run_step <- function(name, fn, deps = character(0), force = FORCE,
                     is_ingest = FALSE) {
  out_path <- wh_path(name, cfg)
  if (!force && .step_cached(out_path, deps, include_code = !is_ingest)) {
    log_info("skip %-34s (cached)", name)
    return(wh_read(name, cfg))
  }
  log_info("run  %-34s ...", name)
  t0 <- Sys.time()
  result <- fn()
  dur <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  log_info("done %-34s [%5.1fs]", name, dur)
  if (is.data.frame(result) && !fs::file_exists(out_path)) {
    wh_write(name, result, cfg)
  }
  result
}

run_step_rds <- function(name, fn, deps = character(0), force = FORCE,
                         is_ingest = FALSE) {
  out_path <- wh_path(name, cfg)
  if (!force && .step_cached(out_path, deps, include_code = !is_ingest)) {
    log_info("skip %-34s (cached)", name)
    return(readRDS(out_path))
  }
  log_info("run  %-34s ...", name)
  t0 <- Sys.time()
  result <- fn()
  dur <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  log_info("done %-34s [%5.1fs]", name, dur)
  if (!is.null(result)) saveRDS(result, out_path, compress = "xz")
  result
}

# --- pipeline --------------------------------------------------------------

ports_meta <- run_step("mart_dim_port",
  function() load_ports_metadata(cfg),
  deps = cfg$paths$ports_metadata)

raw_portwatch <- run_step("raw_portwatch_tonnage_daily",
  function() fetch_portwatch_tonnage(cfg, cfg$paths$warehouse_dir),
  is_ingest = TRUE)

raw_disr <- run_step("raw_disr_req_quarterly",
  function() fetch_disr_req(cfg, cfg$paths$warehouse_dir),
  is_ingest = TRUE)

features <- run_step("derived_features",
  function() build_features(raw_portwatch, raw_disr, cfg),
  deps = c(wh_path("raw_portwatch_tonnage_daily", cfg),
           wh_path("raw_disr_req_quarterly",     cfg)))

# Live-nowcast bridge: fit on every training quarter we have, up to the
# latest DISR-published observation. (Backtest fits use an expanding-
# window `train_end` of their own via `backtest_one_quarter`; the config
# `train_end` is ignored there.)
cfg_live <- cfg
if (nrow(features) > 0L) {
  cfg_live$sample$train_end <- as.character(max(features$quarter_end))
}

bridge_fits <- run_step_rds("derived_bridge_fits",
  function() fit_bridge(features, cfg_live),
  deps = wh_path("derived_features", cfg))

backtest_results <- run_step("derived_backtest_results",
  function() backtest_rmse(features, cfg),
  deps = wh_path("derived_features", cfg))

nowcast_current <- run_step("derived_nowcast_current",
  function() run_nowcast(bridge_fits, features, cfg,
                         portwatch  = raw_portwatch,
                         ports_meta = ports_meta),
  deps = c(wh_path("derived_bridge_fits", cfg),
           wh_path("derived_features",    cfg),
           wh_path("raw_portwatch_tonnage_daily", cfg)))

anomalies <- detect_anomalies(raw_portwatch, cfg)
save_nowcast_run(cfg, nowcast_current)

# --- outputs ---------------------------------------------------------------

csv_paths <- write_csv_outputs(nowcast_current, raw_portwatch,
                               bridge_fits, backtest_results, cfg)

if (!SKIP_REPORT) {
  render_briefing("reports/briefing/briefing.Rmd",
                  nowcast_current, csv_paths, cfg)
}

log_info("pipeline complete -- %d csv outputs", length(csv_paths))
