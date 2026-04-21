#!/usr/bin/env Rscript
## resourcetracker -- end-to-end pipeline
##
## Replaces the previous {targets} orchestrator. Sources every R/ module,
## loads config, initialises logger + warehouse dir, then runs the steps
## in the same order as the old `_targets.R`.
##
## Caching policy (`run_step` / `run_step_rds`):
##   Skip a step if its rds output already exists AND its mtime is newer
##   than every input it depends on (including R/ source files and
##   config.R). This is the targets-style "skip if up-to-date" policy
##   selected during planning. Pass `--force` to rerun everything.
##
## Usage:
##   Rscript run.R              # normal run, skip-if-up-to-date
##   Rscript run.R --force      # force rerun of every step
##   Rscript run.R --no-report  # skip the briefing render

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

# Source every R/ module in alphabetical order. This works because the
# modules reference each other by function name, not by load order.
R_FILES <- sort(list.files("R", pattern = "\\.R$", full.names = TRUE))
for (f in R_FILES) source(f, local = FALSE)

cfg <- load_config("config.R")
init_logger(cfg)
warehouse_init_schema(cfg)

args <- commandArgs(trailingOnly = TRUE)
FORCE      <- "--force"     %in% args
SKIP_REPORT <- "--no-report" %in% args

# --- skip-if-up-to-date helpers --------------------------------------------

.CODE_DEPS <- c(R_FILES, "config.R")

.step_cached <- function(out_path, deps) {
  all_deps <- unique(c(deps, .CODE_DEPS))
  existing <- all_deps[fs::file_exists(all_deps)]
  if (!fs::file_exists(out_path) || length(existing) == 0L) return(FALSE)
  out_mtime <- as.numeric(fs::file_info(out_path)$modification_time)
  dep_mtime <- max(as.numeric(fs::file_info(existing)$modification_time))
  out_mtime > dep_mtime
}

#' Run a step whose output is a tidy data frame. If the named warehouse
#' table is up-to-date vs its dependency files, skip and return the
#' cached rds; otherwise run `fn` and persist its result via `wh_write`.
run_step <- function(name, fn, deps = character(0), force = FORCE) {
  out_path <- wh_path(name, cfg)
  if (!force && .step_cached(out_path, deps)) {
    log_info("skip %-34s (cached)", name)
    return(wh_read(name, cfg))
  }
  log_info("run  %-34s ...", name)
  t0 <- Sys.time()
  result <- fn()
  dur <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  log_info("done %-34s [%5.1fs]", name, dur)
  # Most table-producing functions write to the warehouse themselves; if
  # not, persist here so the cache works on the next run.
  if (is.data.frame(result) && !fs::file_exists(out_path)) {
    wh_write(name, result, cfg)
  }
  result
}

#' Same as [run_step] but for non-tabular objects (e.g. fitted model lists).
#' Stores directly via saveRDS() under the warehouse directory.
run_step_rds <- function(name, fn, deps = character(0), force = FORCE) {
  out_path <- wh_path(name, cfg)
  if (!force && .step_cached(out_path, deps)) {
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

ports_meta     <- run_step("mart_dim_port",
  function() load_ports_metadata(cfg),
  deps = cfg$paths$ports_metadata)

sitc_crosswalk <- run_step("mart_crosswalk_sitc",
  function() load_sitc_crosswalk(cfg),
  deps = cfg$paths$sitc_crosswalk)

raw_portwatch  <- run_step("raw_portwatch_tonnage_daily",
  function() fetch_portwatch_tonnage(cfg, cfg$paths$warehouse_dir))

raw_abs_5368   <- run_step("raw_abs_5368_monthly",
  function() fetch_abs_5368(cfg, cfg$paths$warehouse_dir))

raw_abs_5302   <- run_step("raw_abs_5302_quarterly",
  function() fetch_abs_5302(cfg, cfg$paths$warehouse_dir))

raw_fred       <- run_step("raw_fred_prices_daily",
  function() fetch_fred_prices(cfg, cfg$paths$warehouse_dir))

features <- run_step("derived_features",
  function() build_features(raw_portwatch, raw_abs_5368, raw_fred,
                            ports_meta, sitc_crosswalk, cfg),
  deps = c(wh_path("raw_portwatch_tonnage_daily", cfg),
           wh_path("raw_abs_5368_monthly", cfg),
           wh_path("raw_fred_prices_daily", cfg),
           wh_path("mart_dim_port", cfg),
           wh_path("mart_crosswalk_sitc", cfg)))

bridge_fits <- run_step_rds("derived_bridge_fits",
  function() fit_bridge(features, cfg),
  deps = wh_path("derived_features", cfg))

deflators <- run_step("derived_deflators",
  function() implicit_deflator(raw_abs_5302),
  deps = wh_path("raw_abs_5302_quarterly", cfg))

backtest_results <- run_step("derived_backtest_results",
  function() backtest_rmse(features, raw_abs_5302, cfg),
  deps = c(wh_path("derived_features", cfg),
           wh_path("raw_abs_5302_quarterly", cfg)))

nowcast_current <- run_step("derived_nowcast_current",
  function() run_nowcast(bridge_fits, features, deflators, cfg,
                         portwatch  = raw_portwatch,
                         ports_meta = ports_meta,
                         fred       = raw_fred),
  deps = c(wh_path("derived_bridge_fits", cfg),
           wh_path("derived_features", cfg),
           wh_path("derived_deflators", cfg),
           wh_path("raw_portwatch_tonnage_daily", cfg),
           wh_path("mart_dim_port", cfg),
           wh_path("raw_fred_prices_daily", cfg)))

# These write their own side tables and don't need mtime cache semantics.
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
