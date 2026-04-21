#' Write an ingest-run row to `mart.ingest_runs`
#'
#' Best-effort audit trail for every external fetch. Errors from this
#' function itself are swallowed so they can't mask real pipeline errors.
#'
#' @param cfg Config list.
#' @param source Source identifier (`"portwatch"`, `"abs_5368"`, ...).
#' @param started_at POSIXct start time.
#' @param rows_written Integer row count.
#' @param status One of `"ok"`, `"cached"`, `"error"`.
#' @param error_message Optional error string.
#' @return Invisibly, the run_id.
#' @keywords internal
log_ingest_run <- function(cfg, source, started_at,
                           rows_written = NA_integer_,
                           status        = "ok",
                           error_message = NA_character_) {
  tryCatch({
    run_id <- paste(
      format(started_at, "%Y%m%dT%H%M%S"),
      source,
      sample(letters, 6, replace = TRUE) |> paste(collapse = ""),
      sep = "_"
    )
    row <- tibble::tibble(
      run_id        = run_id,
      source        = source,
      started_at    = started_at,
      finished_at   = Sys.time(),
      rows_written  = as.integer(rows_written),
      status        = status,
      error_message = error_message
    )
    wh_append("mart_ingest_runs", row, cfg, keys = "run_id")
    invisible(run_id)
  },
  error = function(e) {
    log_warn("log_ingest_run swallowed error: %s", conditionMessage(e))
    invisible(NA_character_)
  })
}
