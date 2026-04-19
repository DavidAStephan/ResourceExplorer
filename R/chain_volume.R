#' Implicit price deflator from ABS 5302.0
#'
#' `D_Q = current_Q / chainvol_Q`. Returns one row per quarter-end.
#' Both numerator and denominator come from the same release so the
#' deflator is internally consistent.
#'
#' @param abs_5302 Tibble from [fetch_abs_5302()].
#' @param series_id Which 5302.0 series to use (goods credits).
#' @return Tibble: `quarter_end`, `deflator`.
#' @export
implicit_deflator <- function(abs_5302,
                              series_id = NULL) {
  dat <- abs_5302 |>
    dplyr::filter(!is.na(.data$value_current_aud_m),
                  !is.na(.data$value_chainvol_aud_m),
                  .data$value_chainvol_aud_m > 0)

  if (!is.null(series_id)) {
    dat <- dplyr::filter(dat, .data$series_id == !!series_id)
  }

  dat |>
    dplyr::group_by(.data$quarter_end) |>
    dplyr::summarise(
      current  = sum(.data$value_current_aud_m,  na.rm = TRUE),
      chainvol = sum(.data$value_chainvol_aud_m, na.rm = TRUE),
      .groups  = "drop"
    ) |>
    dplyr::mutate(deflator = .data$current / .data$chainvol) |>
    dplyr::filter(is.finite(.data$deflator)) |>
    dplyr::transmute(quarter_end, deflator)
}

#' Apply chain-volume conversion to current-price quarterly predictions
#'
#' Uses the trailing mean of the last `lookback` observed quarterly
#' deflators as the forecast deflator for the prediction quarter. This
#' reflects the fact that the *same-quarter* deflator is not available
#' until ABS publishes the quarterly release -- exactly the situation a
#' nowcast finds itself in.
#'
#' @param predictions_curr Tibble with `quarter_end`, `value_current_aud_m`.
#' @param deflators Tibble from [implicit_deflator()].
#' @param lookback Integer number of trailing quarters to average.
#' @return Tibble: `quarter_end`, `value_current_aud_m`,
#'   `deflator_forecast`, `value_chainvol_aud_m`.
#' @export
apply_chain_volume <- function(predictions_curr, deflators, lookback = 4L) {
  def_sorted <- dplyr::arrange(deflators, .data$quarter_end)

  purrr::map_dfr(
    seq_len(nrow(predictions_curr)),
    function(i) {
      q <- predictions_curr$quarter_end[i]
      recent <- dplyr::filter(def_sorted, .data$quarter_end < q)
      if (nrow(recent) == 0) {
        d <- NA_real_
      } else {
        tail_n <- utils::tail(recent$deflator, lookback)
        d <- mean(tail_n, na.rm = TRUE)
      }
      tibble::tibble(
        quarter_end          = q,
        value_current_aud_m  = predictions_curr$value_current_aud_m[i],
        deflator_forecast    = d,
        value_chainvol_aud_m = predictions_curr$value_current_aud_m[i] / d
      )
    }
  )
}
