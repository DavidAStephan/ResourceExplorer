#' Load the hand-curated port metadata
#'
#' Reads `inst/extdata/ports_metadata.csv` and upserts it into
#' `mart.dim_port`. In Phase 1 the CSV is header-only, so this is a
#' no-op against an empty table.
#'
#' @param cfg Config list.
#' @return The metadata tibble.
#' @export
load_ports_metadata <- function(cfg) {
  path <- cfg$paths$ports_metadata
  if (!fs::file_exists(path)) {
    stop("ports_metadata.csv not found at ", path, call. = FALSE)
  }

  meta <- readr::read_csv(
    path,
    col_types = readr::cols(
      port_id         = readr::col_character(),
      port_name       = readr::col_character(),
      iso3            = readr::col_character(),
      lat             = readr::col_double(),
      lon             = readr::col_double(),
      commodity_class = readr::col_character(),
      sitc_map        = readr::col_character()
    )
  )

  wh_write("mart_dim_port", meta, cfg)

  log_info("load_ports_metadata -- %d rows", nrow(meta))
  meta
}
