# Plan: China demand indicator via FRED

Next-up open item from [`docs/ROADMAP.md`](ROADMAP.md). Supersedes the
"Plan B" section of [`docs/PLAN_LNG_AND_DEMAND.md`](PLAN_LNG_AND_DEMAND.md),
which framed this at a higher level alongside the LNG re-scope. LNG
remains deferred; this is the plan to pick up next.

This doc is execution-ready: every phase lists the files to touch, the
tests to write, and a definition of done. Pick it up from Phase 0 once
the decisions in § Decisions to lock are made.

---

## Goal

Add a forward-looking **demand** signal to the candidate bench. Today
every spec consumes a flavour of PortWatch tonnage (or, in `price_aug`,
a commodity price). All five candidates are highly correlated by
construction. Stock-Watson combination gains are largest when the
underlying candidates draw on *different* information — so a
demand-side regressor (steel output, electricity generation, freight
rates) from an independent release calendar should diversify the bench
even if a single demand-only spec doesn't win production.

**Success target.** At least one demand-augmented candidate spec lands
production for ≥ 1 commodity on the OOS leaderboard, *or* the
combination forecasts (`equal_avg`, `inv_mse`) improve by ≥ 5% RMSE
when the demand spec is included. If neither happens, the spec stays
in the bench as a diagnostic — same pattern as `price_aug` and
`lagged` today.

**Non-goal.** Building a custom "China demand index" from raw NBS
series. Use off-the-shelf FRED aggregates.

---

## Decisions to lock before Phase 0

These are the only blockers. Each has a recommended default; explicitly
override here before kicking off Phase 0.

### 1. The three FRED series

| series id | label | maps to | recommendation |
|---|---|---|---|
| `CHNPRMNTO01IXOBSAM` | China — crude steel production (index, SA) | `iron_ore` | ✅ default |
| `CHNPIEAEN01GPSAM` | China — electricity production (index, SA) | `coal_thermal` | ✅ default |
| `BDIY` *(not in FRED)* | Baltic Dry Index | both coal commodities + iron_ore | ❌ **drop** — BDI isn't on FRED at the daily/monthly granularity we need. Use OECD's `CCUSMA02CNQ659N` (China industrial production) as a third signal mapping to `coal_met` instead, or skip the third series entirely on this pass. |

**Recommended pick:** start with two series (`steel`, `electricity`) —
adding more dimensions at N ≈ 23 training quarters risks overfitting
even with regularised combination weights. We can add a third later
without changing the schema. Drop BDI from scope.

> **Verify the series IDs are still live** before committing to them.
> FRED occasionally retires or rebases OECD-sourced series. Use
> `fredr::fredr_series("CHNPRMNTO01IXOBSAM")` to confirm.

### 2. Key handling

- Register a free key at <https://fred.stlouisfed.org/docs/api/api_key.html> (sign-up takes ~2 min, no payment).
- Add as repo secret `FRED_API_KEY` (Settings → Secrets and variables → Actions).
- Add the placeholder to [`.Renviron.example`](../.Renviron.example) so local devs know how to wire it up.
- The pipeline must degrade gracefully when the key is absent: when `Sys.getenv("FRED_API_KEY") == ""`, skip the fetch and let the bench run without the `demand_aug` spec. This keeps offline / fork builds working without leaking the key requirement.

### 3. Order of operations vs LNG

LNG is deferred indefinitely; this plan owns the next chunk of dev
time unilaterally. No coordination required.

### 4. Rollback contract

If, after Phase 3, none of the new candidates beats anything (no
production wins, no combination lift), we keep them in the bench
anyway (as we did with `price_aug`). Rationale: an OOS-leaderboard
loser is still useful diagnostic info, and FRED has zero maintenance
cost once the key is set. The only reason to actually pull the spec is
if it makes the bench numerically unstable — flagged by a `min_n`
warning in the logs or a degenerate-regressor warning from
`R/bridge.R`.

---

## Phases

### Phase 0 — register key + scaffold (~1 hour)

| step | artefact |
|---|---|
| Register FRED key | (external) |
| Add `FRED_API_KEY` to repo secrets | (GitHub UI) |
| Add `FRED_API_KEY=` placeholder to [`.Renviron.example`](../.Renviron.example) | small edit |
| Verify the two series IDs (`CHNPRMNTO01IXOBSAM`, `CHNPIEAEN01GPSAM`) return data | one-off `fredr::fredr()` call from local R |
| Document chosen series in [`docs/METHODOLOGY.md` § 2 (Data table)](METHODOLOGY.md#2-data) | append a row to the table |

**Definition of done:** A local `R -e 'fredr::fredr("CHNPRMNTO01IXOBSAM")'` (with the key in `.Renviron`) returns rows. No code committed yet.

### Phase 1 — ingest module (~3 hours)

New file [`R/ingest_fred.R`](../R/ingest_fred.R). Mirror the shape of
[`R/ingest_wb_prices.R`](../R/ingest_wb_prices.R) — the same
`with_cache()` wrapper, the same `log_ingest_run()` bookend, the same
stale-cache-fallback semantics on error.

```r
fetch_fred_demand <- function(cfg, db_ready) {
  # 1. Resolve key from env; if absent, return zero-row tibble with a
  #    log_warn -- this keeps offline / fork runs working.
  # 2. For each (series_id, commodity) mapping in cfg$fred$series,
  #    call fredr::fredr(series_id, frequency = "m") via with_cache.
  # 3. Aggregate monthly -> quarterly mean.
  # 4. Emit a long tibble: (quarter_end, commodity, series, value,
  #    log_value, ingested_at).
  # 5. wh_write("raw_fred_demand_quarterly", result, cfg).
  # 6. log_ingest_run(cfg, "fred", started, nrow(result), status).
}
```

Config additions to [`config.R`](../config.R):

```r
fred = list(
  # When the env var is unset (CI fork, offline dev), the ingest
  # short-circuits to an empty tibble and the bridge skips demand_aug.
  api_key_env = "FRED_API_KEY",
  series = list(
    iron_ore     = c(steel_idx = "CHNPRMNTO01IXOBSAM"),
    coal_thermal = c(power_idx = "CHNPIEAEN01GPSAM")
    # coal_met intentionally has no series in this pass.
  ),
  retry = list(max_attempts = 3L, backoff_seconds = 5L)
)
```

Wire into [`run.R`](../run.R) between the existing
`raw_wb_prices_quarterly` step and `derived_features`:

```r
raw_fred_demand <- run_step("raw_fred_demand_quarterly",
  function() fetch_fred_demand(cfg, cfg$paths$warehouse_dir),
  is_ingest = TRUE)
```

Pass through `build_features(..., fred_demand = raw_fred_demand)`.

**Tests** (new file `tests/testthat/test-ingest-fred.R`):

- `test-fetch-fred-demand returns the expected long-tibble schema on a stubbed `fredr::fredr` call` (mock with `local_mocked_bindings()` — see existing `test-ingest-portwatch.R` for the pattern).
- `test-fetch-fred-demand returns zero rows + a WARN log when FRED_API_KEY is unset`.
- `test-fetch-fred-demand falls back to stale cache on a network error`.

**Definition of done:** `Rscript run.R --force` writes `data/warehouse/raw_fred_demand_quarterly.rds` with one row per (commodity, quarter, series). Existing tests still pass.

### Phase 2 — feature wiring (~2 hours)

Edits to [`R/features.R`](../R/features.R):

1. Add `fred_demand = NULL` parameter to `build_features()`.
2. Pivot the long FRED tibble to wide per commodity: `value_steel_idx`, `value_power_idx`, `log_value_steel_idx`, etc.
3. Add YoY-log columns: `yoy_log_demand_steel`, `yoy_log_demand_power`. Treat NA when no series is mapped to a given commodity (e.g. coal_met has no FRED series in this pass — its `yoy_log_demand_*` cols stay NA, and the `demand_aug` spec skip-listed it as a regressor-NA row via the existing `predict_bridge` NA-guard).
4. Document new feature columns in the comment table at the top of `build_features()`.

Edits to [`R/nowcast.R::build_nowcast_pred_frame`](../R/nowcast.R):

- Add a join for the latest quarter's FRED values + lag-4 values, mirroring how `price_aug` is wired (`cur_price` / `lag4_price` pattern at lines ~226-253).

**Tests:**

- Extend `tests/testthat/test-features.R` (or add one — there isn't a dedicated features test yet; reuse `test-pipeline-stubs.R`'s fixtures) to confirm: when FRED is provided, the YoY-log demand columns appear with correct values; when FRED is empty, they're absent (or NA-only).

**Definition of done:** `derived_features.rds` has the new YoY-log demand columns. `build_nowcast_pred_frame()` produces them at predict time.

### Phase 3 — `demand_aug` candidate spec (~1 hour)

Edit [`R/bridge.R::spec_info`](../R/bridge.R):

```r
demand_aug = list(
  lhs = "log_volume",
  rhs = c("yoy_log_tonnage",
          "yoy_log_demand_steel",   # NA -> dropped per commodity
          "yoy_log_demand_power",
          "log_volume_lag4"),
  predict_extra = character(),
  to_log_volume = function(yhat, pred_row) yhat
)
```

Add `"demand_aug"` to `cfg$bridge$candidates` in [`config.R`](../config.R).

Update [`R/attribution.R::decompose_components`](../R/attribution.R) so the `yoy_log_demand_*` regressors are bucketed under `other_log` (alongside `yoy_log_price`).

**Behavior gate.** The bridge `fit_bridge_one()` already skips a spec when any required regressor has near-zero variance or excessive NAs (`R/bridge.R` § Guardrails in METHODOLOGY). So when FRED is absent the spec auto-skips per commodity; no extra branching needed.

**Tests:**

- New `tests/testthat/test-bridge.R::demand_aug fits when FRED columns are present`.
- New `tests/testthat/test-bridge.R::demand_aug skips per commodity when its required cols are all NA`.

**Definition of done:** `bridge_diagnostics.csv` shows `demand_aug` rows for `iron_ore` and `coal_thermal`. `coal_met` has no `demand_aug` row (per the deliberate config).

### Phase 4 — workflow secret + verify on cron (~1 hour)

Edit [`.github/workflows/weekly.yml`](../.github/workflows/weekly.yml). The `Run pipeline` step needs the secret in its env:

```yaml
- name: Run pipeline (--ci fails on all-stale ingest)
  run: Rscript run.R --ci
  env:
    FRED_API_KEY: ${{ secrets.FRED_API_KEY }}
```

Manual-dispatch the workflow once, confirm:

1. `data/warehouse/raw_fred_demand_quarterly.rds` is present in the `data` branch after the run.
2. `bridge_diagnostics.csv` has `demand_aug` rows.
3. The bench leaderboard surfaces `demand_aug` rmse / coverage / production-pick info correctly.

**Definition of done:** First cron run after Phase 4 ships ingests FRED successfully and the briefing shows the new spec in the diagnostics table + the band-calibration table.

### Phase 5 — surfacing + ROADMAP update (~1 hour)

- The briefing's diagnostics table grows by ≤ 2 rows per commodity (1 for iron_ore, 1 for coal_thermal). No layout changes needed — the existing kable rendering handles it.
- If `demand_aug` wins production for any commodity, the briefing's "Production equation per commodity" section will render the new equation automatically (existing infrastructure — see `build_eq_entry()` in `briefing.Rmd`). **Add a branch** in `build_eq_entry()` for the `demand_aug` spec so the rendered equation is non-empty (it currently defaults to `eq <- ""` for unrecognised specs).
- `outputs.json` `production_spec` field reflects the new winner automatically.
- [`docs/METHODOLOGY.md`](METHODOLOGY.md) § 4: add a "4.5 demand-augmented" subsection describing the spec and citing the rationale (Stock-Watson combination diversity, the FRED series chosen, why these and not others).
- Move "China demand indicator" entry under [`docs/ROADMAP.md`](ROADMAP.md) "Completed" with the run-date.

**Definition of done:** All four columns visible in the rendered briefing; production equation renders correctly if `demand_aug` wins.

---

## Total budget

| phase | active dev | notes |
|---|---|---|
| 0 — register + scaffold | ~1 h | external (key registration) |
| 1 — ingest module | ~3 h | mirror `R/ingest_wb_prices.R` |
| 2 — feature wiring | ~2 h | mirror price-feature plumbing |
| 3 — `demand_aug` spec | ~1 h | one new entry in `spec_info()` + config |
| 4 — workflow secret | ~1 h | one line in `weekly.yml` + verification |
| 5 — surfacing + docs | ~1 h | small briefing tweak + methodology section |
| **total active** | **~9 h** | ~1.5 dev days |
| **total elapsed** | **~1–2 days** | mostly waiting for key registration + one weekly cron |

---

## Risks

1. **FRED series IDs change.** OECD-sourced FRED series occasionally get rebased or retired. Verify in Phase 0; on failure, pick the nearest substitute or skip that signal. The retry / stale-cache pattern in `R/ingest_wb_prices.R` covers transient outages but not series deletion.
2. **Demand signal doesn't help at N ≈ 23.** Plausible. The fallback is "spec stays in the bench as diagnostic info", same as `price_aug` today (which didn't win for any commodity but still flags relationship shifts via the OOS leaderboard).
3. **Sample misalignment.** FRED's China series start in different years. Confirm at Phase 0 that both `CHNPRMNTO01IXOBSAM` and `CHNPIEAEN01GPSAM` go back to at least 2019 (our `train_start`). If not, the bridge will skip that commodity's `demand_aug` spec automatically (via the `min_n = 12` guardrail) — not silent, but worth knowing.
4. **Combination weights downweight the new candidate to near zero.** Acceptable. The `equal_avg` combination spec gives the demand spec equal say, and `inv_mse` weighs by inverse-MSE, so a noisy candidate is automatically deprioritised without us having to tune.

---

## What NOT to do as part of this plan

- **Don't pipe in more than two or three FRED series.** Overfit risk at our sample size.
- **Don't try to construct a custom "China demand index"** from raw inputs — use off-the-shelf NBS aggregates that FRED republishes.
- **Don't scrape NBS or Wikipedia BDI as a primary path.** Markup-fragile; revisit only if FRED proves insufficient.
- **Don't add a `demand_only` spec** (demand without tonnage). Two-thirds of the value of this work is in the *combination* with PortWatch, not as a substitute.

---

## Open questions for the dev kickoff

These are the only things this plan deliberately leaves open:

1. Whether to add the OECD `CCUSMA02CNQ659N` (China industrial production) as a third series mapping to `coal_met`. Default: skip, but reconsider after Phase 3 if combination gains look strong on the two-series version.
2. Whether to add seasonal-adjustment to the FRED series. Both default suggestions are already SA. If a future series is NSA, decide whether to YoY-difference or pre-SA — match the rest of the bench (YoY-difference, see `docs/METHODOLOGY.md § 3`).
3. Whether to commit a snapshot fixture for tests or rely on live FRED at test time. Recommendation: commit a small fixture (12-24 months × 2 series) under `tests/testthat/fixtures/fred_demand_snapshot.rds`; tests mock `fredr::fredr` to return slices of it.

Everything else is locked. Once Phase 0's decisions are confirmed, the
work can be done end-to-end without further design conversation.
