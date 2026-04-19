#' Initialise the logger
#'
#' Configures `{logger}` to write to both stdout and a dated log file in
#' the configured logs directory. Safe to call repeatedly -- each call
#' replaces the previous appender configuration.
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
  level <- switch(
    toupper(level_str),
    TRACE = logger::TRACE, DEBUG = logger::DEBUG, INFO = logger::INFO,
    WARN  = logger::WARN,  ERROR = logger::ERROR, logger::INFO
  )

  logger::log_threshold(level)
  logger::log_appender(
    logger::appender_tee(log_file),
    namespace = "resourcetracker"
  )
  logger::log_layout(logger::layout_glue_colors)
  invisible(log_file)
}

`%||%` <- function(x, y) if (is.null(x)) y else x
