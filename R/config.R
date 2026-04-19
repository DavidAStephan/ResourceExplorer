#' Load project configuration
#'
#' Reads `config.yml` from the project root using the `{config}` package.
#' All downstream targets should pull paths and parameters from the
#' returned list rather than hard-coding.
#'
#' @param path Path to `config.yml`. Defaults to the project root.
#' @param profile Config profile. Defaults to `"default"`.
#' @return A named list of configuration values.
#' @export
load_config <- function(path = "config.yml", profile = "default") {
  if (!fs::file_exists(path)) {
    stop("config.yml not found at ", path, call. = FALSE)
  }
  cfg <- config::get(file = path, config = profile)

  # Ensure expected top-level keys exist so downstream code can be terse.
  required <- c("paths", "sample", "commodities", "portwatch", "abs",
                "fred", "nowcast", "logging")
  missing <- setdiff(required, names(cfg))
  if (length(missing)) {
    stop("config.yml missing keys: ", paste(missing, collapse = ", "),
         call. = FALSE)
  }
  cfg
}
