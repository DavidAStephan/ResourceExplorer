#' Load project configuration
#'
#' Reads an R-file config (a script whose final expression is a list).
#' The previous YAML-backed config was dropped when the package moved off
#' the `config` / `yaml` dependencies (not on the work-laptop allow-list).
#'
#' @param path Path to the R config file. Defaults to `config.R` in the
#'   working directory.
#' @return A named list of configuration values.
#' @export
load_config <- function(path = "config.R") {
  if (!fs::file_exists(path)) {
    stop("config.R not found at ", path, call. = FALSE)
  }
  # Use a fresh empty env so sourcing can't accidentally leak symbols.
  env <- new.env(parent = baseenv())
  cfg <- source(path, local = env)$value
  if (!is.list(cfg)) {
    stop("config.R must have a list as its final expression", call. = FALSE)
  }

  required <- c("paths", "sample", "commodities", "portwatch", "abs",
                "fred", "nowcast", "logging")
  missing <- setdiff(required, names(cfg))
  if (length(missing)) {
    stop("config.R missing keys: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  cfg
}
