test_that("pipeline runs end-to-end with all caches primed (integration)", {
  skip_if_not_installed("readxl")

  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse_dir  = file.path(tmp, "warehouse"),
      ports_metadata = testthat::test_path("..", "..", "inst", "extdata",
                                            "ports_metadata.csv"),
      cache          = file.path(tmp, "cache"),
      outputs        = file.path(tmp, "outputs"),
      logs           = file.path(tmp, "logs")
    ),
    commodities = c("iron_ore","coal"),
    sample      = list(train_start = "2019-01-01",
                       train_end   = "2023-12-31",
                       valid_start = "2024-01-01"),
    portwatch   = list(base_url = "https://example.invalid/fs/0",
                       countries = "AUS", page_size = 1000,
                       retry = list(max_attempts = 1, backoff_seconds = 0),
                       lng_ports = character(0)),
    disr        = list(
      sheet        = "16",
      url_override = "https://example.invalid/disr.xlsx",
      rows = list(
        iron_ore = list(rows = 19L,         unit = "kt"),
        coal     = list(rows = c(47L, 48L), unit = "Mt")
      )),
    nowcast     = list(bootstrap_reps = 50, seed = 1),
    bridge      = list(hac_lag = 1L, min_n = 12L,
                       spec = list(iron_ore = "midas",
                                    coal     = "aggregate")),
    logging     = list(level = "WARN")
  )

  init_logger(cfg); warehouse_init_schema(cfg)
  ports_meta <- load_ports_metadata(cfg)

  cache_write(cfg, "portwatch", "daily_ports_data", tibble::tibble(
    obs_date             = as.Date(character()),
    portid               = character(),
    portname             = character(),
    export_dry_bulk      = integer(),
    export_tanker        = integer(),
    export_container     = integer(),
    export_general_cargo = integer(),
    export_roro          = integer(),
    portcalls            = integer(),
    ingested_at          = as.POSIXct(character(), tz = "UTC")
  ))
  cache_write(cfg, "disr_req", basename(cfg$disr$url_override), tibble::tibble(
    quarter_end = as.Date(character()),
    commodity   = character(),
    tonnes_Mt   = double(),
    source_url  = character()
  ))

  withr::with_envvar(c(FRED_API_KEY = ""), {
    pw    <- fetch_portwatch_tonnage(cfg, cfg$paths$warehouse_dir)
    disr  <- fetch_disr_req(cfg, cfg$paths$warehouse_dir)
  })

  feats <- build_features(pw, disr, cfg)
  fits  <- fit_bridge(feats, cfg)
  bt    <- backtest_rmse(feats, cfg)
  nc    <- run_nowcast(fits, feats, cfg,
                       portwatch = pw, ports_meta = ports_meta,
                       as_of = as.Date("2026-05-01"))
  anoms <- detect_anomalies(pw, cfg)
  save_nowcast_run(cfg, nc)

  paths <- write_csv_outputs(nc, pw, fits, bt, cfg)
  expect_true(all(fs::file_exists(paths)))
  expect_equal(nrow(nc), length(cfg$commodities))
  expect_s3_class(anoms, "tbl_df")

  # tonnage_quarterly.csv schema: every row has is_complete +
  # tonnage_extrapolated; the latter is NA on complete rows and finite
  # on the latest partial row.
  tq <- readr::read_csv(paths[["tonnage_quarterly"]], show_col_types = FALSE)
  expect_true(all(c("is_complete", "tonnage_extrapolated") %in% names(tq)))
  expect_true(all(is.na(tq$tonnage_extrapolated[tq$is_complete])))
  partial <- dplyr::filter(tq, !.data$is_complete)
  if (nrow(partial) > 0) {
    expect_true(all(is.finite(partial$tonnage_extrapolated)))
    # Extrapolated must be at least as large as raw observed sum -- you
    # can't shrink a partial-quarter sum by adding in unobserved months.
    expect_true(all(partial$tonnage_extrapolated >= partial$tonnage))
  }
})

test_that("quarter_share_observed is within [0,1]", {
  expect_gte(quarter_share_observed(as.Date("2026-01-01")), 0)
  expect_lte(quarter_share_observed(as.Date("2026-03-31")), 1)
})
