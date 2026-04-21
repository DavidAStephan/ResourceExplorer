#' Initialise the logger
#'
#' Configures the built-in base-R logger to write to both stderr and a
#' dated log file in `cfg$paths$logs`. Safe to call repeatedly.
#'
#' Replaced the `{logger}` package (not on the work-laptop allow-list)
#' with a small hand-rolled logger that keeps the same call-site surface
#' (`log_info`, `log_warn`, `log_error`, `log_debug`, `log_trace`).
#'
#' Messages are `sprintf`-formatted: pass a format string and values as
#' additional args. No `glue`-style interpolation (keeps dependencies
#' trivial). Level precedence TRACE < DEBUG < INFO < WARN < ERROR.
#'
#' @param cfg Config list from [load_config()].
#' @return Invisibly, the path of the current log file.
#' @keywords internal
init_logger <- function(cfg) {
  logs_dir <- cfg$paths$logs %||% "logs"
  fs::dir_create(logs_dir)
  log_file <- fs::path(logs_dir, paste0(format(Sys.Date()), ".log"))

  level_env <- Sys.getenv("RESOURCETRACKER_LOG_LEVEL", unset = "")
  level_str <- if (nzchar(level_env)) level_env else (cfg$logging$level %||% "INFO")

  .rt_logger_state$threshold <- .rt_level_num(level_str)
  .rt_logger_state$file      <- log_file
  invisible(log_file)
}

.rt_logger_state <- new.env(parent = emptyenv())
.rt_logger_state$threshold <- 20L   # INFO default
.rt_logger_state$file      <- NULL

.rt_level_num <- function(name) {
  switch(
    toupper(name),
    TRACE = 5L, DEBUG = 10L, INFO = 20L,
    WARN = 30L, WARNING = 30L, ERROR = 40L,
    20L
  )
}

.rt_log <- function(level_name, fmt, ...) {
  if (.rt_level_num(level_name) < .rt_logger_state$threshold) return(invisible(NULL))
  msg <- tryCatch(
    sprintf(fmt, ...),
    error = function(e) paste(c(fmt, ...), collapse = " ")
  )
  line <- sprintf("%s [%s] %s",
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                  toupper(level_name), msg)
  # stderr mirror
  message(line)
  # file mirror (best-effort; swallow both errors AND warnings so logging
  # never aborts work even if the dated log path has been cleaned up under
  # us -- common in tests that use a tempdir and then unwind).
  f <- .rt_logger_state$file
  if (!is.null(f)) {
    tryCatch(
      suppressWarnings(cat(line, "\n", sep = "", file = f, append = TRUE)),
      error = function(e) NULL
    )
  }
  invisible(NULL)
}

#' @keywords internal
log_trace <- function(fmt, ...) .rt_log("TRACE", fmt, ...)
#' @keywords internal
log_debug <- function(fmt, ...) .rt_log("DEBUG", fmt, ...)
#' @keywords internal
log_info  <- function(fmt, ...) .rt_log("INFO",  fmt, ...)
#' @keywords internal
log_warn  <- function(fmt, ...) .rt_log("WARN",  fmt, ...)
#' @keywords internal
log_error <- function(fmt, ...) .rt_log("ERROR", fmt, ...)

`%||%` <- function(x, y) if (is.null(x)) y else x
