# Nexus Cross Collection Search — Fly.io Demo: Design

Source design: `../../../../Nexus_Demo_Design.md` (Nexus_Demo_Design.md at the
repo root's parent directory). This spec covers everything needed to turn
that design into a running app deployed on Fly.io, plus the specific
deviations made to fit a single-Machine deployment and a 2-3 day timeline.

---

## 1. Scope

Full pipeline, matching sections 1-9 of the source design:

- Unified Solr schema, four source formats mapped into it (section 3-4)
- Blacklight search app: facets, item pages with source-record tab,
  link-back, rights-based suppression (sections 1, 5-8)
- Mock OAI-PMH upstream for Grainger Museum + scheduled Rails harvester
  (section 9), for the sync-pipeline story

Rare Books, Herbarium, and Archives (15 records) are loaded once as static
JSON straight into Solr, matching the source design's call to keep some
collections static ("mirrors reality, where some sources have OAI and some
only give you a file"). Only Grainger (5 records) goes through the
OAI-PMH -> harvester -> mapper -> indexer path. The optional CSV-file
harvester for Herbarium is out of scope.

### Deviations from the source design

| Source design | This build | Why |
|---|---|---|
| Postgres | SQLite | One fewer service to deploy/pay for; Rails 8 default; Solid Queue runs fine against it |
| Docker Compose, 4 services (`solr`, `db`, `upstream`, `web`, `worker`) | 1 Fly Machine, 1 image, 4 supervised processes | Cheapest, fewest failure points for a demo deploy under time pressure |
| Demo script edits `upstream/data/grainger.yml` by hand (section 9.5) | Small admin UI edits the same YAML | SSH-ing into a remote Fly Machine mid-interview to vim a file is fragile; a form is not |
| GitHub Actions CI (section 9.4) | None | Explicitly deferred; can be added later |

Everything else (schema, mapping rules, sample data, Blacklight config,
SearchBuilder suppression, harvester/mapper/indexer/reconciler shapes,
HarvestRun model) is as specified in the source design and is not repeated
here in full — see the source document for the field tables, per-collection
sample data, mapping rules, `catalog_controller.rb`, `SearchBuilder`,
`HarvestCollectionJob`, `OaiPmh` harvester, and `GraingerOaiDc` mapper.

---

## 2. Repository layout

```
nexus_demo/
  app/
    controllers/
      catalog_controller.rb
      admin/
        collection_sources_controller.rb   # list sources, "Harvest now" button
        harvest_runs_controller.rb         # list runs + error samples
        upstream_records_controller.rb     # edit the mock upstream's YAML records
    models/
      search_builder.rb
      collection_source.rb
      harvest_run.rb
    jobs/
      harvest_collection_job.rb
    services/nexus/
      harvesters/{base,oai_pmh}.rb
      mappers/{base,grainger_oai_dc}.rb      # only Grainger goes through a mapper; see note below
      indexer.rb
      reconciler.rb
      date_parser.rb
      dublin_core.rb                       # small Nokogiri wrapper -> hash of arrays
  upstream/
    app.rb                                  # Sinatra OAI-PMH mock
    data/grainger.yml                       # backing store; admin UI writes here
  db/
    seeds/nexus_demo_data.json               # the 15 static-collection records (Rare Books,
                                              # Herbarium, Archives), already in unified-schema
                                              # shape. Grainger's 5 live only in
                                              # upstream/data/grainger.yml and reach Solr
                                              # exclusively via the harvest pipeline.
  solr/conf/                                 # Blacklight's default configset, vendored at build time
  bin/
    entrypoint.sh                            # supervises solr, upstream, puma, solid queue
    seed_static.rb                           # POSTs the 3 static collections to Solr once
  config/recurring.yml
  Dockerfile
  fly.toml
```

---

## 3. Container & process architecture

One Dockerfile, one image, four processes started by `bin/entrypoint.sh`:

1. `solr start -f` against a core created from the vendored configset,
   data directory under `/data/solr` (Fly volume).
2. `ruby upstream/app.rb -p 4567 -o 127.0.0.1` — Sinatra OAI-PMH mock,
   loopback-only.
3. `bin/rails server -p 3000 -b 0.0.0.0` — Puma, the only process bound
   to a non-loopback address.
4. `bin/jobs` — Solid Queue supervisor, running the recurring harvest
   schedule from `config/recurring.yml` against the same SQLite DB.

`bin/entrypoint.sh` starts all four as background jobs and does
`wait -n`: if any one exits, the script exits non-zero and Fly restarts
the Machine. On first boot (empty volume), the entrypoint also runs Solr
core creation, `bin/rails db:prepare`, and `bin/seed_static.rb` before
starting Puma, gated on a marker file (`/data/.seeded`) so restarts don't
reseed or duplicate documents (Solr upserts by `id` are idempotent anyway,
but the static seed step is skipped once the marker exists to keep boot
fast).

Only Puma's port is exposed via `fly.toml`'s `[http_service]`. Solr
(8983) and the upstream mock (4567) are loopback-only inside the Machine.

---

## 4. Data & storage layout

Single Fly volume mounted at `/data`:

```
/data/db/nexus_demo.sqlite3     # Rails app DB: bookmarks/searches tables,
                                 # collection_sources, harvest_runs, Solid Queue tables
/data/solr/                     # Solr core data directory
/data/upstream/grainger.yml     # mock upstream backing store (admin UI writes here)
/data/.seeded                   # marker file, see above
```

All three services read/write only within `/data`, so `fly volumes
extend` / snapshot / restore behave predictably, and a fresh volume
naturally reproduces "empty Blacklight" (demo script step 1).

---

## 5. Admin UI (new, not in the source design)

Unauthenticated (matches the rest of the app — no auth anywhere), mounted
at `/admin`, three pages:

- **Sources** (`/admin`) — one row per `CollectionSource`, showing its
  cursor and a **"Harvest now"** button that calls
  `HarvestCollectionJob.perform_later(key)` (incremental) and a smaller
  **"Full re-index"** link for `full: true`. This replaces the doc's
  `bin/rails runner` step with a button click.
- **Harvest runs** (`/admin/harvest_runs`) — table of `HarvestRun` rows:
  status, fetched/indexed/deleted/mapping_errors, duration, and expandable
  error samples. This is the page the source design calls "the UI you'd
  show a collection owner."
- **Upstream records** (`/admin/upstream_records`) — lists the 5 Grainger
  YAML records with inline edit (title field) and a "mark deleted"
  toggle; saving rewrites `grainger.yml` and bumps that record's
  `updated_at` to now. This replaces the doc's "edit the YAML file, wait
  for the schedule" demo step with something clickable.

No new gems beyond what's already in the design (plain ERB views, a Rails
form for the YAML edit, `YAML.load_file`/`File.write` under a mutex to
avoid clobbering concurrent writes — acceptable for single-user demo use).

---

## 6. Error handling

- **Mapping errors** don't abort a run — counted, first 20 sampled with
  record id + message (as section 9.2 specifies), visible on the Harvest
  Runs admin page.
- **Job failures** mark the run `failed`, log a structured JSON line, and
  re-raise so Solid Queue retries with backoff.
- **Process supervision**: `wait -n` in the entrypoint script — any one
  of the four processes dying restarts the whole Machine. No finer-grained
  self-healing; called out explicitly as a demo-scale simplification.
- **Suppression** (`SearchBuilder#hide_restricted`) fails closed: the
  restricted filter applies unless `staff_view=1` is present exactly.
- **Upstream YAML writes**: a `File.flock` around read-modify-write in
  the admin controller prevents corruption if a harvest run and an admin
  edit race.

---

## 7. Testing

Given the timeline, coverage is limited to the specs the source design
calls out as talking points, run locally (`bundle exec rspec`) before
each deploy — no CI wiring:

- `DateParser`: `"1950-1952"`, `"c. 1930s"`, `"1867"`, `"n.d."`
- A mapper handles a record with no creator
- `OaiPmh` harvester follows a `resumptionToken` across pages
- A mapping error is counted, not fatal, and doesn't stop later records
- A deleted OAI header removes the corresponding Solr doc
- `HarvestRun` counts (fetched/indexed/deleted/mapping_errors) match a
  scripted fixture harvest
- `SearchBuilder#hide_restricted` suppresses by default, admits with
  `staff_view=1`

---

## 8. Fly.io deployment

- `fly launch` (no auto-deploy) to scaffold the app; hand-edit the
  resulting `fly.toml`.
- `fly.toml`: one `[[mounts]]` for the `/data` volume, `[http_service]`
  exposing only Puma's port with a health check against `/catalog`,
  `shared-cpu-1x` / 1GB Machine to start.
- Solr JVM heap capped (`-Xmx512m` via `SOLR_HEAP` or `-m` flag) given
  the ~20-document dataset — revisit if Solr OOMs under Blacklight's
  default configset.
- Secrets: `fly secrets set RAILS_MASTER_KEY=...`. No other credentials
  needed (no auth, no external DB, no OAI auth).
- `fly volumes create nexus_data --size 1` (single region) before first
  deploy.
- Deploy: `fly deploy` from the local Dockerfile. No registry step, no
  CI.
- Known limitation, accepted for the demo: Solr's admin UI (8983) and the
  upstream mock (4567) are not reachable from outside the Machine. Direct
  Solr poking would need `fly ssh console` + a tunnel.

---

## 9. Demo script (adapted from source design section 9.5 + section 6)

1. `fly deploy` on an empty volume — Blacklight loads with the 15 static
   records only (Grainger not yet harvested).
2. Visit `/admin`, click **Full re-index** for Grainger — 5 records
   appear; the Harvest Runs page shows fetched 5 / indexed 5 / deleted 0.
3. Visit `/admin/upstream_records`, edit GM-1102's title, save. Click
   **Harvest now** (or wait for the 15-min schedule) — only 1 record
   fetched, title updated in Blacklight.
4. Mark GM-1540 deleted, save, **Harvest now** — record disappears from
   search; run shows deleted 1.
5. Run the section 1-12 search scenarios from the source design (cross-
   collection `grainger` query, facet narrowing, date range, suppression
   toggle, source-record tab, relevance ordering) directly against the
   deployed app.
6. Point at the structured JSON log line Fly captures for each harvest
   run as "the event Splunk would index."

---

## 10. Non-goals

No auth, no IIIF, no CSV-file harvester, no CI/CD, no multi-region /
multi-Machine HA, no Postgres. All explicitly deferred per the scoping
conversation, not oversights.
