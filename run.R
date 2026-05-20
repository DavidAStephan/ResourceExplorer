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
##   Rscript run.R --ci         # exit non-zero if every ingest landed on stale cache

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
CI_MODE     <- "--ci"        %in% args
RUN_STARTED <- Sys.time()

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
  # Always persist when the step actually ran. The earlier
  # `!fs::file_exists(out_path)` guard meant a `--force` rerun would
  # recompute in memory but leave the previous rds on disk -- silently
  # invisible until a schema change exposed it (the 2026-05-20
  # coal_met / coal_thermal split was the first time this surfaced).
  if (is.data.frame(result)) {
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

# Fit every candidate spec on the live training sample, then run the
# walk-forward backtest (one fit per candidate per validation quarter).
bridge_fits_bench <- run_step_rds("derived_bridge_fits_bench",
  function() fit_bridge_bench(features, cfg_live),
  deps = wh_path("derived_features", cfg))

backtest_results <- run_step("derived_backtest_results",
  function() backtest_rmse(features, cfg),
  deps = wh_path("derived_features", cfg))

# Augment backtest with combination forecasts (equal_avg, inv_mse),
# build OOS diagnostics, and pick the per-commodity production choice.
backtest_aug <- augment_with_combinations(backtest_results)
oos          <- oos_diagnostics(backtest_aug)
choice       <- production_choice(oos)
prod_models  <- select_production_models(bridge_fits_bench, oos, choice, cfg)

production_label <- if (nrow(choice) > 0) {
  stats::setNames(choice$production_spec, choice$commodity)
} else {
  NULL
}

nowcast_current <- run_step("derived_nowcast_current",
  function() run_nowcast(prod_models, features, cfg,
                         portwatch  = raw_portwatch,
                         ports_meta = ports_meta),
  deps = c(wh_path("derived_bridge_fits_bench", cfg),
           wh_path("derived_features",          cfg),
           wh_path("raw_portwatch_tonnage_daily", cfg)))

anomalies <- detect_anomalies(raw_portwatch, cfg)
save_nowcast_run(cfg, nowcast_current)

# --- outputs ---------------------------------------------------------------

csv_paths <- write_csv_outputs(nowcast_current, raw_portwatch,
                               bridge_fits_bench, backtest_aug, cfg,
                               production_label = production_label)

if (!SKIP_REPORT) {
  render_briefing("reports/briefing/briefing.Rmd",
                  nowcast_current, csv_paths, cfg)
}

log_info("pipeline complete -- %d csv outputs", length(csv_paths))

# --- Per-source staleness snapshot (always written) -----------------------
#
# For each external source we track, report the days since its most-
# recent fresh fetch (`status == "ok"`). Written to outputs/staleness.json
# so the weekly Actions workflow can surface a graduated warning when a
# source has been silently rotting on stale cache for more than a week.
# This is independent of `--ci`; the CI guard is a *hard* fail signal,
# this is a *soft* notification feed.

local({
  runs <- tryCatch(wh_read("mart_ingest_runs", cfg), error = function(e) NULL)
  src_summary <- if (is.null(runs) || nrow(runs) == 0L) {
    tibble::tibble(source = character(), latest_ok = as.POSIXct(character()),
                    days_since_ok = double())
  } else {
    runs |>
      dplyr::filter(.data$status == "ok") |>
      dplyr::group_by(.data$source) |>
      dplyr::summarise(latest_ok = max(.data$started_at), .groups = "drop") |>
      dplyr::mutate(days_since_ok = as.numeric(difftime(Sys.time(),
                                                         .data$latest_ok,
                                                         units = "days"))) |>
      dplyr::arrange(.data$source)
  }
  src_rows <- lapply(seq_len(nrow(src_summary)), function(i) {
    r <- src_summary[i, ]
    list(
      source        = r$source,
      latest_ok     = format(r$latest_ok, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      days_since_ok = round(r$days_since_ok, 1),
      stale         = isTRUE(r$days_since_ok > 7)
    )
  })
  payload <- list(
    generated_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    threshold_days = 7,
    sources        = src_rows
  )
  fs::dir_create(cfg$paths$outputs)
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE),
             fs::path(cfg$paths$outputs, "staleness.json"))
  for (i in seq_len(nrow(src_summary))) {
    r <- src_summary[i, ]
    if (isTRUE(r$days_since_ok > 7)) {
      log_warn("staleness: %s last fresh fetch was %.1f days ago",
               r$source, r$days_since_ok)
    }
  }
})

# --- CI staleness guard ----------------------------------------------------
#
# In --ci mode, fail the run if every external fetch this pipeline
# attempted landed on stale cache. The pipeline still produces outputs
# (good for offline dev), but a weekly automated run that quietly serves
# last week's data is a silent failure we want to surface loudly.

if (CI_MODE) {
  runs <- tryCatch(wh_read("mart_ingest_runs", cfg), error = function(e) NULL)
  this_run <- if (!is.null(runs) && nrow(runs) > 0L) {
    dplyr::filter(runs, .data$started_at >= RUN_STARTED)
  } else {
    NULL
  }
  # No rows: every ingest step was skipped via the rds-mtime cache. That
  # only happens locally on a warm checkout -- a CI worker always starts
  # cold, so we treat the empty case as clean.
  if (is.null(this_run) || nrow(this_run) == 0L) {
    log_info("ci: no ingest steps executed this run (all rds-cached)")
  } else {
    fresh <- sum(this_run$status == "ok")
    stale <- sum(this_run$status %in% c("cached", "error"))
    log_info("ci: ingest_runs this run -- %d fresh, %d stale/error",
             fresh, stale)
    if (fresh == 0L) {
      log_warn("ci: every external fetch landed on stale cache -- exiting non-zero")
      quit(status = 1L, save = "no")
    }
  }
}
