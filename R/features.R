#' Build the MIDAS-style quarterly feature panel
#'
#' One row per (`commodity`, `quarter_end`). The "MIDAS" (mixed-data
#' sampling) part: each quarter is broken into three monthly positions
#' (`m1`, `m2`, `m3`) so the bridge can weight within-quarter timing
#' differently for each — useful because PortWatch tonnage for, say,
#' the first month of a quarter is mechanically a better indicator of
#' that quarter's exports than the third (which is still being filled
#' in at nowcast time).
#'
#' Columns:
#'
#' | column                   | meaning                                      |
#' |--------------------------|----------------------------------------------|
#' | `commodity`              | one of `iron_ore`, `coal`                    |
#' | `quarter_end`            | last day of the quarter                      |
#' | `volume_Mt`              | LHS target: DISR REQ T16 physical Mt         |
#' | `tonnage`                | total quarterly PortWatch tonnage (sum m1+m2+m3) |
#' | `tonnage_m1` .. `_m3`    | PortWatch tonnage in each month of the quarter |
#' | `log_volume`             | log of LHS                                   |
#' | `log_tonnage_m1` .. `_m3`| logs of monthly positions                    |
#' | `log_volume_lag4`        | year-ago LHS (seasonal anchor)               |
#' | `yoy_log_volume`         | YoY Δ of LHS (used by the `bojo` spec)       |
#' | `yoy_log_tonnage_m1` .. `_m3` | YoY Δ of each monthly position (RHS in bridge) |
#'
#' YoY differencing on each monthly position strips out seasonality
#' mechanically, so no STL / X-13 is applied here.
#'
#' @param portwatch Daily tonnage tibble from [fetch_portwatch_tonnage()].
#' @param disr_req Quarterly physical-volume tibble from
#'   [fetch_disr_req()] with columns `quarter_end`, `commodity`,
#'   `tonnes_Mt`.
#' @param cfg Config list.
#' @return Tibble keyed by `(commodity, quarter_end)`.
#' @export
build_features <- function(portwatch, disr_req, cfg,
                           wb_prices   = NULL,
                           fred_demand = NULL) {
  commodities <- cfg$commodities

  # PortWatch can't disaggregate dry-bulk at coal ports into metallurgical
  # vs thermal use -- the disaggregation only exists on the LHS (DISR
  # rows 47 vs 48). When the configured commodities include the coal
  # split, fan out PortWatch's `coal` rows so both sub-commodities see
  # the same tonnage signal.
  portwatch <- expand_coal_split(portwatch, commodities)

  tonnage_m <- aggregate_monthly_tonnage_mwq(portwatch, commodities)

  # Optional price column. Joined onto features below; absent when
  # `wb_prices` is NULL or when the commodity has no matching price
  # series (e.g. an older config without the price ingest wired up).
  price_join <- if (!is.null(wb_prices) && nrow(wb_prices) > 0) {
    wb_prices |>
      dplyr::select(dplyr::all_of(c("commodity", "quarter_end", "log_price")))
  } else {
    tibble::tibble(commodity = character(),
                   quarter_end = as.Date(character()),
                   log_price = double())
  }

  # Optional FRED demand-indicator columns. Pivot the long
  # (commodity, series, quarter_end, log_value) tibble to one column per
  # series with prefix `log_demand_`. Absent series stay NA (handled
  # downstream by `fit_bridge_one`'s near-zero-variance / NA skip).
  demand_join <- if (!is.null(fred_demand) && nrow(fred_demand) > 0) {
    fred_demand |>
      dplyr::select(dplyr::all_of(c("commodity", "quarter_end", "series",
                                    "log_value"))) |>
      tidyr::pivot_wider(names_from  = "series",
                         values_from = "log_value",
                         names_prefix = "log_demand_")
  } else {
    tibble::tibble(commodity = character(),
                   quarter_end = as.Date(character()))
  }

  # LHS: physical tonnage (Mt) by commodity, quarterly.
  lhs <- disr_req |>
    dplyr::filter(.data$commodity %in% commodities) |>
    dplyr::transmute(.data$commodity, .data$quarter_end,
                     volume_Mt = .data$tonnes_Mt)

  wide <- tonnage_m |>
    dplyr::select(dplyr::all_of(c("commodity", "quarter_end", "mwq",
                                  "tonnage"))) |>
    tidyr::pivot_wider(names_from  = "mwq",
                       values_from = "tonnage",
                       names_prefix = "tonnage_m",
                       values_fill  = 0)

  # Some quarters might miss a monthly column if PortWatch has no rows
  # for that month. Guarantee all three exist.
  for (k in 1:3) {
    col <- paste0("tonnage_m", k)
    if (!col %in% names(wide)) wide[[col]] <- 0
  }

  feats <- dplyr::inner_join(lhs, wide, by = c("commodity", "quarter_end")) |>
    dplyr::left_join(price_join, by = c("commodity", "quarter_end")) |>
    dplyr::left_join(demand_join, by = c("commodity", "quarter_end"))
  # Ensure log_price always exists so the downstream mutate doesn't fail
  # when price_join had zero matching rows (e.g. price ingest disabled).
  if (!"log_price" %in% names(feats)) feats$log_price <- NA_real_

  # Names of the FRED demand columns we just joined. May be empty when
  # `fred_demand` is NULL or unset; the YoY mutate below skips them
  # in that case.
  demand_cols <- setdiff(grep("^log_demand_", names(feats), value = TRUE),
                         character())

  feats <- feats |>
    dplyr::group_by(.data$commodity) |>
    dplyr::arrange(.data$quarter_end, .by_group = TRUE) |>
    dplyr::mutate(
      tonnage             = .data$tonnage_m1 + .data$tonnage_m2 +
                            .data$tonnage_m3,
      log_volume          = log(pmax(.data$volume_Mt,   1e-6)),
      log_tonnage         = log(pmax(.data$tonnage,     1e-6)),
      log_tonnage_m1      = log(pmax(.data$tonnage_m1,  1e-6)),
      log_tonnage_m2      = log(pmax(.data$tonnage_m2,  1e-6)),
      log_tonnage_m3      = log(pmax(.data$tonnage_m3,  1e-6)),
      log_volume_lag4     = dplyr::lag(.data$log_volume, 4L),
      # YoY log-difference of the LHS -- the dependent variable when the
      # bridge is fit in pure differenced form (`bojo` spec, which
      # forces beta_lag4 = 1).
      yoy_log_volume      = .data$log_volume -
                             dplyr::lag(.data$log_volume, 4L),
      # Aggregate YoY: log ratio of quarterly tonnage totals; for the
      # `spec = "aggregate"` bridge variant.
      yoy_log_tonnage     = .data$log_tonnage -
                             dplyr::lag(.data$log_tonnage, 4L),
      # 1-quarter lag of the YoY tonnage indicator, used by the `lagged`
      # spec (Adland-Jia-Strandenes 2017: AIS can lead customs-cleared
      # trade by several weeks).
      yoy_log_tonnage_lag1 = dplyr::lag(.data$log_tonnage -
                                          dplyr::lag(.data$log_tonnage, 4L),
                                        1L),
      # Per-month YoY: for the `spec = "midas"` bridge variant.
      yoy_log_tonnage_m1  = .data$log_tonnage_m1 -
                             dplyr::lag(.data$log_tonnage_m1, 4L),
      yoy_log_tonnage_m2  = .data$log_tonnage_m2 -
                             dplyr::lag(.data$log_tonnage_m2, 4L),
      yoy_log_tonnage_m3  = .data$log_tonnage_m3 -
                             dplyr::lag(.data$log_tonnage_m3, 4L),
      # YoY change in log price, used by the `price_aug` candidate spec.
      # `log_price` may be NA if the price-ingest hasn't run yet --
      # the column propagates NAs through to the bridge, which then
      # skips this candidate via the existing complete_cases guard.
      yoy_log_price       = .data$log_price - dplyr::lag(.data$log_price, 4L)
    ) |>
    dplyr::ungroup()

  # YoY-difference each FRED demand series, mirroring the YoY treatment
  # of price / tonnage above. Same NA-propagation semantics: when the
  # series wasn't joined (commodity has no FRED mapping in this pass)
  # the column stays NA and `fit_bridge_one` skips `demand_aug` for
  # that commodity automatically.
  for (col in demand_cols) {
    yoy_name <- sub("^log_demand_", "yoy_log_demand_", col)
    feats <- feats |>
      dplyr::group_by(.data$commodity) |>
      dplyr::arrange(.data$quarter_end, .by_group = TRUE) |>
      dplyr::mutate(!!yoy_name := .data[[col]] - dplyr::lag(.data[[col]], 4L)) |>
      dplyr::ungroup()
  }

  feats |>
    dplyr::filter(is.finite(.data$log_volume))
}

#' Duplicate PortWatch `coal` rows into `coal_met` + `coal_thermal`
#'
#' Both sub-commodities share the same PortWatch signal because we can't
#' disaggregate dry-bulk-at-coal-ports by met vs thermal use at the port
#' level. The disaggregation only exists on the LHS (DISR rows 47 vs 48).
#'
#' If `commodities` doesn't include any coal-split entries the function
#' is a no-op.
#'
#' @keywords internal
expand_coal_split <- function(portwatch, commodities) {
  wants_split <- any(c("coal_met", "coal_thermal") %in% commodities)
  if (!wants_split || nrow(portwatch) == 0L) return(portwatch)
  if (!"coal" %in% portwatch$commodity) return(portwatch)

  coal_rows <- dplyr::filter(portwatch, .data$commodity == "coal")
  add <- list()
  if ("coal_met"     %in% commodities) {
    add[[1L]] <- dplyr::mutate(coal_rows, commodity = "coal_met")
  }
  if ("coal_thermal" %in% commodities) {
    add[[length(add) + 1L]] <- dplyr::mutate(coal_rows, commodity = "coal_thermal")
  }
  dplyr::bind_rows(
    dplyr::filter(portwatch, .data$commodity != "coal"),
    dplyr::bind_rows(add)
  )
}

#' Aggregate daily PortWatch tonnage to (commodity × quarter × month-in-quarter)
#'
#' Returns one row per (commodity, quarter_end, mwq) where `mwq` is 1/2/3
#' for the first/second/third month of that quarter.
#' @keywords internal
aggregate_monthly_tonnage_mwq <- function(portwatch, commodities) {
  empty <- tibble::tibble(
    commodity   = character(),
    quarter_end = as.Date(character()),
    mwq         = integer(),
    tonnage     = double()
  )
  if (nrow(portwatch) == 0L) return(empty)

  portwatch |>
    dplyr::filter(.data$commodity %in% commodities) |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(.data$obs_date, "quarter") - 1,
      mwq         = ((lubridate::month(.data$obs_date) - 1L) %% 3L) + 1L
    ) |>
    dplyr::group_by(.data$commodity, .data$quarter_end, .data$mwq) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")
}
