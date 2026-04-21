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

  commodities = c("iron_ore", "coal"),

  cache = list(enabled = TRUE),

  portwatch = list(
    base_url  = "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/ArcGIS/rest/services/Daily_Ports_Data/FeatureServer/0",
    countries = c("AUS"),
    page_size = 1000L,
    retry     = list(max_attempts = 3L, backoff_seconds = 5L),
    # LNG port whitelist -- kept in config for completeness even though
    # lng is out of the nowcasting scope. Tanker tonnage routing.
    lng_ports = c("Darwin", "Dampier", "Gladstone", "Gorgon LNG", "Onslow")
  ),

  disr = list(
    # Sheet name and row mapping in DISR REQ Historical Data workbook.
    # Iron ore row 19 is in kt; coal rows 47+48 (metallurgical + thermal)
    # are in Mt. The url_override key forces a specific release (useful
    # for testing / reproducibility); when NULL the code probes for the
    # latest publication.
    sheet        = "16",
    url_override = NULL,
    rows = list(
      iron_ore = list(rows = 19L,          unit = "kt"),
      coal     = list(rows = c(47L, 48L),  unit = "Mt")
    )
  ),

  nowcast = list(
    bootstrap_reps = 1000L,
    seed           = 20260419L
  ),

  bridge = list(
    hac_lag = 1L,
    min_n   = 12L,
    # Per-commodity model spec. "aggregate" uses a single YoY-Δ tonnage
    # predictor (parsimonious, better when monthly betas would be
    # roughly equal); "midas" uses three per-month YoY-Δ predictors
    # (flexible, better when within-quarter timing carries signal).
    #
    # Choices come from the 2026-04-21 backtest-RMSE comparison:
    # iron_ore improves ~5% under MIDAS (β_m1 dominates) while coal is
    # ~16% worse because its monthly betas are roughly equal, so the
    # extra parameters inflate variance without new signal.
    spec = list(
      iron_ore = "midas",
      coal     = "aggregate"
    )
  ),

  logging = list(
    level = "INFO"
  )
)
