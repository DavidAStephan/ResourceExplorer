## ResourceTracker configuration
##
## Per-commodity quarterly physical-tonnage nowcasts for iron_ore and coal.
## Target:   DISR Resources and Energy Quarterly Table 16 (physical Mt).
## Indicator: IMF PortWatch AIS daily tonnage, aggregated to quarterly.
##
## LNG was scoped out 2026-04-21 — PortWatch tanker tonnage has near-zero
## correlation with ABS LNG volume at quarterly grain. Australian LNG is
## too contract-dominated to be nowcastable from physical indicators.

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

  # Coal is split into metallurgical (DISR row 47) and thermal (row 48).
  # Different demand drivers (Asian steelmakers vs power generation) and
  # the 2026-05-20 review flagged the split as the most likely RMSE
  # improvement. Both sub-commodities share the same PortWatch RHS
  # (we can't disaggregate dry-bulk tonnage by destination use at port
  # level) but get separately-fit bridges.
  commodities = c("iron_ore", "coal_met", "coal_thermal"),

  cache = list(enabled = TRUE),

  portwatch = list(
    base_url  = "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/ArcGIS/rest/services/Daily_Ports_Data/FeatureServer/0",
    countries = c("AUS"),
    page_size = 1000L,
    retry     = list(max_attempts = 3L, backoff_seconds = 5L)
  ),

  disr = list(
    # Sheet name and row mapping in DISR REQ Historical Data workbook.
    # Iron ore row 19 is in kt; coal split: row 47 = metallurgical,
    # row 48 = thermal, both in Mt. The url_override key forces a
    # specific release (useful for testing / reproducibility); when
    # NULL the code probes for the latest publication.
    sheet        = "16",
    url_override = NULL,
    rows = list(
      iron_ore     = list(rows = 19L, unit = "kt"),
      coal_met     = list(rows = 47L, unit = "Mt"),
      coal_thermal = list(rows = 48L, unit = "Mt")
    )
  ),

  nowcast = list(
    bootstrap_reps = 1000L,
    seed           = 20260419L
  ),

  # FRED China-demand indicators consumed by the `demand_aug` bridge
  # spec. When `FRED_API_KEY` is unset (offline / fork builds) the
  # ingest short-circuits and the bench drops `demand_aug` per commodity
  # automatically via the existing `fit_bridge_one` guardrails.
  # Series IDs verified live 2026-05-21 -- the originally-proposed
  # `CHNPRMNTO01IXOBSAM` (steel) and `CHNPIEAEN01GPSAM` (electricity)
  # were retired by OECD; substitutes below have been live since the
  # 1990s and update monthly.
  fred = list(
    api_key_env = "FRED_API_KEY",
    series = list(
      iron_ore     = c(cli     = "CHNLOLITOAASTSAM"),
      coal_thermal = c(exports = "XTEXVA01CNM667S")
    ),
    retry = list(max_attempts = 3L, backoff_seconds = 5L)
  ),

  # ABS 5302.0 Table 6 chain-volume measures (Balance of Payments).
  # Used post-nowcast to convert DISR physical-tonnage growth rates
  # into national-accounts chain-volume A$m. Coal (SITC 32) is a
  # direct match; metal ores (SITC 27+28) proxies iron ore.
  abs = list(
    series = list(
      iron_ore   = list(series_id = "A3535047K",
                        label = "Metal ores and minerals"),
      coal_total = list(series_id = "A3535048L",
                        label = "Coal, coke and briquettes")
    )
  ),

  bridge = list(
    hac_lag = 1L,
    min_n   = 12L,
    # All candidates are fit per commodity at every refit; production
    # picks the best by OOS RMSE (see R/combination.R). Currently:
    #   aggregate -- free beta_lag4
    #   midas     -- three free monthly betas, free beta_lag4
    #   bojo      -- pure YoY-on-YoY (beta_lag4 forced to 1)
    #   lagged    -- aggregate + 1-quarter-lagged tonnage term
    candidates = c("aggregate", "midas", "bojo", "lagged", "price_aug",
                   "demand_aug")
  ),

  logging = list(
    level = "INFO"
  )
)
