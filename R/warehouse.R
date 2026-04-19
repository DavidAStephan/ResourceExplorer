#' Open a DuckDB connection to the warehouse
#'
#' Callers are responsible for closing the connection with
#' `DBI::dbDisconnect(con, shutdown = TRUE)`.
#'
#' @param cfg Config list from [load_config()].
#' @param read_only Open the database read-only. Default `FALSE`.
#' @return A `DBIConnection` to the DuckDB warehouse.
#' @export
warehouse_connect <- function(cfg, read_only = FALSE) {
  path <- cfg$paths$warehouse
  fs::dir_create(fs::path_dir(path))
  DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = read_only)
}

#' Initialise the warehouse schema
#'
#' Applies the DDL in `inst/sql/schema.sql` to the DuckDB file named in
#' `cfg$paths$warehouse`. Idempotent -- safe to re-run.
#'
#' @param cfg Config list from [load_config()].
#' @return The warehouse path, invisibly, as a string. Returning a scalar
#'   lets downstream `{targets}` targets depend on this side-effect.
#' @export
warehouse_init_schema <- function(cfg) {
  sql_path <- cfg$paths$schema_sql
  if (!fs::file_exists(sql_path)) {
    stop("schema.sql not found at ", sql_path, call. = FALSE)
  }
  ddl <- readr::read_file(sql_path)

  con <- warehouse_connect(cfg, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # DuckDB accepts multi-statement scripts via dbExecute when split on ';'.
  stmts <- strsplit(ddl, ";\\s*\\n", perl = TRUE)[[1]]
  stmts <- stmts[nzchar(trimws(stmts))]
  for (s in stmts) DBI::dbExecute(con, s)

  invisible(cfg$paths$warehouse)
}
