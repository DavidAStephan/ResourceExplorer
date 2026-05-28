#' @importFrom rlang .data
NULL

## Register column names used inside dplyr NSE so R CMD check doesn't
## flag them as "undefined global variables". Kept tight on purpose -- no
## blanket silencing. Update when the feature / schema column names change.

utils::globalVariables(c(
  # schema columns (raw.* / mart.* tables)
  "commodity", "commodity_class", "month_end", "quarter_end",
  "obs_date", "port_id", "sitc", "sitc_map",
  "tonnage", "tonnage_sa", "vessel_count",
  "series_id", "series", "date",
  "value", "value_aud_m", "value_current_aud_m", "value_chainvol_aud_m",
  "y_aud_m", "y_total", "y_named",
  "ingested_at", "price", "deflator", "is_chainvol",

  # feature-panel columns
  "log_y", "log_y_lag1", "log_tonnage_sa", "log_price",
  "yhat_aud_m", "yhat_log",

  # backtest columns
  "err", "err_naive", "point_estimate", "ratio_vs_naive",
  "rmse_valid", "rmse_naive",

  # anomaly columns
  "z_score", "doy_centre",

  # chain_volume / extrapolation intermediates
  "cum", "cum_share", "day", "t", "total", "w",
  "seed_log_y", "latest_log_price", "tonnage_est",
  "chain_vol_Am", "cv_commodity", "disr_lag4_Mt",
  "point_estimate_Am", "growth_factor",

  # state
  "run_timestamp", "share_observed", "lower_80", "lower_95",
  "upper_80", "upper_95"
))
