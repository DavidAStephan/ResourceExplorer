## DISR REQ Table 16 parser tests.
## We build a minimal 8-column synthetic xlsx with the same row layout as
## the real Sheet 16: logo row 1, header date row 7, data rows 19 (iron_ore
## kt), 47 & 48 (coal met + thermal Mt).

.synthetic_t16 <- function(path) {
  skip_if_not_installed("openxlsx")
  library(openxlsx)
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "16")
  # Build a 55 x 11 matrix of 0s (not NA -- openxlsx trims trailing NAs),
  # then poke in specific cells.
  m <- matrix(0, nrow = 55, ncol = 11)
  # Data columns 8:11 = 4 quarters of 2023, date serial numbers (excel epoch)
  dates <- as.numeric(as.Date(c("2023-03-01","2023-06-01",
                                 "2023-09-01","2023-12-01")) -
                       as.Date("1899-12-30"))
  m[7, 8:11]  <- dates
  m[19, 8:11] <- c(230000, 240000, 235000, 245000)  # iron_ore kt
  m[47, 8:11] <- c(40, 38, 42, 41)                   # coal met Mt
  m[48, 8:11] <- c(55, 56, 60, 58)                   # coal thermal Mt
  openxlsx::writeData(wb, "16", m, colNames = FALSE, rowNames = FALSE)
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  invisible(path)
}

test_that("parse_disr_table16 extracts iron_ore and coal in Mt", {
  skip_if_not_installed("openxlsx")
  skip_if_not_installed("readxl")

  tmp <- tempfile(fileext = ".xlsx")
  on.exit(unlink(tmp), add = TRUE)
  .synthetic_t16(tmp)

  out <- parse_disr_table16(
    tmp, sheet = "16",
    rows = list(
      iron_ore = list(rows = 19L,         unit = "kt"),
      coal     = list(rows = c(47L, 48L), unit = "Mt")
    )
  )

  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 8L)  # 4 quarters x 2 commodities
  expect_setequal(unique(out$commodity), c("iron_ore", "coal"))
  expect_named(out, c("quarter_end", "commodity", "tonnes_Mt"))

  iron_q1 <- dplyr::filter(out, commodity == "iron_ore",
                            quarter_end == as.Date("2023-03-31"))
  expect_equal(iron_q1$tonnes_Mt, 230)  # 230000 kt -> 230 Mt

  coal_q1 <- dplyr::filter(out, commodity == "coal",
                            quarter_end == as.Date("2023-03-31"))
  expect_equal(coal_q1$tonnes_Mt, 40 + 55)  # met + thermal
})

test_that("parse_disr_table16 handles all-NA data rows as zero-row output", {
  skip_if_not_installed("openxlsx")
  tmp <- tempfile(fileext = ".xlsx")
  on.exit(unlink(tmp), add = TRUE)
  library(openxlsx)
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "16")
  m <- matrix(0, nrow = 55, ncol = 11)  # zeros as placeholder
  dates <- as.numeric(as.Date(c("2023-03-01","2023-06-01",
                                 "2023-09-01","2023-12-01")) -
                       as.Date("1899-12-30"))
  m[7, 8:11] <- dates
  # Row 19 stays as zeros
  m[19, 8:11] <- NA
  openxlsx::writeData(wb, "16", m, colNames = FALSE, rowNames = FALSE)
  openxlsx::saveWorkbook(wb, tmp, overwrite = TRUE)

  out <- parse_disr_table16(tmp, sheet = "16",
                             rows = list(iron_ore = list(rows = 19L,
                                                          unit = "kt")))
  expect_equal(nrow(out), 0L)
})
