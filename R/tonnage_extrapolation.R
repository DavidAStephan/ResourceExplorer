#' Estimate full-quarter tonnage from a partially observed quarter
#'
#' Given the current date `as_of` sitting inside quarter Q, return
#' one row per (commodity, month in Q) with a best-estimate tonnage
#' plus a `status` flag (`observed` / `partial` / `estimated`).
#'
#' **Partial-month scale-up** uses the 2019-training day-of-month share.
#' If through day d we've observed a fraction `share(d)` of the typical
#' month's tonnage, then estimated full-month tonnage is
#' `observed / share(d)`. For commodities whose shipping cadence isn't
#' uniform (coal, LNG bulk shipments) this beats a flat pro-rata.
#'
#' **Unobserved future months** use `seasonal_avg x pace`, where `pace`
#' is the ratio of the most-recent complete month's tonnage to its own
#' seasonal average. So a pickup in observed pace carries forward.
#'
#' **PortWatch lag.** IMF's daily-ports endpoint refreshes with a
#' multi-day lag; on any given Tuesday, the latest available row is
#' typically 7-14 days back. The partial-month scale-up therefore
#' anchors on `effective_today = min(as_of, max(obs_date))` rather than
#' the calendar date `as_of`, so we never divide actually-observed
#' tonnage by an expected-share computed for days the data doesn't cover
#' yet. Backtests still bound `effective_today` at the requested `as_of`.
#'
#' **Sanity clip.** A partial-month estimate that lands more than `3x`
#' away from `seasonal_norm * pace` in either direction is clipped to
#' the seasonal-norm value and a warning is logged. Catches partial-
#' month divisions that go pathological on tiny day-counts.
#'
#' @param portwatch Daily tonnage tibble from [fetch_portwatch_tonnage()].
#' @param ports_meta Port metadata, for the commodity mapping.
#' @param cfg Config list.
#' @param as_of Date; defaults to `Sys.Date()`.
#' @return Tibble: `commodity`, `month_end`, `tonnage_est`,
#'   `share_observed`, `status`.
#' @export
extrapolate_quarter_tonnage <- function(portwatch, ports_meta, cfg,
                                        as_of = Sys.Date()) {
  q_start <- lubridate::floor_date(as_of, "quarter")
  q_end   <- quarter_end(as_of)
  months_in_q <- seq(q_start, q_end, by = "month") |>
    lubridate::ceiling_date("month") - 1

  if (nrow(portwatch) == 0) {
    return(tibble::tibble(
      commodity = cfg$commodities,
      month_end = rep(q_end, length(cfg$commodities)),
      tonnage_est = NA_real_,
      share_observed = NA_real_,
      status = "estimated"
    ))
  }

  # `portwatch` already carries a `commodity` column from
  # derive_portwatch_commodity_rows(); no port_id-based join needed.
  # `ports_meta` is kept in the signature for backwards compatibility but
  # unused here.
  daily <- dplyr::filter(portwatch, !is.na(.data$commodity))

  # Anchor on the data, not the calendar. Bound at `as_of` so backtests
  # at past dates don't peek at later observations.
  effective_today <- min(as_of, max(daily$obs_date, na.rm = TRUE))
  if (effective_today < as_of) {
    log_info(paste0("extrapolate_quarter_tonnage: PortWatch lag %d day(s)",
                    " -- using effective_today=%s instead of as_of=%s"),
             as.integer(as_of - effective_today),
             as.character(effective_today), as.character(as_of))
  }

  commodities <- cfg$commodities

  purrr::map_dfr(commodities, function(com) {
    com_daily <- dplyr::filter(daily, .data$commodity == com)

    seasonal_norm <- seasonal_monthly_norm(com_daily)
    dom_share    <- day_of_month_share(com_daily)
    pace         <- recent_pace_ratio(com_daily, seasonal_norm,
                                      effective_today)

    purrr::map_dfr(months_in_q, function(m) {
      m_floor <- lubridate::floor_date(m, "month")
      m_end   <- m
      in_m    <- dplyr::filter(com_daily,
                               .data$obs_date >= m_floor,
                               .data$obs_date <= pmin(m_end, effective_today))
      obs_tonnage <- sum(in_m$tonnage, na.rm = TRUE)

      avg_for_month <- seasonal_norm$mean_tonnage[
        seasonal_norm$month == lubridate::month(m_end)
      ]
      norm_est <- if (length(avg_for_month) == 1 && !is.na(avg_for_month)) {
        avg_for_month * pace
      } else {
        NA_real_
      }

      if (m_end <= effective_today) {
        # Fully observed (relative to the data we actually have).
        tibble::tibble(commodity = com, month_end = m_end,
                       tonnage_est = obs_tonnage,
                       share_observed = 1,
                       status = "observed")
      } else if (m_floor > effective_today) {
        # No data for this month yet -- pure seasonal forecast.
        tibble::tibble(commodity = com, month_end = m_end,
                       tonnage_est = norm_est,
                       share_observed = 0,
                       status = "estimated")
      } else {
        # Partially observed: scale up by the day-of-month share at the
        # data's actual last-observed day (NOT the calendar's today).
        d <- as.integer(effective_today - m_floor + 1)
        s <- dom_share_at(dom_share, d)
        s <- max(s, 0.05)   # floor to avoid blow-up on day 1-2
        raw_est <- obs_tonnage / s
        est <- sanity_clip_partial(raw_est, norm_est, com, m_end)
        tibble::tibble(commodity = com, month_end = m_end,
                       tonnage_est = est,
                       share_observed = s,
                       status = "partial")
      }
    })
  })
}

#' Sanity-clip a partial-month estimate against the seasonal norm
#'
#' Partial-month scale-up `obs / share(d)` can go pathological when `d`
#' is tiny (1-2 days), when an unusual shipping cluster lands on those
#' days, or when `share(d)` is small. If the scaled estimate is more
#' than `3x` away from the seasonal-norm-anchored estimate in either
#' direction, fall back to the seasonal-norm value and warn. The 3x
#' threshold is wide enough that real pickups / slowdowns pass through.
#'
#' @keywords internal
sanity_clip_partial <- function(raw_est, norm_est, commodity, month_end,
                                factor = 3) {
  if (!is.finite(raw_est) || !is.finite(norm_est) || norm_est <= 0) {
    return(raw_est)
  }
  ratio <- raw_est / norm_est
  if (ratio > factor || ratio < 1 / factor) {
    log_warn(paste0(
      "extrapolate_quarter_tonnage: clipping %s %s partial-month estimate -- ",
      "raw=%.2f Mt, seasonal-anchor=%.2f Mt (ratio %.2f)"
    ), commodity, as.character(month_end),
       raw_est / 1e6, norm_est / 1e6, ratio)
    return(norm_est)
  }
  raw_est
}

#' Seasonal monthly norm from daily tonnage
#' @keywords internal
seasonal_monthly_norm <- function(daily) {
  if (nrow(daily) == 0) {
    return(tibble::tibble(month = integer(), mean_tonnage = double()))
  }
  daily |>
    dplyr::mutate(
      month_end = lubridate::ceiling_date(.data$obs_date, "month") - 1,
      month     = lubridate::month(.data$obs_date)
    ) |>
    dplyr::group_by(.data$month, .data$month_end) |>
    dplyr::summarise(tonnage = sum(.data$tonnage, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::group_by(.data$month) |>
    dplyr::summarise(mean_tonnage = mean(.data$tonnage, na.rm = TRUE),
                     .groups = "drop")
}

#' Empirical day-of-month cumulative share, pooled across months
#' @keywords internal
day_of_month_share <- function(daily) {
  if (nrow(daily) == 0) return(numeric(0))
  by_day <- daily |>
    dplyr::mutate(day = lubridate::day(.data$obs_date),
                  month_end = lubridate::ceiling_date(.data$obs_date, "month") - 1) |>
    dplyr::group_by(.data$month_end, .data$day) |>
    dplyr::summarise(t = sum(.data$tonnage, na.rm = TRUE), .groups = "drop") |>
    dplyr::group_by(.data$month_end) |>
    dplyr::mutate(cum = cumsum(.data$t),
                  total = sum(.data$t),
                  cum_share = .data$cum / pmax(.data$total, 1e-6)) |>
    dplyr::ungroup()

  tapply(by_day$cum_share, by_day$day, mean, na.rm = TRUE)
}

#' Look up the day-of-month share, with linear interp for missing days
#' @keywords internal
dom_share_at <- function(dom_share, day) {
  if (length(dom_share) == 0) return(day / 30)  # flat pro-rata fallback
  idx <- as.character(day)
  if (idx %in% names(dom_share)) return(unname(dom_share[idx]))
  # linear interpolation between nearest neighbours
  known_days <- as.integer(names(dom_share))
  below <- max(known_days[known_days < day], -Inf)
  above <- min(known_days[known_days > day], Inf)
  if (is.infinite(below)) return(unname(dom_share[as.character(above)]))
  if (is.infinite(above)) return(unname(dom_share[as.character(below)]))
  lo <- unname(dom_share[as.character(below)])
  hi <- unname(dom_share[as.character(above)])
  lo + (hi - lo) * (day - below) / (above - below)
}

#' Recent pace: last complete month's tonnage / its seasonal average
#'
#' "Last complete month" is the most-recent month-end strictly before
#' the reference date (so partial coverage of the reference month never
#' biases the pace ratio toward zero).
#'
#' @keywords internal
recent_pace_ratio <- function(daily, seasonal_norm, ref_date) {
  if (nrow(daily) == 0 || nrow(seasonal_norm) == 0) return(1)
  last_m_floor <- lubridate::floor_date(ref_date, "month") - months(1)
  last_m_end   <- lubridate::ceiling_date(last_m_floor, "month") - 1
  last_m <- lubridate::month(last_m_floor)

  last_tonnage <- daily |>
    dplyr::filter(.data$obs_date >= last_m_floor,
                  .data$obs_date <= last_m_end) |>
    dplyr::summarise(t = sum(.data$tonnage, na.rm = TRUE)) |>
    dplyr::pull(.data$t)

  avg <- seasonal_norm$mean_tonnage[seasonal_norm$month == last_m]
  if (length(avg) != 1 || is.na(avg) || avg <= 0) return(1)
  unname(last_tonnage / avg)
}
