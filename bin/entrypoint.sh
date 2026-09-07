#!/usr/bin/env bash
set -euo pipefail

export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr/nexus}"
export UPSTREAM_URL="${UPSTREAM_URL:-http://localhost:4567/oai}"
export UPSTREAM_DATA_PATH="${UPSTREAM_DATA_PATH:-/data/upstream/grainger.yml}"

# All four Active Record databases (primary, cache, queue, cable) live under
# /data/db so the whole application's state survives a Fly Machine restart
# when /data is a persistent volume. Rails only honors the bare
# DATABASE_URL for the "primary" database when multiple databases are
# configured (see config/database.yml) -- solid_cache/solid_queue/solid_cable
# each need their own <NAME>_DATABASE_URL.
export DATABASE_URL="${DATABASE_URL:-sqlite3:///data/db/nexus_demo.sqlite3}"
export CACHE_DATABASE_URL="${CACHE_DATABASE_URL:-sqlite3:///data/db/nexus_demo_cache.sqlite3}"
export QUEUE_DATABASE_URL="${QUEUE_DATABASE_URL:-sqlite3:///data/db/nexus_demo_queue.sqlite3}"
export CABLE_DATABASE_URL="${CABLE_DATABASE_URL:-sqlite3:///data/db/nexus_demo_cable.sqlite3}"

# Solr's vendored schema (solr/conf/schema.xml) uses ICUFoldingFilterFactory,
# which lives in Solr's optional analysis-extras module. Solr fails to load
# the core without this.
export SOLR_MODULES=analysis-extras

mkdir -p /data/solr /data/upstream /data/db

# The stock "solr-precreate"/"precreate-core" docker scripts hardcode their
# core storage path to /var/solr/data, ignoring SOLR_HOME overrides passed as
# arguments. To keep the Solr index under /data (for persistence across a Fly
# Machine restart via the mounted volume) we make /var/solr a symlink into
# /data/solr instead of trying to relocate solr.solr.home per invocation.
ln -sfn /data/solr /var/solr

# Populate /var/solr/{data,logs,log4j2.xml} on first boot (idempotent).
init-var-solr /var/solr

# precreate-core is idempotent: it no-ops ("Core nexus already exists") if
# the core directory is already present, so first boot and every restart
# take the same code path.
precreate-core nexus /opt/solr/server/solr/configsets/nexus_config

# Started as root inside this single-process-per-container demo image; Solr
# refuses to start as root without --force.
solr start -f -m 512m --force &
SOLR_PID=$!

until curl -sf "$SOLR_URL/admin/ping" >/dev/null 2>&1; do sleep 1; done

if [ ! -f /data/upstream/grainger.yml ]; then
  cp /app/upstream/data/grainger.yml /data/upstream/grainger.yml
fi

ruby /app/upstream/app.rb -p 4567 -o 127.0.0.1 &
UPSTREAM_PID=$!

# db:prepare (create-or-migrate) runs every boot, not just the first --
# it's idempotent, and gating it behind the seed sentinel would silently
# skip a new migration on a redeploy against an existing Fly volume. Only
# the actual seeding (which would duplicate data) is first-boot-only.
bin/rails db:prepare

if [ ! -f /data/.seeded ]; then
  bin/rails db:seed
  ruby bin/seed_static.rb
  touch /data/.seeded
fi

bin/rails server -p 3000 -b 0.0.0.0 &
PUMA_PID=$!

bin/jobs &
JOBS_PID=$!

wait -n "$SOLR_PID" "$UPSTREAM_PID" "$PUMA_PID" "$JOBS_PID"
echo "A supervised process exited; shutting down the container."
exit 1
