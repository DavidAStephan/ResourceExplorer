## resourcetracker — end-to-end pipeline
##
## Every function lives in R/. Phase 1 stubs return well-typed empty
## tibbles so the full DAG runs and downstream shapes are contract-tested
## before any real data arrives.

library(targets)

tar_option_set(
  packages = c("dplyr", "tibble", "tidyr", "readr", "fs", "logger",
               "DBI", "duckdb", "lubridate", "stringr", "httr2",
               "jsonlite", "purrr"),
  format   = "rds",
  error    = "stop"
)

# Source all R/ modules. devtools::load_all() isn't available inside a
# targets pipeline by default, and we don't want to force a rebuild+install
# between edits during development.
lapply(fs::dir_ls("R", glob = "*.R"), source)

list(

  tar_target(cfg,
             load_config("config.yml")),

  tar_target(logger_ready,
             init_logger(cfg)),

  tar_target(db_ready,
             warehouse_init_schema(cfg),
             format = "file"),

  tar_target(ports_meta,
             load_ports_metadata(cfg)),

  tar_target(sitc_crosswalk,
             load_sitc_crosswalk(cfg)),

  # --- ingestion ----------------------------------------------------------

  tar_target(raw_portwatch, fetch_portwatch_tonnage(cfg, db_ready)),
  tar_target(raw_abs_5368,  fetch_abs_5368(cfg, db_ready)),
  tar_target(raw_abs_5302,  fetch_abs_5302(cfg, db_ready)),
  tar_target(raw_fred,      fetch_fred_prices(cfg, db_ready)),

  # --- features + modelling -----------------------------------------------

  tar_target(features,
             build_features(raw_portwatch, raw_abs_5368, raw_fred,
                            ports_meta, sitc_crosswalk, cfg)),

  tar_target(bridge_fits,
             fit_bridge(features, cfg)),

  tar_target(deflators,
             implicit_deflator(raw_abs_5302)),

  tar_target(backtest_results,
             backtest_rmse(features, raw_abs_5302, cfg)),

  tar_target(nowcast_current,
             run_nowcast(bridge_fits, features, deflators, cfg,
                         portwatch  = raw_portwatch,
                         ports_meta = ports_meta,
                         fred       = raw_fred)),

  tar_target(anomalies,
             detect_anomalies(raw_portwatch, cfg)),

  tar_target(nowcast_history_row,
             save_nowcast_run(cfg, nowcast_current)),

  # --- outputs ------------------------------------------------------------

  tar_target(csv_exports,
             write_csv_outputs(nowcast_current, raw_portwatch,
                               bridge_fits, backtest_results, cfg)),

  tar_target(briefing_path,
             render_briefing("reports/briefing/briefing.qmd",
                             nowcast_current, csv_exports, cfg))
)
