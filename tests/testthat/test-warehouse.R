## Warehouse: RDS-backed table I/O.

test_that("warehouse_init_schema creates the warehouse directory", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(warehouse_dir = file.path(tmp, "wh"),
                           logs = file.path(tmp, "logs")))
  dir <- warehouse_init_schema(cfg)
  expect_true(fs::dir_exists(dir))
  expect_equal(normalizePath(dir), normalizePath(file.path(tmp, "wh")))
})

test_that("wh_write + wh_read round-trip preserves a tibble", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(warehouse_dir = file.path(tmp, "wh")))
  t <- tibble::tibble(x = 1:3, y = c("a", "b", "c"), d = as.Date("2024-01-01") + 0:2)
  wh_write("smoke", t, cfg)
  back <- wh_read("smoke", cfg)
  expect_s3_class(back, "tbl_df")
  expect_equal(back, t)
})

test_that("wh_read returns NULL for a missing table", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(warehouse_dir = file.path(tmp, "wh")))
  expect_null(wh_read("never_written", cfg))
})

test_that("wh_append dedupes by key, keeping the latest occurrence", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(warehouse_dir = file.path(tmp, "wh")))
  wh_write("t", tibble::tibble(id = c(1, 2), v = c("old_1", "old_2")), cfg)
  wh_append("t", tibble::tibble(id = c(2, 3), v = c("new_2", "new_3")), cfg,
            keys = "id")
  back <- wh_read("t", cfg)
  expect_equal(nrow(back), 3)
  expect_equal(back$v[back$id == 2], "new_2")
})

test_that("wh_write rejects unsafe table names", {
  cfg <- list(paths = list(warehouse_dir = tempfile("wh_")))
  expect_error(wh_write("no/slashes", tibble::tibble(x = 1), cfg),
               "\\[A-Za-z0-9_\\]\\+")
})
