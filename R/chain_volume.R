#' Build chain-volume nowcast series from latest ABS observation onwards
#'
#' Detects the gap between the latest published ABS chain-volume quarter
#' and the current nowcast, fills any intervening quarters by running the
#' bridge model over completed PortWatch data, then converts all quarters
#' to chain-volume A$m via the growth-rate pass-through.
#'
#' @param nowcast_current Tibble from [run_nowcast()] (h=0, h=1 rows).
#' @param abs_chain_vol Tibble from [fetch_abs_chain_volume()].
#' @param disr_hist Tibble from [fetch_disr_req()] (historical tonnes).
#' @param bridge_fits Production model bundle from [select_production_models()].
#' @param features Quarterly feature tibble from [build_features()].
#' @param portwatch Daily PortWatch tonnage tibble.
#' @param ports_meta Port metadata.
#' @param cfg Config list.
#' @return Chain-volume nowcast tibble covering all quarters from
#'   latest_ABS+1 through the nowcast horizon, or empty tibble if
#'   ABS data is unavailable.
#' @export
build_chain_vol_nowcast <- function(nowcast_current, abs_chain_vol,
                                    disr_hist, bridge_fits, features,
                                    portwatch, ports_meta, cfg) {
  if (is.null(abs_chain_vol) || nrow(abs_chain_vol) == 0L ||
      is.null(nowcast_current) || nrow(nowcast_current) == 0L) {
    return(empty_chain_vol_nowcast())
  }

  latest_abs_q <- max(abs_chain_vol$quarter_end)
  first_nc_q   <- min(nowcast_current$quarter_end[nowcast_current$horizon == 0L])

  gap_quarters <- find_gap_quarters(latest_abs_q, first_nc_q)

  gap_nc <- if (length(gap_quarters) > 0L) {
    log_info("chain_vol: filling %d gap quarter(s) from %s to %s",
             length(gap_quarters),
             as.character(min(gap_quarters)),
             as.character(max(gap_quarters)))
    fill_gap_quarters(gap_quarters, bridge_fits, features, portwatch,
                      ports_meta, cfg)
  } else {
    NULL
  }

  all_nc <- dplyr::bind_rows(gap_nc, nowcast_current)
  convert_nowcast_chain_volume(all_nc, abs_chain_vol, disr_hist)
}

#' Find quarter-end dates between latest ABS and first nowcast quarter
#' @keywords internal
find_gap_quarters <- function(latest_abs_q, first_nc_q) {
  if (is.na(latest_abs_q) || is.na(first_nc_q)) return(as.Date(character()))
  next_q <- lubridate::ceiling_date(
    latest_abs_q + 1, "quarter"
  ) - 1
  if (next_q >= first_nc_q) return(as.Date(character()))
  gap <- seq(next_q, first_nc_q - 1, by = "quarter")
  gap <- gap[gap < first_nc_q]
  gap
}

#' Run the bridge model for completed-but-unobserved gap quarters
#' @keywords internal
fill_gap_quarters <- function(gap_quarters, bridge_fits, features,
                              portwatch, ports_meta, cfg) {
  purrr::map_dfr(seq_along(gap_quarters), function(i) {
    q_end <- gap_quarters[i]
    h <- -length(gap_quarters) + i - 1L
    nc <- run_nowcast(bridge_fits, features, cfg,
                      portwatch  = portwatch,
                      ports_meta = ports_meta,
                      as_of      = q_end,
                      horizon    = 0L)
    dplyr::mutate(nc, horizon = as.integer(h))
  })
}

#' Convert physical-tonnage nowcasts to chain-volume A$m
#'
#' Applies a growth-rate pass-through bridge: the YoY growth rate of
#' DISR physical tonnes is applied to the year-ago ABS chain-volume
#' level. Validated empirically:
#'
#'   - **Coal** (SITC 32): slope = 1.02, R² = 0.81, p(β=1) = 0.67.
#'   - **Iron ore** (SITC 27+28 proxy): slope = 1.03, R² = 0.53,
#'     p(β=1) = 0.85 (2015+ sample; iron ore dominates the basket).
#'
#' Coal sub-commodities (met + thermal) are summed before conversion
#' because ABS publishes only total coal chain-volume.
#'
#' @param nowcast_current Tibble from [run_nowcast()] with columns
#'   `commodity`, `quarter_end`, `point_estimate_Mt`, band columns, etc.
#' @param abs_chain_vol Tibble from [fetch_abs_chain_volume()].
#' @param disr_hist Tibble from [fetch_disr_req()] (historical tonnes).
#' @return Tibble with one row per chain-volume commodity (`iron_ore`,
#'   `coal_total`): `commodity`, `quarter_end`, `point_estimate_Am`,
#'   `lower_80_Am`, `upper_80_Am`, `lower_95_Am`, `upper_95_Am`,
#'   `abs_lag4_Am`, `disr_lag4_Mt`, `growth_factor`, `horizon`.
#'   Returns empty tibble if ABS data is unavailable.
#' @export
convert_nowcast_chain_volume <- function(nowcast_current, abs_chain_vol,
                                         disr_hist) {
  if (is.null(abs_chain_vol) || nrow(abs_chain_vol) == 0L ||
      is.null(nowcast_current) || nrow(nowcast_current) == 0L) {
    return(empty_chain_vol_nowcast())
  }

  nc <- prepare_nowcast_for_cv(nowcast_current, disr_hist)
  if (nrow(nc) == 0L) return(empty_chain_vol_nowcast())

  abs_cv <- dplyr::select(abs_chain_vol, "quarter_end", "commodity",
                          "chain_vol_Am")

  cv_sigma <- cv_bridge_sigma(abs_chain_vol, disr_hist)

  purrr::map_dfr(unique(nc$cv_commodity), function(com) {
    nc_com  <- dplyr::filter(nc, .data$cv_commodity == com)
    abs_com <- dplyr::filter(abs_cv, .data$commodity == com)
    if (nrow(abs_com) == 0L) return(NULL)

    sigma_cv <- cv_sigma[[com]] %||% 0

    purrr::map_dfr(seq_len(nrow(nc_com)), function(i) {
      row   <- nc_com[i, ]
      q_end <- row$quarter_end
      q_lag4 <- lubridate::ceiling_date(
        q_end - lubridate::years(1L), "quarter"
      ) - 1

      abs_lag4 <- abs_com |>
        dplyr::filter(.data$quarter_end == q_lag4) |>
        dplyr::pull("chain_vol_Am")

      if (length(abs_lag4) == 0L || is.na(abs_lag4[1])) return(NULL)
      abs_lag4 <- abs_lag4[1]

      disr_lag4 <- row$disr_lag4_Mt
      if (is.na(disr_lag4) || disr_lag4 <= 0) return(NULL)

      growth <- row$point_estimate_Mt / disr_lag4
      log_point <- log(abs_lag4 * growth)

      sigma_tonnage <- infer_log_sigma(row$lower_80, row$upper_80,
                                       row$point_estimate_Mt, 0.80)
      sigma_total <- sqrt(sigma_tonnage^2 + sigma_cv^2)

      tibble::tibble(
        commodity         = com,
        quarter_end       = q_end,
        point_estimate_Am = exp(log_point),
        lower_80_Am       = exp(log_point - stats::qnorm(0.90) * sigma_total),
        upper_80_Am       = exp(log_point + stats::qnorm(0.90) * sigma_total),
        lower_95_Am       = exp(log_point - stats::qnorm(0.975) * sigma_total),
        upper_95_Am       = exp(log_point + stats::qnorm(0.975) * sigma_total),
        abs_lag4_Am       = abs_lag4,
        disr_lag4_Mt      = disr_lag4,
        growth_factor     = growth,
        horizon           = row$horizon
      )
    })
  })
}

#' Estimate per-commodity SD of the chain-volume bridge residual
#'
#' Computes `sd(Δlog(CV) − Δlog(tonnes))` from the overlapping ABS/DISR
#' history (2015+ for iron ore, full overlap for coal). This captures
#' the irreducible uncertainty in mapping physical tonnes growth to
#' chain-volume growth — basket composition, quality/grade shifts, and
#' timing differences.
#' @keywords internal
cv_bridge_sigma <- function(abs_chain_vol, disr_hist) {
  coal_subs <- c("coal_met", "coal_thermal")
  disr_coal <- disr_hist |>
    dplyr::filter(.data$commodity %in% coal_subs) |>
    dplyr::group_by(.data$quarter_end) |>
    dplyr::summarise(tonnes_Mt = sum(.data$tonnes_Mt), .groups = "drop") |>
    dplyr::mutate(commodity = "coal_total")

  disr_cv <- dplyr::bind_rows(
    disr_hist |>
      dplyr::filter(.data$commodity == "iron_ore") |>
      dplyr::select("quarter_end", "commodity", "tonnes_Mt"),
    disr_coal
  )

  abs_cv <- dplyr::select(abs_chain_vol, "quarter_end", "commodity",
                          "chain_vol_Am")

  out <- list()
  for (com in c("iron_ore", "coal_total")) {
    d <- dplyr::inner_join(
      dplyr::filter(disr_cv, .data$commodity == com),
      dplyr::filter(abs_cv,  .data$commodity == com),
      by = "quarter_end"
    ) |>
      dplyr::arrange(.data$quarter_end) |>
      dplyr::mutate(
        disr_yoy = log(.data$tonnes_Mt) - log(dplyr::lag(.data$tonnes_Mt, 4)),
        cv_yoy   = log(.data$chain_vol_Am) - log(dplyr::lag(.data$chain_vol_Am, 4)),
        resid    = .data$cv_yoy - .data$disr_yoy
      ) |>
      dplyr::filter(!is.na(.data$resid))

    if (com == "iron_ore") d <- dplyr::filter(d, .data$quarter_end >= as.Date("2015-01-01"))
    out[[com]] <- if (nrow(d) >= 4L) stats::sd(d$resid) else 0.035
  }
  out
}

#' Infer log-space sigma from a pair of percentile bounds
#'
#' Assumes the tonnage bootstrap is approximately log-normal. When
#' lower == upper (zero-width band, e.g. completed quarters), returns 0.
#' @keywords internal
infer_log_sigma <- function(lower, upper, point, coverage = 0.80) {
  if (is.na(lower) || is.na(upper) || is.na(point) ||
      point <= 0 || lower <= 0 || upper <= 0 || lower >= upper) {
    return(0)
  }
  z <- stats::qnorm(0.5 + coverage / 2)
  half_width_log <- (log(upper) - log(lower)) / 2
  half_width_log / z
}

#' Prepare nowcast rows for chain-volume conversion
#'
#' Aggregates coal sub-commodities into coal_total and attaches
#' year-ago DISR physical tonnes for each target quarter.
#' @keywords internal
prepare_nowcast_for_cv <- function(nowcast_current, disr_hist) {
  coal_subs <- c("coal_met", "coal_thermal")
  has_coal  <- any(nowcast_current$commodity %in% coal_subs)

  # Iron ore: pass through directly
  iron <- nowcast_current |>
    dplyr::filter(.data$commodity == "iron_ore") |>
    dplyr::mutate(cv_commodity = "iron_ore")

  # Coal: sum sub-commodities per (quarter_end, horizon)
  coal <- if (has_coal) {
    nowcast_current |>
      dplyr::filter(.data$commodity %in% coal_subs) |>
      dplyr::group_by(.data$quarter_end,
                      horizon = if ("horizon" %in% names(nowcast_current))
                                  .data$horizon else 0L) |>
      dplyr::summarise(
        point_estimate_Mt = sum(.data$point_estimate_Mt, na.rm = TRUE),
        lower_80          = sum(.data$lower_80, na.rm = TRUE),
        upper_80          = sum(.data$upper_80, na.rm = TRUE),
        lower_95          = sum(.data$lower_95, na.rm = TRUE),
        upper_95          = sum(.data$upper_95, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(commodity = "coal_total", cv_commodity = "coal_total")
  } else {
    # Handle case where commodity is already "coal_total" or just "coal"
    nowcast_current |>
      dplyr::filter(grepl("^coal", .data$commodity)) |>
      dplyr::mutate(cv_commodity = "coal_total")
  }

  nc <- dplyr::bind_rows(iron, coal)
  if (nrow(nc) == 0L) return(nc)

  # Attach year-ago DISR tonnes
  disr_lag4 <- build_disr_lag4(disr_hist, nc)
  nc |> dplyr::left_join(disr_lag4, by = c("cv_commodity", "quarter_end"))
}

#' Look up year-ago DISR physical tonnes for each nowcast row
#' @keywords internal
build_disr_lag4 <- function(disr_hist, nc) {
  coal_subs <- c("coal_met", "coal_thermal")

  disr_total_coal <- disr_hist |>
    dplyr::filter(.data$commodity %in% coal_subs) |>
    dplyr::group_by(.data$quarter_end) |>
    dplyr::summarise(tonnes_Mt = sum(.data$tonnes_Mt, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::mutate(commodity = "coal_total")

  disr_for_cv <- dplyr::bind_rows(
    disr_hist |>
      dplyr::filter(.data$commodity == "iron_ore") |>
      dplyr::select("quarter_end", "commodity", "tonnes_Mt"),
    disr_total_coal
  )

  target_quarters <- unique(nc$quarter_end)
  lag4_quarters <- lubridate::ceiling_date(
    target_quarters - lubridate::years(1L), "quarter"
  ) - 1

  purrr::map_dfr(unique(nc$cv_commodity), function(com) {
    purrr::map_dfr(seq_along(target_quarters), function(i) {
      val <- disr_for_cv |>
        dplyr::filter(.data$commodity == com,
                      .data$quarter_end == lag4_quarters[i]) |>
        dplyr::pull("tonnes_Mt")
      tibble::tibble(
        cv_commodity = com,
        quarter_end  = target_quarters[i],
        disr_lag4_Mt = if (length(val) > 0) val[1] else NA_real_
      )
    })
  })
}

#' @keywords internal
empty_chain_vol_nowcast <- function() {
  tibble::tibble(
    commodity         = character(),
    quarter_end       = as.Date(character()),
    point_estimate_Am = double(),
    lower_80_Am       = double(),
    upper_80_Am       = double(),
    lower_95_Am       = double(),
    upper_95_Am       = double(),
    abs_lag4_Am       = double(),
    disr_lag4_Mt      = double(),
    growth_factor     = double(),
    horizon           = integer()
  )
}
