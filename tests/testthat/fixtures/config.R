## Test fixture: minimal config.R for test-config.R parity checks.
list(
  paths = list(
    warehouse_dir   = "data/warehouse",
    cache           = "data/cache",
    outputs         = "outputs",
    logs            = "logs",
    ports_metadata  = "inst/extdata/ports_metadata.csv",
    sitc_crosswalk  = "inst/extdata/sitc_crosswalk.csv"
  ),
  sample = list(
    train_start = as.Date("2019-01-01"),
    train_end   = as.Date("2023-12-31"),
    valid_start = as.Date("2024-01-01")
  ),
  commodities = c("iron_ore", "coal", "lng", "other"),
  cache       = list(enabled = TRUE),
  portwatch   = list(
    base_url  = "https://example.invalid/fs/0",
    countries = c("AUS"),
    page_size = 2000L,
    retry     = list(max_attempts = 3L, backoff_seconds = 5L)
  ),
  abs = list(
    cat_5368 = "5368.0", tables_5368 = c("12a", "12b"),
    cat_5302 = "5302.0", tables_5302 = c("1", "2"),
    commodity_sitc = list(
      iron_ore = c("281"), coal = c("321", "322"), lng = c("343")
    )
  ),
  fred = list(series_ids = c("PIORECRUSDM", "PCOALAUUSDM", "PNGASJPUSDM")),
  nowcast = list(bootstrap_reps = 1000L, seed = 20260419L),
  logging = list(level = "INFO")
)
