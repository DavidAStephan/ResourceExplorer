## ResourceTracker configuration
##
## Returns a named list. Sourced by `load_config()` (R/config.R); prefer
## editing values here over patching at runtime. This file replaced the
## previous `config.yml` because the work-laptop package allow-list does
## not include the `config` or `yaml` packages.

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

  cache = list(
    # Cache is a fallback, not a freshness policy. Every run refreshes from
    # source; on fetch failure we fall back to the most recent cached RDS
    # and tag the returned tibble with attr(x, "cache_status").
    enabled = TRUE
  ),

  portwatch = list(
    # IMF PortWatch daily trade panel -- public ArcGIS FeatureServer.
    # Placeholder URL; validated on first live run. Override at runtime
    # via Sys.setenv(PORTWATCH_BASE_URL=...) if the layer ID moves.
    base_url  = "https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/PortWatch_daily_trade_panel/FeatureServer/0",
    countries = c("AUS"),
    page_size = 2000L,
    retry     = list(
      max_attempts    = 3L,
      backoff_seconds = 5L
    )
  ),

  abs = list(
    cat_5368    = "5368.0",
    tables_5368 = c("12a", "12b"),
    cat_5302    = "5302.0",
    tables_5302 = c("1", "2"),
    # SITC 3-digit codes mapped to bridge-regression commodities.
    # LNG: SITC 343 includes non-LNG natural gas; LNG dominates AUS
    # exports of 343 so this is an MVP proxy. Upgrade to HS 2711.11 later
    # if residuals warrant it.
    commodity_sitc = list(
      iron_ore = c("281"),
      coal     = c("321", "322"),
      lng      = c("343")
    )
  ),

  fred = list(
    series_ids = c(
      "PIORECRUSDM",   # Iron ore, China import CFR
      "PCOALAUUSDM",   # Coal, Australia thermal
      "PNGASJPUSDM"    # Natural gas, Japan LNG
    )
    # Required env var: FRED_API_KEY (from .Renviron). Fetch gracefully
    # degrades to cache when unset.
  ),

  nowcast = list(
    bootstrap_reps = 1000L,
    seed           = 20260419L
  ),

  logging = list(
    level = "INFO"
  )
)
