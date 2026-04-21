## Test fixture: minimal config.R matching the current production schema.
list(
  paths = list(
    warehouse_dir  = "data/warehouse",
    cache          = "data/cache",
    outputs        = "outputs",
    logs           = "logs",
    ports_metadata = "inst/extdata/ports_metadata.csv"
  ),
  sample = list(
    train_start = as.Date("2019-01-01"),
    train_end   = as.Date("2023-12-31"),
    valid_start = as.Date("2024-01-01")
  ),
  commodities = c("iron_ore", "coal"),
  cache       = list(enabled = TRUE),
  portwatch   = list(
    base_url  = "https://example.invalid/fs/0",
    countries = c("AUS"),
    page_size = 1000L,
    retry     = list(max_attempts = 3L, backoff_seconds = 5L),
    lng_ports = c("Darwin", "Dampier", "Gladstone", "Gorgon LNG", "Onslow")
  ),
  disr = list(
    sheet        = "16",
    url_override = NULL,
    rows = list(
      iron_ore = list(rows = 19L,         unit = "kt"),
      coal     = list(rows = c(47L, 48L), unit = "Mt")
    )
  ),
  nowcast = list(bootstrap_reps = 100L, seed = 20260419L),
  bridge  = list(hac_lag = 1L, min_n = 12L,
                 spec = list(iron_ore = "midas", coal = "aggregate")),
  logging = list(level = "INFO")
)
