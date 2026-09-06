#!/usr/bin/env bash
set -euo pipefail
docker rm -f nexus-solr-dev >/dev/null 2>&1 || true
docker run -d --name nexus-solr-dev -p 8983:8983 \
  -e SOLR_MODULES=analysis-extras \
  -v "$(pwd)/solr/conf:/opt/solr/server/solr/configsets/nexus_config/conf" \
  solr:9 solr-precreate nexus /opt/solr/server/solr/configsets/nexus_config
