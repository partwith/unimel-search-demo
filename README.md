# Nexus Cross Collection Search

A Rails + Blacklight demo that unifies several museum/library-style
collections (e.g. Grainger) behind a single search index, with a harvest
pipeline that ingests records from an upstream OAI-PMH source into a shared
Solr schema. Built as a take-home/interview demo to show end-to-end design:
schema unification, harvesting/reconciliation, restricted-record handling,
an admin UI for triggering harvests and editing upstream state, and a
single-container deploy to Fly.io.

**Live demo:** https://cross-collection-search.fly.dev

## Running locally

```bash
bundle install
bin/solr_dev.sh          # starts a local Solr instance with the app's schema
bundle exec rspec        # run the test suite
bin/rails server         # starts the app at http://localhost:3000
```

The mock upstream OAI-PMH server (`upstream/app.rb`) and Solid Queue worker
are started separately in production (see `Dockerfile`/entrypoint); for
local development, harvests can be triggered from the admin UI
(`/admin/collection_sources`) once Solr and the app are running.

## Architecture (brief)

- A single unified Solr schema holds documents from every collection,
  normalized to a shared field set (e.g. `title_tesim`, `creator_tesim`)
  plus collection-specific fields (e.g. `scientific_name_ssim`).
- Four collections are modeled, each with its own mapper translating
  source metadata into the shared schema.
- A harvest pipeline (`HarvestCollectionJob` + `Nexus::Harvesters::OaiPmh`
  + `Nexus::Reconciler`) incrementally fetches new/changed/deleted records
  from each source and reconciles Solr against the upstream's current
  id set on full runs.
- The whole app (Rails, Solr, the mock upstream, and Solid Queue) runs as
  one supervised process group in a single container, deployed as one
  Fly Machine.

## Known limitations / deliberate non-goals

This is a demo, not a production system. Notably:

- **No authentication anywhere**, including `/admin` — anyone with the URL
  can trigger harvests or edit upstream records.
- **Restricted-record suppression is enforced only at the search layer**
  (the search builder filters restricted records out of query results). A
  direct item-page fetch by id is not re-checked against the same
  predicate, nor would any future API/OAI output be — a production system
  would enforce the same restriction check on document fetch and any other
  read path, not just search.
- **Single Fly Machine with SQLite** — no high availability, no failover,
  no read replicas.
- **Solr is not exposed outside the container** — it's reachable only by
  the Rails app on localhost, with no independent access control of its
  own to demonstrate.
- **The OAI-PMH upstream is a mock** (`upstream/app.rb`) built for this
  demo to exercise pagination, resumption tokens, and deletes — it is not
  a real integration with any live collection-management system.
