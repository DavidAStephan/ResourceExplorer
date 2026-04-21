#' STL-based seasonal adjustment for a single monthly series
#'
#' Wraps `stats::stl()` with `s.window = "periodic"` and `robust = TRUE`.
#' Accepts a long tibble (`month_end`, `value`), returns the same tibble
#' with a `value_sa` column. Handles the awkward corners:
#'
#' - **Short series** (< 36 monthly observations). STL needs at least two
#'   full seasonal cycles; with <36 months the pattern isn't identified.
#'   Fall back to `value_sa = value` and log a warning.
#' - **Non-positive values**. Multiplicative adjustment requires logs of
#'   positive values. If any value <= 0 we switch to additive
#'   (subtract the STL seasonal component).
#' - **Gaps**. STL needs a regular `ts`. We reindex to a full monthly grid
#'   and linearly interpolate single-month gaps; longer NA runs carry
#'   through unchanged.
#'
#' Replaced `seasonal::seas()` (X-13-ARIMA-SEATS) because the `{seasonal}`
#' package and its x13 Fortran binary are not on the work-laptop
#' allow-list. STL loses X-13's calendar and trading-day adjustments;
#' acceptable for Phase 2. If residual-seasonality diagnostics flag it
#' later, add a working-days-per-month regressor upstream.
#'
#' @param df Tibble with `month_end` (Date, first or last of month) and
#'   `value` (numeric).
#' @param force_additive If `TRUE`, skip the positivity check and use
#'   additive decomposition unconditionally.
#' @return The input tibble with an added `value_sa` numeric column.
#' @export
x13_adjust <- function(df, force_additive = FALSE) {
  stopifnot(all(c("month_end", "value") %in% names(df)))
  if (nrow(df) == 0) {
    return(dplyr::mutate(df, value_sa = double()))
  }

  df <- df |>
    dplyr::arrange(.data$month_end) |>
    dplyr::mutate(value = as.numeric(.data$value))

  first_m <- lubridate::floor_date(min(df$month_end), "month")
  last_m  <- lubridate::floor_date(max(df$month_end), "month")
  grid <- tibble::tibble(month_floor = seq(first_m, last_m, by = "month"))
  df <- df |>
    dplyr::mutate(month_floor = lubridate::floor_date(.data$month_end, "month")) |>
    dplyr::right_join(grid, by = "month_floor") |>
    dplyr::arrange(.data$month_floor) |>
    dplyr::mutate(
      month_end = lubridate::ceiling_date(.data$month_floor, "month") - 1
    )

  if (nrow(df) < 36) {
    log_warn("x13_adjust: %d obs < 36 -- returning original", nrow(df))
    return(dplyr::transmute(df,
                            month_end = .data$month_end,
                            value     = .data$value,
                            value_sa  = .data$value))
  }

  use_additive <- force_additive || any(df$value <= 0, na.rm = TRUE)

  sa_values <- tryCatch(
    .stl_adjust_core(df$value, first_m, use_additive),
    error = function(e) {
      log_warn("x13_adjust failed (%s) -- returning original",
               conditionMessage(e))
      df$value
    }
  )

  dplyr::transmute(df,
                   month_end = .data$month_end,
                   value     = .data$value,
                   value_sa  = sa_values)
}

#' @keywords internal
.stl_adjust_core <- function(v, first_m, use_additive) {
  # STL can't handle NAs; interpolate single-month gaps with a linear
  # fill, leave longer runs alone (they'll return NA SA values, which is
  # honest).
  v_filled <- .linear_interp(v)

  z <- if (use_additive) v_filled else log(v_filled)

  ts_obj <- stats::ts(
    z,
    start     = c(lubridate::year(first_m), lubridate::month(first_m)),
    frequency = 12
  )

  stl_fit <- stats::stl(
    ts_obj,
    s.window = "periodic",
    robust   = TRUE,
    na.action = stats::na.pass
  )
  seas <- as.numeric(stl_fit$time.series[, "seasonal"])

  if (use_additive) {
    v - seas
  } else {
    # log-space deseasonalisation; restore scale
    v / exp(seas)
  }
}

#' Linear interpolation of isolated NAs in a numeric vector
#' @keywords internal
.linear_interp <- function(v) {
  n <- length(v)
  idx <- which(!is.na(v))
  if (length(idx) < 2L) return(v)
  stats::approx(x = idx, y = v[idx], xout = seq_len(n), rule = 1L)$y
}
