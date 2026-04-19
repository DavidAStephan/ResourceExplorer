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

  con <- warehouse_connect(cfg)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DELETE FROM mart.dim_port")
  if (nrow(meta) > 0) {
    DBI::dbWriteTable(con, DBI::Id(schema = "mart", table = "dim_port"),
                      meta, append = TRUE)
  }

  logger::log_info("load_ports_metadata -- {nrow(meta)} rows",
                   namespace = "resourcetracker")
  meta
}
