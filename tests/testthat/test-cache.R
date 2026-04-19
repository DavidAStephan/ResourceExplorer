test_that("with_cache returns fresh on first call, tags status", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(cache = tmp))

  got <- with_cache(cfg, "src", "key",
                    fetcher = function() tibble::tibble(x = 1:3))

  expect_equal(attr(got, "cache_status"), "fresh")
  expect_equal(nrow(got), 3)
  expect_true(fs::file_exists(file.path(tmp, "src", "key.rds")))
})

test_that("with_cache falls back to cache on fetcher error", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(cache = tmp))

  with_cache(cfg, "src", "key", function() tibble::tibble(x = 1:3))

  got <- with_cache(cfg, "src", "key",
                    fetcher = function() stop("network down"))

  expect_equal(attr(got, "cache_status"), "stale")
  expect_equal(nrow(got), 3)
})

test_that("with_cache errors hard when fetch fails and no cache exists", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(cache = tmp))

  expect_error(
    with_cache(cfg, "src", "missing", function() stop("x")),
    "no cache available"
  )
})

test_that("cache key is filesystem-sanitised", {
  tmp <- withr::local_tempdir()
  cfg <- list(paths = list(cache = tmp))
  p <- cache_path(cfg, "src", "weird/key:with*bad?chars")
  expect_false(grepl("[/:*?]", basename(p)))
})
