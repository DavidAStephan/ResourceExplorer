#!/usr/bin/env Rscript
## Build the GitHub Pages landing page for resourcetracker.
##
## Reads the latest nowcast values + the per-spec OOS leaderboard from
## the freshly-deployed site dir and emits a polished index.html that
## doesn't look like raw rmarkdown.
##
## Usage:
##   Rscript scripts/build_index.R --site <dir> --today <yyyy-mm-dd> --repo <owner/name>

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(fs)
})

# ---- arg parsing ----
parse_args <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  out  <- list(site = NULL, today = NULL, repo = NULL)
  i <- 1
  while (i <= length(argv)) {
    key <- sub("^--", "", argv[i])
    val <- argv[i + 1]
    out[[key]] <- val
    i <- i + 2
  }
  if (is.null(out$site) || is.null(out$today) || is.null(out$repo)) {
    stop("usage: build_index.R --site <dir> --today <yyyy-mm-dd> --repo <owner/name>")
  }
  out
}
args <- parse_args()
site_dir <- args$site
today    <- args$today
repo     <- args$repo

# ---- helpers ----
fmt_signed <- function(x, digits = 1) {
  if (!is.finite(x)) return("—")
  sign <- if (x >= 0) "+" else "−"
  paste0(sign, formatC(abs(x), digits = digits, format = "f"))
}
escape_html <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x
}

# ---- data load ----
nc_path  <- path(site_dir, "data", "nowcast_current.csv")
bd_path  <- path(site_dir, "data", "bridge_diagnostics.csv")
hist_dir <- path(site_dir, "history")

nc <- if (file_exists(nc_path)) {
  read_csv(nc_path, show_col_types = FALSE)
} else tibble::tibble()
bd <- if (file_exists(bd_path)) {
  read_csv(bd_path, show_col_types = FALSE)
} else tibble::tibble()
csv_files <- if (dir_exists(path(site_dir, "data"))) {
  sort(path_file(dir_ls(path(site_dir, "data"), regexp = "\\.csv$")))
} else character()
hist_files <- if (dir_exists(hist_dir)) {
  sort(path_file(dir_ls(hist_dir, regexp = "\\.html$")), decreasing = TRUE)
} else character()

# ---- card HTML ----
commodity_label <- function(x) {
  switch(x,
         iron_ore = "Iron ore",
         coal     = "Coal",
         tools::toTitleCase(gsub("_", " ", x)))
}
cards_html <- if (nrow(nc) > 0) {
  cards <- vapply(seq_len(nrow(nc)), function(i) {
    r <- nc[i, ]
    sprintf(
      '<div class="headline-card">
  <span class="label">%s &middot; %s</span>
  <div><span class="value">%.1f</span><span class="unit">Mt</span></div>
  <span class="ci">80%% CI &middot; %.1f &ndash; %.1f Mt</span>
  <span class="delta flat">%.0f%% of the quarter observed</span>
</div>',
      escape_html(commodity_label(r$commodity)),
      format(as.Date(r$quarter_end), "%b %Y"),
      r$point_estimate_Mt, r$lower_80, r$upper_80,
      100 * r$share_observed
    )
  }, character(1))
  paste0('<div class="headline-grid">\n', paste(cards, collapse = "\n"),
         "\n</div>")
} else {
  '<div class="callout"><span class="label">Status</span> No nowcast produced this run.</div>'
}

# ---- production-pick summary ----
prod_summary <- if (nrow(bd) > 0 && "production_choice" %in% names(bd)) {
  rows <- bd |>
    mutate(production_choice = as.character(production_choice)) |>
    filter(production_choice %in% c("TRUE", "true")) |>
    transmute(
      commodity = vapply(commodity, commodity_label, character(1)),
      cell = sprintf(
        "<strong>%s</strong>: <code>%s</code> &middot; %.2f&times; naive RMSE",
        escape_html(commodity), escape_html(spec),
        as.numeric(ratio_vs_naive)
      )
    )
  if (nrow(rows) > 0) {
    paste0(
      '<div class="callout"><span class="label">Production model</span> ',
      paste(rows$cell, collapse = " &nbsp;·&nbsp; "),
      "</div>"
    )
  } else ""
} else ""

# ---- history rows ----
history_html <- if (length(hist_files) > 0) {
  rows <- vapply(hist_files, function(f) {
    dt <- sub("\\.html$", "", f)
    label <- tryCatch(format(as.Date(dt), "%e %B %Y"), error = function(e) dt)
    sprintf('<tr><td>%s</td><td><a href="history/%s">View report</a></td></tr>',
            escape_html(label), escape_html(f))
  }, character(1))
  paste0(
    '<table class="history-table"><thead><tr><th>Date</th><th>Briefing</th></tr></thead><tbody>',
    paste(rows, collapse = ""),
    "</tbody></table>"
  )
} else {
  "<p>No prior reports yet.</p>"
}

# ---- CSV downloads ----
csv_list_html <- if (length(csv_files) > 0) {
  items <- vapply(csv_files, function(f) {
    sprintf('<li><a href="data/%s">%s</a></li>',
            escape_html(f), escape_html(f))
  }, character(1))
  paste0('<ul class="downloads">', paste(items, collapse = ""), "</ul>")
} else "<p>—</p>"

# ---- page ----
title <- "Australian Resource Export Volumes"
tagline <- "Weekly nowcast of Australian iron-ore and coal physical-tonnage exports from IMF PortWatch AIS shipping data."
nice_date <- format(as.Date(today), "%e %B %Y")

html <- sprintf('<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>resourcetracker &middot; weekly nowcast</title>
<meta name="description" content="%s">
<link rel="stylesheet" href="style.css">
<link rel="canonical" href="https://%s.github.io/%s/">
</head>
<body>
<main>
  <header class="hero">
    <p class="kicker">resourcetracker &middot; updated %s</p>
    <h1>%s</h1>
    <p class="lede">%s</p>
    <p><a href="latest.html">Read the full briefing &rarr;</a></p>
  </header>

  %s
  %s

  <h2>Report archive</h2>
  %s

  <h2>Raw data</h2>
  <p>Underlying series from this week\'s run, as CSV:</p>
  %s

  <h2>About</h2>
  <p>resourcetracker is a quarterly nowcast for Australian iron-ore and coal exports, built from IMF PortWatch AIS shipping data and the DISR Resources &amp; Energy Quarterly historical data release. Per-commodity bridge regressions are refit weekly against the most recent available data; uncertainty bands shrink as the current quarter is observed.</p>
  <p>Full methodology: <a href="https://github.com/%s/blob/main/docs/METHODOLOGY.md">METHODOLOGY.md</a>. Source code: <a href="https://github.com/%s">%s</a>. Live state branch: <a href="https://github.com/%s/tree/data">data</a>.</p>

  <footer class="site-footer">
    <span>Site rendered %s UTC by the weekly Actions workflow.</span>
    <span><a href="https://github.com/%s/actions/workflows/weekly.yml">View latest run</a></span>
  </footer>
</main>
</body>
</html>
',
  escape_html(tagline),
  tolower(strsplit(repo, "/", fixed = TRUE)[[1]][1]),
  strsplit(repo, "/", fixed = TRUE)[[1]][2],
  nice_date,
  escape_html(title),
  escape_html(tagline),
  cards_html,
  prod_summary,
  history_html,
  csv_list_html,
  repo, repo, repo, repo,
  today, repo
)

writeLines(html, path(site_dir, "index.html"))
cat("wrote ", path(site_dir, "index.html"), "\n", sep = "")
