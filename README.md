# Zapkey clone

A Rails 8 app that scrapes property-registration data from the Maharashtra IGR
free-search portal (`freesearchigrservice.maharashtra.gov.in`) and presents it as
Zapkey-style transaction cards with search, filter, and sort.

> Scrapes a public government search portal for research/personal use. Be polite:
> run a single worker, don't hammer the site.

## Requirements

- Ruby 3.3, Rails 8.1, PostgreSQL 18+
- Google Chrome (chromedriver is auto-managed by Selenium Manager)
- Tesseract OCR + ImageMagick — `brew install tesseract imagemagick`
- `ANTHROPIC_API_KEY` (optional — only for the LLM building-name backfill)

## Setup

```bash
bundle install
bin/rails db:prepare          # creates the DB and loads db/schema.rb
bin/rails server              # http://localhost:3000
```

## Scraping

Seeding find-or-creates `Property` rows and enqueues them on the `:scraping`
queue; `bin/jobs` runs a **single** worker (one headless Chrome at a time).

```bash
rake igr:scrape_parel                       # Parel (Mumbai City) #1..10 / 2026
IGR_FROM=11 IGR_TO=50 rake igr:scrape_parel
rake igr:scrape_kharghar                    # Kharghar (Raigad / Panvel)
rake igr:scrape_pending                     # (re)enqueue all pending/error rows
bin/jobs                                    # process the queue

# Debug one property synchronously (IGR_HEADED=1 shows the browser):
IGR_PROPERTY_ID=123 rake igr:scrape_one
```

Post-scrape building-name enrichment:

```bash
bin/rails runner script/backfill_building_name.rb                       # regex
ANTHROPIC_API_KEY=… bin/rails runner script/backfill_building_name_llm.rb  # Claude Haiku
```

## Architecture

See [`CLAUDE.md`](CLAUDE.md) for the full design notes, the verified live-site
quirks, the IndexII section map, and the hard-won lessons.

- `app/services/igr/` — the scraper (Session base + Mumbai/Rest-Maharashtra
  subclasses, captcha OCR, result/IndexII parsers, building-name extraction).
- `app/models/` — `Property` (search targets) and `Document` (registrations).
- `app/controllers/documents_controller.rb` + `app/views/documents/` — the UI.

## Tests

```bash
bin/rails test
```
