# Zapkey clone — project memory bank

A Rails 8 + PostgreSQL app that scrapes property-registration data from the
Maharashtra IGR free-search portal (`freesearchigrservice.maharashtra.gov.in`)
and presents it as Zapkey-style transaction cards with search / filter / sort.

## Stack & layout

- **Rails 8.1**, **PostgreSQL 18**, Ruby 3.3, **Tailwind v4** (tailwindcss-rails).
- **Scraper**: Selenium headless Chrome (`app/services/igr/`).
- **Captcha OCR**: Tesseract + ImageMagick (MiniMagick).
- **LLM fallback**: Claude **Haiku** via the `anthropic` gem (building names).
- **Jobs**: Solid Queue, `:scraping` queue, **single worker** (`bin/jobs`).
- **Pagination**: Pagy pinned `~> 9.3` (v9 uses `limit:`, not `items:`).
- Single development database — Solid Queue/Cache/Cable tables live in the
  primary DB (see `config/database.yml`, `config/environments/development.rb`).

## Run it

```bash
bin/rails db:prepare                     # loads db/schema.rb
rake igr:scrape_parel                    # seed+enqueue Parel #1..10 / 2026
IGR_FROM=1 IGR_TO=10 rake igr:scrape_kharghar
bin/jobs                                 # process the :scraping queue (one Chrome)
bin/rails server                         # browse the cards at /
```

Debug a single property synchronously (watch Chrome with `IGR_HEADED=1`):
`IGR_PROPERTY_ID=123 rake igr:scrape_one`.

Post-scrape building-name enrichment:
`bin/rails runner script/backfill_building_name.rb` (regex), then
`ANTHROPIC_API_KEY=… bin/rails runner script/backfill_building_name_llm.rb`.

## Data model

- `Property` — one search target: `(year, district, tahsil, village, property_no)`
  (unique). `search_status` enum pending/found/empty/error. `mumbai?` ⇔ tahsil blank.
- `Document` — one registration row, enriched from its IndexII page. `raw` jsonb
  holds the grid row; `index_ii` jsonb holds the numbered IndexII sections "1".."14".

## Scraper architecture (`app/services/igr/`)

- `Session` (abstract) — browser lifecycle, captcha capture/solve loop, async-grid
  polling, IndexII new-window handling, stale-element retries. Subclasses
  `MumbaiSession` and `RestMaharashtraSession` own only form selectors + `fill_form`.
  `PropertyScraper#session_for` picks by `Property#mumbai?`.
- `Captcha` — hex-whitelist Tesseract OCR.
- `ResultParser` — `table#RegistrationGrid` → rows.
- `IndexIiParser` — numbered sections → attributes (`from_sections` is exact and
  tested; `parse`'s HTML→sections DOM walk is **best-effort, verify live**).
- `BuildingName` (regex) + `BuildingNameLlm` (Claude Haiku fallback).

## Hard-won live-site facts (verified June 2026)

- **Captcha is 6-char HEXADECIMAL** (0-9 A-F). Restrict Tesseract to that
  whitelist — biggest accuracy lever. Grayscale+normalize+upscale only; do NOT
  `-threshold` (hollows the glyphs). The answer is not leakable; OCR is required.
- **No feedback on a wrong captcha** — silent regenerate. "Entered Correct
  Captcha" label is a RED HERRING. Wrong captcha and "no records" both leave the
  grid empty → submit up to `EMPTY_CONFIRMATIONS` (5) times before trusting :empty.
- **CRITICAL FLOW**: fill the form ONCE, then loop solve→submit on the SAME page.
  Each submit is an ASP.NET postback that regenerates the captcha and preserves
  the form via ViewState. Re-filling/reloading between attempts corrupts the form
  so even a correct captcha returns empty.
- Results load via async UpdatePanel postback (~5-8s) → POLL (`RESULT_TIMEOUT` 12s).
- Chrome needs `--disable-dev-shm-usage` or the headless tab crashes on results.
- Intro popup (`div#popup`, close `a.btnclose`) overlays every load AND postback.
- Captcha `.screenshot_as(:png)` is BLANK in headless → draw `<img>` to a canvas
  and read `toDataURL`.
- IndexII link opens a NEW window; `__doPostBack` via execute_script throws a
  strict-mode "arguments" error → CLICK the anchor instead.
- Element IDs — **Mumbai tab**: `btnMumbaisearch` (JS-click; popup intercepts),
  `ddlFromYear`, `ddlDistrict` (value: 30=Mumbai City where Parel is, 31=Suburban),
  `txtAreaName` (village), `ddlareaname` (populates after the field BLURS),
  `txtAttributeValue`, `imgCaptcha`, `txtImg`, `btnSearch`.
  **Rest-of-Maharashtra tab**: `btnOtherdistrictSearch`, `ddlFromYear1`,
  `ddlDistrict1` (Raigad="7"), `ddltahsil` (Panvel="2 " — TRAILING SPACE),
  `ddlvillage` (value = Marathi text, Kharghar="खारघर"), `txtAttributeValue1`,
  `imgCaptcha_new`, `txtImg1`, `btnSearch_RestMaha`. Extend the English→site-value
  maps in `RestMaharashtraSession` for new villages/talukas.

## IndexII (सूची क्र.2) section map

`(1)` doc type · `(2)` consideration · `(3)` market value · `(4)` property
description (unit/floor/building/area) · `(5)` area "91.15 चौ.मीटर" · `(7)`/`(8)`
seller/purchaser blocks (PAN + pin) · `(9)` execution date · `(10)` registration
date · `(12)` stamp duty · `(13)` registration fee. Descriptions are **Marathi**.

## Building-name extraction

Description shows two shapes — comma-separated and free space-separated; in both
the name sits **after the floor marker (मजला/माळा) and before the next locality
token (प्लॉट/सेक्टर…)**. Regex hit-rate ~80% Kharghar; the LLM fallback covers the
messier Mumbai/Parel free-text. UI title = `building_name || "Property #N"`.
**Gotcha**: Ruby `\w`/`\W` are ASCII-only — use `\p{L}` to test for a Devanagari
letter, never `[\W]`.

## Hard lessons

- NEVER run a second Chrome or `rails runner` while a scrape is live (memory
  contention → InvalidSessionId crashes). Use `psql` for mid-scrape inspection.
- A running scraper uses the code it booted with and re-inserts docs per property,
  so it OVERWRITES mid-run DB fixes — stop, fix, restart.

## Recovered data (this rebuild)

The code was lost but the `zapkey_development` database survived: **332 properties,
574 documents** of real scraped data (Parel, Kharghar, Turbhe, …). The migrations
were reconstructed with the original version numbers so the data stays intact;
`db/schema.rb` was dumped from the live DB. Kharghar 11-300 was intentionally left
`pending`.
