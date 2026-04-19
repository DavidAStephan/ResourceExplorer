test_that("warehouse_init_schema creates expected tables", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse  = file.path(tmp, "wh.duckdb"),
      schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
      logs       = file.path(tmp, "logs")
    )
  )

  warehouse_init_schema(cfg)

  con <- warehouse_connect(cfg, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  raw <- DBI::dbGetQuery(con,
    "SELECT table_name FROM information_schema.tables WHERE table_schema='raw'"
  )
  mart <- DBI::dbGetQuery(con,
    "SELECT table_name FROM information_schema.tables WHERE table_schema='mart'"
  )

  expect_setequal(
    raw$table_name,
    c("portwatch_tonnage_daily", "abs_5368_monthly",
      "abs_5302_quarterly", "fred_prices_daily")
  )
  expect_setequal(
    mart$table_name,
    c("dim_port", "crosswalk_sitc", "ingest_runs",
      "nowcast_history", "latest_anomalies")
  )
})

test_that("warehouse_init_schema is idempotent", {
  tmp <- withr::local_tempdir()
  cfg <- list(
    paths = list(
      warehouse  = file.path(tmp, "wh.duckdb"),
      schema_sql = system.file("sql", "schema.sql", package = "resourcetracker"),
      logs       = file.path(tmp, "logs")
    )
  )
  expect_no_error(warehouse_init_schema(cfg))
  expect_no_error(warehouse_init_schema(cfg))
})
