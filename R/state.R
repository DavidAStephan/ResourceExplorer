#' Persist a nowcast run to `mart.nowcast_history`
#'
#' Append-only audit log. One row per `tar_make()`. The previous run's
#' row is fetched by [last_nowcast_run()] to compute "change since last
#' run" for the briefing.
#'
#' @param cfg Config list.
#' @param nowcast_row One-row tibble from [run_nowcast()].
#' @return Invisibly, the inserted row.
#' @export
save_nowcast_run <- function(cfg, nowcast_row) {
  if (nrow(nowcast_row) == 0) {
    logger::log_warn("save_nowcast_run: empty input, skipping",
                     namespace = "resourcetracker")
    return(invisible(nowcast_row))
  }

  row <- tibble::tibble(
    run_timestamp  = nowcast_row$run_timestamp[1],
    quarter_end    = nowcast_row$quarter_end[1],
    point_estimate = nowcast_row$point_estimate[1],
    lower_80       = nowcast_row$lower_80[1],
    upper_80       = nowcast_row$upper_80[1],
    lower_95       = nowcast_row$lower_95[1],
    upper_95       = nowcast_row$upper_95[1],
    share_observed = nowcast_row$share_observed[1]
  )

  con <- warehouse_connect(cfg)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(con,
                    DBI::Id(schema = "mart", table = "nowcast_history"),
                    row, append = TRUE)
  invisible(row)
}

#' Fetch the previous run's nowcast for the same quarter, if any
#'
#' @param cfg Config list.
#' @param current_quarter Quarter-end date.
#' @param exclude_run_timestamp POSIXct to exclude (typically this run).
#' @return One-row tibble or NULL if no prior run exists.
#' @export
last_nowcast_run <- function(cfg, current_quarter,
                             exclude_run_timestamp = NULL) {
  con <- warehouse_connect(cfg, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  sql <- "SELECT * FROM mart.nowcast_history
          WHERE quarter_end = ?
          ORDER BY run_timestamp DESC"
  rows <- DBI::dbGetQuery(con, sql,
                          params = list(format(current_quarter, "%Y-%m-%d")))

  if (!is.null(exclude_run_timestamp)) {
    rows <- rows[rows$run_timestamp != exclude_run_timestamp, , drop = FALSE]
  }
  if (nrow(rows) == 0) return(NULL)
  tibble::as_tibble(rows[1, , drop = FALSE])
}

#' Compute delta between current and previous nowcast
#'
#' @param current One-row tibble from [run_nowcast()].
#' @param previous One-row tibble from [last_nowcast_run()].
#' @return Tibble of deltas, or `NULL` if `previous` is `NULL`.
#' @export
nowcast_delta <- function(current, previous) {
  if (is.null(previous) || nrow(previous) == 0) return(NULL)
  tibble::tibble(
    delta_point     = current$point_estimate - previous$point_estimate,
    delta_lower_80  = current$lower_80       - previous$lower_80,
    delta_upper_80  = current$upper_80       - previous$upper_80,
    delta_lower_95  = current$lower_95       - previous$lower_95,
    delta_upper_95  = current$upper_95       - previous$upper_95,
    share_now       = current$share_observed,
    share_prior     = previous$share_observed,
    hours_since     = as.numeric(difftime(current$run_timestamp,
                                          previous$run_timestamp,
                                          units = "hours"))
  )
}
