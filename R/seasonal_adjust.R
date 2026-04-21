#' STL-based quarterly seasonal adjustment for a single series
#'
#' Wraps `stats::stl()` with `s.window = "periodic"` and `robust = TRUE`,
#' frequency = 4 (quarters per year). Accepts a long tibble with columns
#' `quarter_end` (Date, last day of quarter) and `value` (numeric),
#' returns the same tibble with a `value_sa` column.
#'
#' Handles the awkward corners:
#'
#' - **Short series** (< 8 quarterly observations = 2 full cycles). STL
#'   needs at least two periods to identify the seasonal. Fall back to
#'   `value_sa = value` and log a warning.
#' - **Non-positive values.** Multiplicative adjustment requires logs of
#'   positive values. If any `value <= 0` we switch to additive.
#' - **Gaps.** STL needs a regular `ts`. We reindex to a full quarterly
#'   grid and linearly interpolate single-quarter gaps.
#'
#' Replaced X-13-ARIMA-SEATS (`{seasonal}`) because its Fortran binary is
#' not on the work-laptop allow-list. STL loses X-13's calendar /
#' trading-day adjustments, but at quarterly frequency and for bulk
#' commodity tonnage the trading-day signal is tiny.
#'
#' @param df Tibble with `quarter_end` (Date) and `value` (numeric).
#' @param force_additive If `TRUE`, skip positivity check and use
#'   additive decomposition unconditionally.
#' @return The input tibble with an added `value_sa` numeric column.
#' @export
stl_quarterly_adjust <- function(df, force_additive = FALSE) {
  stopifnot(all(c("quarter_end", "value") %in% names(df)))
  if (nrow(df) == 0) {
    return(dplyr::mutate(df, value_sa = double()))
  }

  df <- df |>
    dplyr::arrange(.data$quarter_end) |>
    dplyr::mutate(value = as.numeric(.data$value))

  first_q <- lubridate::floor_date(min(df$quarter_end), "quarter")
  last_q  <- lubridate::floor_date(max(df$quarter_end), "quarter")
  grid <- tibble::tibble(
    quarter_floor = seq(first_q, last_q, by = "quarter")
  )
  df <- df |>
    dplyr::mutate(
      quarter_floor = lubridate::floor_date(.data$quarter_end, "quarter")
    ) |>
    dplyr::right_join(grid, by = "quarter_floor") |>
    dplyr::arrange(.data$quarter_floor) |>
    dplyr::mutate(
      quarter_end = lubridate::ceiling_date(.data$quarter_floor, "quarter") - 1
    )

  if (nrow(df) < 8L) {
    log_warn("stl_quarterly_adjust: %d obs < 8 -- returning original", nrow(df))
    return(dplyr::transmute(df,
                            quarter_end = .data$quarter_end,
                            value       = .data$value,
                            value_sa    = .data$value))
  }

  use_additive <- force_additive || any(df$value <= 0, na.rm = TRUE)

  sa_values <- tryCatch(
    .stl_adjust_core_quarterly(df$value, first_q, use_additive),
    error = function(e) {
      log_warn("stl_quarterly_adjust failed (%s) -- returning original",
               conditionMessage(e))
      df$value
    }
  )

  dplyr::transmute(df,
                   quarter_end = .data$quarter_end,
                   value       = .data$value,
                   value_sa    = sa_values)
}

#' @keywords internal
.stl_adjust_core_quarterly <- function(v, first_q, use_additive) {
  v_filled <- .linear_interp(v)
  z <- if (use_additive) v_filled else log(v_filled)

  ts_obj <- stats::ts(
    z,
    start     = c(lubridate::year(first_q), lubridate::quarter(first_q)),
    frequency = 4
  )

  stl_fit <- stats::stl(
    ts_obj,
    s.window  = "periodic",
    robust    = TRUE,
    na.action = stats::na.pass
  )
  seas <- as.numeric(stl_fit$time.series[, "seasonal"])

  if (use_additive) v - seas else v / exp(seas)
}

#' @keywords internal
.linear_interp <- function(v) {
  n <- length(v)
  idx <- which(!is.na(v))
  if (length(idx) < 2L) return(v)
  stats::approx(x = idx, y = v[idx], xout = seq_len(n), rule = 1L)$y
}
