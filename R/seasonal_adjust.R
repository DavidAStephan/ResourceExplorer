#' X-13-ARIMA-SEATS wrapper for a single monthly series
#'
#' Thin, tidy wrapper around `seasonal::seas()`. Accepts a long tibble
#' (`month_end`, `value`), returns the same tibble with a `value_sa`
#' column. Handles the awkward corners so callers don't have to:
#'
#' - **Short series** (< 36 monthly observations). X-13 refuses to fit;
#'   we fall back to `value_sa = value` and log a warning. 36 months is
#'   X-13's own minimum for the default spec; with only 2 years of data
#'   the seasonal pattern isn't identified anyway.
#' - **Non-positive values**. X-13 is multiplicative by default. If any
#'   value <= 0 we switch to additive (`transform.function = "none"`).
#'   For our data (export values, tonnage), true zeros are rare but can
#'   occur in small-port months.
#' - **Gaps**. X-13 requires a regular ts. We reindex to a full monthly
#'   grid and carry `NA` into `seasonal::seas()`, which accepts them.
#'
#' @param df Tibble with `month_end` (Date, first or last of month) and
#'   `value` (numeric).
#' @param force_additive If `TRUE`, skip the positivity check and use
#'   additive transform unconditionally.
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

  # Reindex to a continuous monthly grid so ts() gets a regular frequency.
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
    logger::log_warn("x13_adjust: {nrow(df)} obs < 36 -- returning original",
                     namespace = "resourcetracker")
    return(dplyr::transmute(df, month_end, value = .data$value,
                            value_sa = .data$value))
  }

  use_additive <- force_additive || any(df$value <= 0, na.rm = TRUE)

  ts_obj <- stats::ts(
    df$value,
    start     = c(lubridate::year(first_m), lubridate::month(first_m)),
    frequency = 12
  )

  sa_values <- tryCatch({
    spec <- if (use_additive) {
      seasonal::seas(ts_obj, transform.function = "none", x11 = "")
    } else {
      seasonal::seas(ts_obj, x11 = "")
    }
    as.numeric(seasonal::final(spec))
  },
  error = function(e) {
    logger::log_warn("x13_adjust failed ({conditionMessage(e)}) -- returning original",
                     namespace = "resourcetracker")
    df$value
  })

  dplyr::transmute(df,
                   month_end = .data$month_end,
                   value     = .data$value,
                   value_sa  = sa_values)
}
