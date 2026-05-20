# Roadmap

Living document of follow-up work, ordered by ROI. Tiers 1, 2, 3, and 4
from the 2026-05 review have all landed (see commit history + the
Completed section). Open items below are the next layer down — things
that would extend the system but aren't on the immediate path.

## Open / future

### Deeper external demand signal

Tier 4 #1 shipped a World-Bank Pink Sheet price ingest + `price_aug`
candidate spec on 2026-05-21; the bench evaluated it at the next
weekly run. Result: price didn't beat tonnage-only specs for any
commodity (price_aug RMSE worse than `bojo` / `midas` / `aggregate`
across iron-ore, coal_met, coal_thermal). The framework still keeps it
in the bench so future shifts in the relationship are picked up
automatically.

What would actually move the needle is a *demand* indicator (not a
price), which is harder to ingest:

- **China crude steel production** (monthly, NBS-published, ~3-week
  lag). Direct iron-ore demand. No clean free API; would need
  scraping or a paid API.
- **China power generation** (monthly, NBS). Thermal coal demand.
  Same access constraint.
- **Baltic Dry Index** (daily). Dry-bulk shipping freight rate — a
  near-real-time market gauge of bulk demand. No public API; the
  data is paywalled.

Effort to add any one: ~1 day for ingestion (the slot in the bridge
bench already exists). Adding all three: ~3 days. Worth doing only
when there's a budget for a data subscription or someone wants to
maintain a scraper.

### LNG re-scope — final note

This is **deferred indefinitely**, not just unstarted.

The original 2026-04-21 finding stands: PortWatch tanker-tonnage at
LNG ports has near-zero correlation with ABS LNG export volumes at
quarterly grain. Australian LNG is contract-dominated — vessels arrive
on schedule regardless of spot-price dynamics, so tonnage is an output
of contracts rather than an indicator of them.

The plausible workaround would model LNG via AIS *destination-share*
(% of tanker tonnage routed to Japan / Korea / China each quarter),
since destinations encode the contract structure implicitly. But:

1. The IMF PortWatch FeatureServer we consume **doesn't expose
   destination at the daily-tonnage layer** — it gives port-day
   tonnage broken out by vessel type, without per-voyage routing.
2. To get destinations we'd need a different AIS data source
   (commercial — VesselFinder, Spire, Kpler, MarineTraffic), and that
   adds a paywalled dependency the project has deliberately avoided.

So LNG is not addressable within the current "free public data only"
constraint. If the constraint relaxes, the work is roughly:

- New ingest pulling per-vessel destination data
- Quarterly destination-share derivation per Australian LNG port
- New `lng_destshare` candidate spec
- ~2-3 weeks of dev + validation, not days

Until then, the iron-ore + coal_met + coal_thermal panel is the live
scope.

## Anti-list — things I'd recommend NOT doing

Documenting these so they don't quietly bubble up as "we should also…"
items in the future:

- **Don't redesign the Pages site again.** It's done; the design
  system is the current source of truth for the look. Subsequent
  changes should fit *into* the existing tokens (colours, spacing,
  components), not invent new ones.
- **Don't add ML / neural-net candidates.** At N ≈ 23 training
  quarters, anything more complex than the current linear bench will
  overfit. The combination bench already gives us the diversity the
  data can support.
- **Don't migrate the warehouse to DuckDB / Postgres.** The rds +
  `data` branch pattern is genuinely well-suited to this dataset
  size. The constraint that originally pushed away from DuckDB (work-
  laptop allowlist) is still real.
- **Don't add more candidate specs unless they bring new
  information.** A fourth variant on the same PortWatch signal
  (e.g. an Almon-polynomial MIDAS) won't help; an indicator from a
  different data source (Tier 4 #1) will.

## Maintenance

This file is hand-maintained. Mark items as done by moving them under a
"Completed" section at the bottom with a date, or by deleting them and
adding a one-liner to the relevant commit message.

## Completed

### 2026-05-20

- **Tier 1 cleanups** (PR #12): tidyselect lint sweep, removed the
  vestigial LNG ingestion pathway, WoW delta + enriched archive table
  on the landing page, failure-issue body now includes the log tail.
- **Tier 2 research** (PR #13): coal split into `coal_met` +
  `coal_thermal` (separate bridges on shared PortWatch RHS), new
  `lagged` candidate spec (Adland-Jia-Strandenes 2017), Chow test for
  structural break at training-sample midpoint. Coal_met turned out to
  be the most predictable commodity in the panel (RMSE/naive 0.49,
  MIDAS wins).
- **run.R force-write bug** (PR #14): `--force` rerun used to recompute
  in memory but skip the rds write when the file already existed.
  Surfaced by the coal-split schema change. Fixed by always persisting
  when a step actually ran.

### 2026-05-21

- **Tier 3 operational hardening** (PR #15):
  - `renv.lock` committed; workflow restores via
    `r-lib/actions/setup-renv@v2`. Pipeline runtime + tests + check now
    pin to a single resolved package set across local and CI.
  - Graduated staleness signal: `run.R` writes `outputs/staleness.json`
    with days-since-last-fresh-fetch per source. The workflow opens /
    closes a soft `weekly-stale-source` issue when any source has been
    stale for more than 7 days. Independent of the hard `--ci` all-stale
    failure path.
  - New `.github/workflows/check.yml`: `R CMD check --no-manual` on PRs
    and pushes to main. 0 errors, 0 warnings; one informational NOTE
    about `ggplot2` / `stringr` being declared Imports but consumed via
    the briefing's separate rmarkdown render env (real runtime deps,
    just not visible to the checker).

- **Tier 4 extensions** (PR #19, #20, #21):
  - **Q+1 forecast**: `run_nowcast` takes a `horizon = c(0L, 1L)` arg;
    Q+1 row produced for each commodity using the seasonal-pace future-
    months extrapolation. Surfaced as a "Next-quarter outlook" section
    in the briefing + sub-line on each landing-card.
  - **`outputs.json` endpoint** at `/data/outputs.json`. Compact
    schema-versioned JSON summary for programmatic consumers: point +
    80/95 bands per (commodity × horizon), plus production spec and
    RMSE-vs-naive per pick.
  - **World Bank Pink Sheet ingestion + `price_aug` candidate spec**.
    Pulls the monthly Pink Sheet xlsx (no API key), aggregates to
    quarterly average, plumbs `yoy_log_price` through the feature
    panel, adds `price_aug` to `cfg$bridge$candidates`. The bench
    evaluated it against the existing candidates; price didn't win
    production for any commodity (iron_ore/price_aug RMSE 4.86 vs
    bojo 4.51; coal_met/price_aug 1.79 vs midas 1.10;
    coal_thermal/price_aug 3.03 vs bojo 2.21). Kept in the bench so
    the OOS leaderboard flags if/when the relationship shifts.
  - **LNG re-scope**: not shipped — final analysis in the body of this
    doc. Blocker is concrete (we don't have AIS destination data in
    the public PortWatch slice).
