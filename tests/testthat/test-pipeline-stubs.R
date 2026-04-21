test_that("pipeline runs end-to-end with all caches primed (integration)", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse_dir  = file.path(tmp, "warehouse"),
      ports_metadata = testthat::test_path("..", "..", "inst", "extdata",
                                            "ports_metadata.csv"),
      sitc_crosswalk = testthat::test_path("..", "..", "inst", "extdata",
                                            "sitc_crosswalk.csv"),
      cache          = file.path(tmp, "cache"),
      outputs        = file.path(tmp, "outputs"),
      logs           = file.path(tmp, "logs")
    ),
    commodities = c("iron_ore", "coal", "lng", "other"),
    sample      = list(train_start = "2019-01-01",
                       train_end   = "2023-12-31",
                       valid_start = "2024-01-01"),
    portwatch   = list(base_url = "https://example.invalid/fs/0",
                       countries = "AUS", page_size = 2000,
                       retry = list(max_attempts = 1, backoff_seconds = 0)),
    abs         = list(commodity_sitc = list(iron_ore = "281",
                                             coal = c("321", "322"),
                                             lng = "343")),
    fred        = list(series_ids = c("PIORECRUSDM")),
    nowcast     = list(bootstrap_reps = 50, seed = 1),
    logging     = list(level = "WARN")
  )

  init_logger(cfg)
  warehouse_init_schema(cfg)
  ports_meta     <- load_ports_metadata(cfg)
  sitc_crosswalk <- load_sitc_crosswalk(cfg)

  cache_write(cfg, "portwatch", "daily_trade_panel", tibble::tibble(
    obs_date     = as.Date(character()),
    port_id      = character(),
    commodity    = character(),
    tonnage      = double(),
    vessel_count = integer(),
    ingested_at  = as.POSIXct(character(), tz = "UTC")
  ))
  cache_write(cfg, "abs_5368", "tables_12ab", tibble::tibble(
    date      = as.Date(character()),
    series    = character(),
    series_id = character(),
    value     = double()
  ))
  cache_write(cfg, "abs_5302", "tables_1_2", tibble::tibble(
    date      = as.Date(character()),
    series    = character(),
    series_id = character(),
    value     = double()
  ))
  cache_write(cfg, "fred", "commodity_prices", tibble::tibble(
    obs_date  = as.Date(character()),
    series_id = character(),
    value     = double()
  ))

  withr::with_envvar(c(FRED_API_KEY = ""), {
    pw    <- fetch_portwatch_tonnage(cfg, cfg$paths$warehouse_dir)
    a5368 <- fetch_abs_5368(cfg, cfg$paths$warehouse_dir)
    a5302 <- fetch_abs_5302(cfg, cfg$paths$warehouse_dir)
    fr    <- fetch_fred_prices(cfg, cfg$paths$warehouse_dir)
  })

  feats <- build_features(pw, a5368, fr, ports_meta, sitc_crosswalk, cfg)
  fits  <- fit_bridge(feats, cfg)
  deflators <- implicit_deflator(a5302)
  bt    <- backtest_rmse(feats, a5302, cfg)
  nc    <- run_nowcast(fits, feats, deflators, cfg,
                       portwatch = pw, ports_meta = ports_meta, fred = fr)
  anoms <- detect_anomalies(pw, cfg)
  save_nowcast_run(cfg, nc)

  paths <- write_csv_outputs(nc, pw, fits, bt, cfg)
  expect_true(all(fs::file_exists(paths)))
  expect_equal(nrow(nc), 1)
  expect_s3_class(anoms, "tbl_df")
})

test_that("quarter_share_observed is within [0,1]", {
  expect_gte(quarter_share_observed(as.Date("2026-01-01")), 0)
  expect_lte(quarter_share_observed(as.Date("2026-03-31")), 1)
})
