# Plans: LNG re-scope and China demand indicator

Two plans for the open items from `docs/ROADMAP.md`. Each starts with the
single hardest decision — both have data-source paths with different
cost and time trade-offs.

Neither has been started. This doc is the design + decision checklist;
when one of these is greenlit, work begins from Phase 0 below.

---

## Plan A — LNG re-scope

### Goal

Publish a weekly LNG export nowcast for Australia, in the same
headline-card format as iron_ore / coal_met / coal_thermal, that beats
a seasonal-random-walk benchmark on the 2024+ validation sample.
RMSE/naive target: ≤ 0.85 (same productivity threshold the brief used
for the other commodities; LNG is harder).

### Why the previous attempt failed

PortWatch's tanker-tonnage-at-LNG-ports has near-zero correlation with
ABS LNG volumes at quarterly grain. Australian LNG is contract-
dominated — ships arrive on schedule regardless of spot conditions, so
tonnage *follows* contracts rather than *forecasting* them. We need a
variable that reflects contract structure.

The hypothesis worth testing: **AIS destination-share** (the fraction
of LNG-port tanker tonnage routed to Japan / Korea / China / Taiwan /
India each quarter) is a proxy for the contract mix in force. When
Japan's share rises vs China's, that's contract-flow information, not
just tonnage.

### The blocking decision: where do AIS destinations come from?

Four options, in increasing order of cost and capability:

| Option | Access | Cost | Coverage | Recommendation |
|---|---|---|---|---|
| **UN Global Platform (UNGP)** | Apply, free for SDG / research use | $0, but needs approval (typically 2–6 weeks) and a project description | Global AIS via Spire feed; what AMRO + IMF papers used | **Try first** |
| **AIS Hub** (`aishub.net`) | Sign-up, free | $0, requires contributing your own receiver or accepting partial coverage | Patchy — heavy ship traffic OK, the Pilbara coast is questionable | Fallback only |
| **Existing IMF PortWatch (different layer)** | Already wired up | $0 | Unknown — investigate whether any layer surfaces destinations beyond `Daily_Ports_Data` | **Investigate first, cheapest if it works** |
| **Commercial AIS** (Spire / Kpler / MarineTraffic Pro) | Account + key | ~AU$500–5000/month depending on coverage tier | Best | Only if (1)–(3) fail and the project is worth it |

**Concrete next step before committing time:** spend ~30 minutes
hitting the IMF PortWatch ArcGIS root and inspecting every layer that's
exposed. There are likely additional layers besides `Daily_Ports_Data`
that we've never looked at — voyage-level, port-pair flows, etc. URL:
`https://services9.arcgis.com/weJ1QsnbMYJlCHdG/ArcGIS/rest/services/`.
If a voyage / port-pair layer exists publicly, the rest of the plan
compresses dramatically.

### Implementation phases (assuming UNGP route)

#### Phase 0 — data-source discovery (1 day)

Probe IMF PortWatch layers. If voyage data is there, jump straight to
Phase 2. If not, submit UNGP application and proceed to Phase 1 while
waiting.

#### Phase 1 — UNGP onboarding + ingest scaffolding (1 week elapsed, ~1 day active)

- Submit UNGP access request (template: brief project description, that
  this is a public reproducible nowcast)
- While waiting, write a `R/ingest_lng_destinations.R` stub that
  returns a `tibble(commodity, quarter_end, destination, share)` from a
  local fixture — lets us prototype downstream changes without the feed
- Add `cfg$lng = list(...)` with the Australian LNG port whitelist
  (re-introduce from before the 2026-04-21 removal): Gorgon,
  Wheatstone, Pluto, NWS Karratha, Prelude, Ichthys, Darwin, APLNG,
  GLNG, QCLNG
- Add `lng` to `cfg$commodities` (gated behind a `cfg$lng$enabled`
  flag so it doesn't break the live pipeline until ready)

#### Phase 2 — feature engineering (1 day)

- For each (LNG port, quarter), compute destination-share for the top
  5 importers (JP, CN, KR, TW, IN). 6th column "OTHER" captures
  everything else.
- New feature columns on the panel: `dest_share_jp`, `dest_share_cn`,
  `dest_share_kr`, `dest_share_tw`, `dest_share_in`. Plus
  `yoy_d_share_<country>` for YoY change.
- DISR REQ Table 16 has an LNG row (need to verify the row index —
  likely row 55 or thereabouts; check the workbook). Add to
  `cfg$disr$rows`.

#### Phase 3 — modelling (2 days)

- New candidate specs in the bench, all driven by destination-share:
  - `lng_dest_shares` — five YoY-share regressors + `log_volume_lag4`
  - `lng_china_share` — single-regressor variant (just
    `yoy_d_share_cn`)
  - `lng_aggregate` — fallback that uses summed tanker tonnage (the
    version we already know doesn't work; kept as a control)
- Backtest 2024+ as usual. Production selection picks whichever wins,
  same machinery.

#### Phase 4 — surfacing + ship (1 day)

- LNG gets its own headline card on the landing page + briefing
  section
- `outputs.json` schema extends to four commodities

**Total elapsed effort assuming UNGP approval:** ~2 weeks. **Total
active dev time:** ~5 days.

### Definition of done

- LNG nowcast published weekly alongside the other three commodities
- OOS RMSE/naive ratio reported in `bridge_diagnostics.csv`
- If the ratio is **> 1.0** after Phase 3 backtest, the plan is to
  **publish it but mark it as "experimental, do not rely on for
  decisions" in the briefing** and document why in `docs/METHODOLOGY.md`.
  Don't pretend it works if it doesn't.

### Risks specific to this plan

1. **UNGP application gets rejected** — recourse is option 4
   (commercial feed). Time/cost commitment.
2. **Destination-share doesn't improve RMSE either** — possible. LNG
   might genuinely not be nowcastable from physical indicators. Phase 3
   backtest gives a clean answer.
3. **IMF PortWatch layer discovery turns up an old destination dataset
   that's no longer maintained** — verify recency before relying on it.

---

## Plan B — China demand indicator

### Goal

Add a forward-looking *demand* signal (steel production, power
generation, or freight-pricing) to the candidate bench. Stock-Watson
combination gains are largest when candidates use *different
information*; currently our bench is all PortWatch tonnage variants +
a price variant that didn't beat tonnage. A demand-side indicator from
a different release calendar would diversify properly.

**Success target:** at least one demand-augmented candidate spec beats
the current production pick on at least one commodity's OOS RMSE.

### The blocking decision: which signal, and which source?

Three candidate signals × three plausible sources = nine paths.
Filtered to the realistic ones:

| Signal | Best free source | Update lag | Likely use |
|---|---|---|---|
| **China crude steel production** (monthly Mt) | FRED `CHNPROINDMISMEI` (close proxy via OECD index) or NBS direct | ~3 weeks | Iron-ore demand |
| **China thermal-power generation** (monthly TWh) | FRED `CHNPRDCTRELQNAQ` (a related series) or NBS direct | ~3 weeks | Thermal coal demand |
| **Baltic Dry Index** (daily index, dry-bulk shipping freight) | Investing.com / TradingEconomics (paywalled) or scrape Wikipedia historical | ~real time | Both coal + iron-ore |

**The single decision:** **re-enable a FRED API key, or scrape NBS /
Wikipedia?**

Recommendation: **re-enable FRED**. Reasons:

1. The project was originally wired for it (`.Renviron.example` still
   has the env-var placeholder)
2. Free tier (no payment, just sign-up) handles our load (1 call per
   week, 3 series)
3. The R package `fredr` already supports renv-friendly install
4. Scraping NBS or Wikipedia is fragile — URL/markup changes break the
   pipeline silently

Cost: registering a FRED key takes 2 minutes; setting a GitHub Action
secret takes 2 minutes. That's the entire setup.

### Implementation phases

#### Phase 0 — choose signals + register key (1 hour)

- Sign up at https://fred.stlouisfed.org/docs/api/api_key.html
- Add `FRED_API_KEY` as a GitHub Actions repo secret
- Pick the three FRED series most useful: one each for iron-ore
  demand, coal demand, freight rates. Document the chosen series IDs
  in `docs/METHODOLOGY.md`.

#### Phase 1 — ingest module (~3 hours)

- New `R/ingest_fred.R` using `fredr::fredr()`. Same shape as
  `R/ingest_wb_prices.R`:
  - Returns a long tibble `(series_id, month_end, value)`
  - Aggregates monthly → quarterly average / mean
  - With-cache wrapper for offline runs
  - Tests against a fixture for parsing
- Wire into `run.R` pipeline between `raw_disr_req_quarterly` and
  `derived_features`

#### Phase 2 — feature engineering (~2 hours)

- Map each FRED series to the commodity it informs:
  - China steel production → iron_ore
  - China electricity generation → coal_thermal (and maybe coal_met,
    depending)
  - Baltic Dry Index → both coal sub-commodities
- New feature columns: `yoy_log_demand` per commodity (NA when no
  demand series mapped)
- `build_features` takes a `fred_data` arg, same pattern as `wb_prices`

#### Phase 3 — bench integration (~1 hour)

- New candidate spec `demand_aug`: aggregate + `yoy_log_demand`
  regressor
- Slots into `cfg$bridge$candidates` automatically; backtest runs it;
  OOS leaderboard reports verdict

#### Phase 4 — workflow secret + verify (~1 hour)

- Weekly workflow passes `FRED_API_KEY` from secrets into the
  run-pipeline step
- First dispatch run will fetch fresh data + populate the bench
- `bridge_diagnostics.csv` will show the new spec's verdict

#### Phase 5 — surfacing + ROADMAP update (~1 hour)

- Briefing's diagnostics table grows from 7 specs/commodity → 8
- If the new spec wins production for any commodity, the live equation
  in the methodology section updates automatically (existing
  infrastructure)
- `outputs.json` `production_spec` field reflects the new winner

**Total active dev time:** ~half a day after the key is registered.

### Definition of done

- Three FRED series ingested weekly
- `demand_aug` spec evaluated in the candidate bench for every
  commodity
- OOS RMSE/naive reported in `bridge_diagnostics.csv`
- If the spec wins production for any commodity, the briefing's
  per-commodity equation renders with the new coefficients
  automatically (no extra UI work)
- If it doesn't win, it stays in the bench as a diagnostic — same
  pattern as `price_aug` and `lagged`

### What NOT to do as part of this plan

- **Don't pipe in dozens of FRED series.** The framework punishes
  over-parameterisation at N=23; one or two carefully-chosen series
  per commodity is the right size.
- **Don't try to construct a custom "China demand index"** from
  multiple raw series. Use the off-the-shelf NBS aggregates — they
  already do the index construction work, and a custom one would be
  unauditable.
- **Don't try Wikipedia BDI scraping** as a primary path. Use it only
  as a fallback if FRED doesn't carry the series cleanly.

---

## Plan comparison

| | Plan A — LNG | Plan B — China demand |
|---|---|---|
| Active dev time | ~5 days | ~4 hours |
| Elapsed (incl. waiting) | ~2 weeks | ~1 day |
| Cost outlay | $0 if UNGP approved; up to AU$5k/mo if commercial | $0 |
| Capability added | 4th commodity in the panel | Diversification of the existing 3 bridges |
| Likely to ship a working result | Medium (destination-share is plausible but unproven for LNG) | High (Stock-Watson gains documented in the literature when candidates use different information) |
| Likely to add maintenance burden | Yes (third-party AIS dependency) | No (FRED is stable since 1960s) |

If only one runs first: **Plan B**. It's ~10× cheaper in elapsed time,
~5× cheaper in active dev time, lower risk of a "shipped but doesn't
work" outcome, and adds no third-party dependency.

If both run: in parallel is fine — they touch different ingest paths
and different commodity scopes; merge conflicts will be minimal.

---

## Decisions to lock before either plan starts

1. **Plan B FRED series** — confirm the three suggested defaults
   (China steel production, China power generation, Baltic Dry Index)
   or pick different ones.
2. **Plan B key handling** — you register the FRED API key and add it
   to repo secrets, or the dev walks you through it.
3. **Plan A data source** — investigate IMF PortWatch other layers
   first (cheapest), or skip straight to UNGP application, or go
   commercial.
4. **Order of operations** — Plan B then A, or both in parallel, or
   only one.

Once locked, the dev work picks up from each plan's Phase 0.
