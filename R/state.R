#' Persist a nowcast run to `mart_nowcast_history`
#'
#' Append-only audit log. One row per (run, commodity) combination —
#' the `run_nowcast()` output now has one row per commodity, so each
#' pipeline run writes `length(commodities)` rows.
#'
#' @param cfg Config list.
#' @param nowcast_rows Tibble from [run_nowcast()] (one row per commodity).
#' @return Invisibly, the inserted rows.
#' @export
save_nowcast_run <- function(cfg, nowcast_rows) {
  if (nrow(nowcast_rows) == 0L) {
    log_warn("save_nowcast_run: empty input, skipping")
    return(invisible(nowcast_rows))
  }

  # `horizon` was added 2026-05-21 to distinguish current-quarter (h=0)
  # from one-quarter-ahead (h=1) nowcasts. Existing history rows
  # don't carry the column; default to 0 for back-compat appending.
  if (!"horizon" %in% names(nowcast_rows)) {
    nowcast_rows$horizon <- 0L
  }
  rows <- nowcast_rows |>
    dplyr::transmute(
      run_timestamp  = .data$run_timestamp,
      commodity      = .data$commodity,
      quarter_end    = .data$quarter_end,
      horizon        = .data$horizon,
      point_estimate = .data$point_estimate_Mt,
      lower_80       = .data$lower_80,
      upper_80       = .data$upper_80,
      lower_95       = .data$lower_95,
      upper_95       = .data$upper_95,
      share_observed = .data$share_observed
    )

  wh_append("mart_nowcast_history", rows, cfg,
            keys = c("run_timestamp", "commodity", "quarter_end", "horizon"))
  invisible(rows)
}

#' Fetch the previous run's nowcast for a specific commodity + quarter
#'
#' @param cfg Config list.
#' @param commodity Commodity name (e.g. "iron_ore").
#' @param current_quarter Quarter-end date.
#' @param exclude_run_timestamp POSIXct to exclude (typically this run).
#' @return One-row tibble or NULL if no prior run exists.
#' @export
last_nowcast_run <- function(cfg, commodity, current_quarter,
                             exclude_run_timestamp = NULL) {
  hist <- wh_read("mart_nowcast_history", cfg)
  if (is.null(hist) || nrow(hist) == 0L) return(NULL)

  rows <- hist |>
    dplyr::filter(.data$commodity   == commodity,
                  .data$quarter_end == as.Date(current_quarter)) |>
    dplyr::arrange(dplyr::desc(.data$run_timestamp))

  if (!is.null(exclude_run_timestamp)) {
    rows <- rows[rows$run_timestamp != exclude_run_timestamp, , drop = FALSE]
  }
  if (nrow(rows) == 0L) return(NULL)
  tibble::as_tibble(rows[1, , drop = FALSE])
}

#' Compute delta between current and previous nowcast for one commodity
#'
#' @param current One-row tibble filtered from [run_nowcast()].
#' @param previous One-row tibble from [last_nowcast_run()].
#' @return Tibble of deltas, or `NULL` if `previous` is `NULL`.
#' @export
nowcast_delta <- function(current, previous) {
  if (is.null(previous) || nrow(previous) == 0L) return(NULL)
  tibble::tibble(
    commodity       = current$commodity,
    delta_point     = current$point_estimate_Mt - previous$point_estimate,
    delta_lower_80  = current$lower_80       - previous$lower_80,
    delta_upper_80  = current$upper_80       - previous$upper_80,
    delta_lower_95  = current$lower_95       - previous$lower_95,
    delta_upper_95  = current$upper_95       - previous$upper_95,
    share_now       = current$share_observed,
    share_prior    = previous$share_observed,
    hours_since    = as.numeric(difftime(current$run_timestamp,
                                          previous$run_timestamp,
                                          units = "hours"))
  )
}
