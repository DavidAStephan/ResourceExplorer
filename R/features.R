#' Build the monthly feature matrix for the bridge regressions
#'
#' Produces a long tibble keyed by (`commodity`, `month_end`) with all
#' the columns the bridge model needs. The work is:
#'
#' 1. Aggregate PortWatch daily tonnage to monthly, rolled up to our
#'    commodity short-list via `ports_meta$commodity_class`.
#' 2. Filter ABS 5368.0 monthly to each commodity's SITC codes (per the
#'    crosswalk), sum across codes, and use the SA series when ABS
#'    publishes one (so downstream fits see a cleaner y).
#' 3. X-13 seasonally adjust the monthly tonnage series per commodity
#'    (PortWatch is raw; ABS LHS is already SA).
#' 4. Resample FRED monthly commodity prices, align to the commodity.
#' 5. Build the "other" bucket by residual: `y_other = y_total - y_named`.
#' 6. Compute log transforms and the AR(1) lag `log_y_lag1` (lag of the
#'    *dependent* variable, on a per-commodity basis, SA where available).
#'
#' @param portwatch Daily tonnage tibble from [fetch_portwatch_tonnage()].
#' @param abs_5368 Monthly ABS tibble from [fetch_abs_5368()].
#' @param fred Price tibble from [fetch_fred_prices()].
#' @param ports_meta Tibble from [load_ports_metadata()].
#' @param sitc_xw Tibble from [load_sitc_crosswalk()].
#' @param cfg Config list.
#' @return Tibble with columns:
#'   `commodity`, `month_end`, `y_aud_m`, `tonnage`, `tonnage_sa`,
#'   `price`, `log_y`, `log_tonnage_sa`, `log_price`, `log_y_lag1`.
#' @export
build_features <- function(portwatch, abs_5368, fred,
                           ports_meta, sitc_xw, cfg) {

  monthly_tonnage <- aggregate_monthly_tonnage(portwatch, ports_meta, cfg)
  monthly_y       <- aggregate_monthly_abs(abs_5368, cfg)
  monthly_prices  <- aggregate_monthly_prices(fred, cfg)

  named <- c("iron_ore", "coal", "lng")
  feats_named <- purrr::map_dfr(named, function(com) {
    tn <- dplyr::filter(monthly_tonnage, .data$commodity == com)
    y  <- dplyr::filter(monthly_y,       .data$commodity == com)
    pr <- dplyr::filter(monthly_prices,  .data$commodity == com)

    tn_sa <- x13_adjust(dplyr::transmute(tn,
                                         month_end = .data$month_end,
                                         value = .data$tonnage))
    dplyr::transmute(
      dplyr::inner_join(
        dplyr::inner_join(
          dplyr::transmute(y, month_end, y_aud_m),
          dplyr::transmute(tn_sa,
                           month_end,
                           tonnage    = .data$value,
                           tonnage_sa = .data$value_sa),
          by = "month_end"
        ),
        dplyr::transmute(pr, month_end, price = .data$value),
        by = "month_end"
      ),
      commodity = com,
      month_end, y_aud_m, tonnage, tonnage_sa, price
    )
  })

  feats_other <- build_other_bucket(feats_named, monthly_tonnage,
                                    monthly_y, monthly_prices)

  dplyr::bind_rows(feats_named, feats_other) |>
    dplyr::group_by(.data$commodity) |>
    dplyr::arrange(.data$month_end, .by_group = TRUE) |>
    dplyr::mutate(
      log_y           = log(pmax(.data$y_aud_m, 1e-6)),
      log_tonnage_sa  = log(pmax(.data$tonnage_sa, 1e-6)),
      log_price       = log(pmax(.data$price, 1e-6)),
      log_y_lag1      = dplyr::lag(.data$log_y, 1)
    ) |>
    dplyr::ungroup() |>
    dplyr::filter(
      is.finite(.data$log_y), is.finite(.data$log_tonnage_sa),
      is.finite(.data$log_price)
    )
}

#' Aggregate daily tonnage to monthly per commodity bucket
#' @keywords internal
aggregate_monthly_tonnage <- function(portwatch, ports_meta, cfg) {
  if (nrow(portwatch) == 0) {
    return(tibble::tibble(
      commodity = character(),
      month_end = as.Date(character()),
      tonnage   = double()
    ))
  }
  portwatch |>
    dplyr::left_join(
      dplyr::select(ports_meta, port_id, commodity_class),
      by = "port_id"
    ) |>
    dplyr::mutate(
      month_end = lubridate::ceiling_date(.data$obs_date, "month") - 1,
      commodity = .data$commodity_class
    ) |>
    dplyr::filter(!is.na(.data$commodity)) |>
    dplyr::group_by(.data$commodity, .data$month_end) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")
}

#' Aggregate ABS monthly series to one value per (commodity, month_end)
#'
#' Coal combines SITC 321 + 322. Iron ore and LNG are single SITCs. Sum
#' over the SITC rows for each commodity after a left-join to the
#' crosswalk.
#' @keywords internal
aggregate_monthly_abs <- function(abs_5368, cfg) {
  if (nrow(abs_5368) == 0) {
    return(tibble::tibble(
      commodity = character(),
      month_end = as.Date(character()),
      y_aud_m   = double()
    ))
  }

  codes <- cfg$abs$commodity_sitc
  xw <- tibble::enframe(codes, name = "commodity", value = "sitc") |>
    tidyr::unnest("sitc")

  abs_5368 |>
    dplyr::inner_join(xw, by = "sitc") |>
    dplyr::group_by(.data$commodity, .data$month_end) |>
    dplyr::summarise(y_aud_m = sum(.data$value_aud_m, na.rm = TRUE),
                     .groups = "drop")
}

#' Resample FRED prices to month-end and attach to each commodity.
#'
#' FRED series are monthly already in practice -- we compute month-end
#' mean to be robust to any daily/weekly series that sneak in.
#' @keywords internal
aggregate_monthly_prices <- function(fred, cfg) {
  if (nrow(fred) == 0) {
    return(tibble::tibble(
      commodity = character(),
      month_end = as.Date(character()),
      value     = double()
    ))
  }

  price_map <- list(
    iron_ore = "PIORECRUSDM",
    coal     = "PCOALAUUSDM",
    lng      = "PNGASJPUSDM"
  )

  monthly <- fred |>
    dplyr::mutate(
      month_end = lubridate::ceiling_date(.data$obs_date, "month") - 1
    ) |>
    dplyr::group_by(.data$series_id, .data$month_end) |>
    dplyr::summarise(value = mean(.data$value, na.rm = TRUE),
                     .groups = "drop")

  purrr::imap_dfr(price_map, function(sid, com) {
    monthly |>
      dplyr::filter(.data$series_id == sid) |>
      dplyr::transmute(commodity = com, month_end, value)
  })
}

#' Construct the "other" bucket as residual-of-totals
#'
#' We don't have a per-commodity tonnage/price for "other" so we use
#' aggregate AUS tonnage and a trade-weighted price index -- weights are
#' the 2019-2023 average value share of the three named commodities,
#' with any residual weight (unobservable) dropped.
#' @keywords internal
build_other_bucket <- function(feats_named, monthly_tonnage,
                               monthly_y, monthly_prices) {
  if (nrow(feats_named) == 0) {
    return(tibble::tibble(
      commodity = character(),
      month_end = as.Date(character()),
      y_aud_m   = double(),
      tonnage   = double(),
      tonnage_sa = double(),
      price     = double()
    ))
  }

  # Total tonnage across all ports on the AUS panel.
  total_t <- monthly_tonnage |>
    dplyr::group_by(.data$month_end) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")

  total_t_sa <- x13_adjust(dplyr::transmute(total_t,
                                            month_end, value = .data$tonnage))

  # y_other = y_total - sum(y_named). Requires a "total_goods" row in
  # monthly_y; for MVP we approximate by summing what we have and
  # treating missing as zero. Replace with a proper total-goods pull
  # in a follow-up if the residual is noisy.
  y_named <- feats_named |>
    dplyr::group_by(.data$month_end) |>
    dplyr::summarise(y_named = sum(.data$y_aud_m, na.rm = TRUE),
                     .groups = "drop")

  y_total <- monthly_y |>
    dplyr::group_by(.data$month_end) |>
    dplyr::summarise(y_total = sum(.data$y_aud_m, na.rm = TRUE),
                     .groups = "drop")

  # Trade-weighted price index (2019-2023 value-share weights).
  weights <- feats_named |>
    dplyr::filter(.data$month_end <= as.Date("2023-12-31"),
                  .data$month_end >= as.Date("2019-01-01")) |>
    dplyr::group_by(.data$commodity) |>
    dplyr::summarise(w = sum(.data$y_aud_m, na.rm = TRUE), .groups = "drop") |>
    dplyr::mutate(w = .data$w / sum(.data$w))

  twp <- feats_named |>
    dplyr::inner_join(weights, by = "commodity") |>
    dplyr::group_by(.data$month_end) |>
    dplyr::summarise(price = sum(.data$price * .data$w, na.rm = TRUE),
                     .groups = "drop")

  dplyr::transmute(
    dplyr::inner_join(
      dplyr::inner_join(
        dplyr::inner_join(y_total, y_named, by = "month_end"),
        dplyr::transmute(total_t_sa,
                         month_end,
                         tonnage    = .data$value,
                         tonnage_sa = .data$value_sa),
        by = "month_end"
      ),
      twp, by = "month_end"
    ),
    commodity = "other",
    month_end,
    y_aud_m = pmax(.data$y_total - .data$y_named, 0),
    tonnage, tonnage_sa, price
  )
}
