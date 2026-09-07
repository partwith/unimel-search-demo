FROM solr:9 AS solr-base

FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libyaml-dev sqlite3 libsqlite3-dev curl default-jre-headless procps \
    && rm -rf /var/lib/apt/lists/*

# Bring over the Solr installation. The docker-solr helper scripts
# (solr-precreate, precreate-core, init-var-solr) live under
# /opt/solr/docker/scripts, and /etc/default/solr.in.sh (sourced by bin/solr)
# lives outside /opt/solr entirely, so both need an explicit COPY.
COPY --from=solr-base /opt/solr /opt/solr
COPY --from=solr-base /etc/default/solr.in.sh /etc/default/solr.in.sh

# The official solr:9 image bundles its own JRE under /opt/java, which is
# NOT part of /opt/solr and so isn't carried over by the COPY above --
# install a JRE ourselves (default-jre-headless, above) and point Solr at it.
ENV JAVA_HOME=/usr/lib/jvm/default-java
ENV PATH="/opt/solr/bin:/opt/solr/docker/scripts:${JAVA_HOME}/bin:${PATH}"

# Replicate the environment the official solr:9 image sets up (normally done
# by its own Dockerfile ENV instructions, which we don't inherit since we
# only copied /opt/solr and one file out of it).
ENV SOLR_HOME=/var/solr/data
ENV SOLR_PID_DIR=/var/solr
ENV SOLR_LOGS_DIR=/var/solr/logs
ENV LOG4J_PROPS=/var/solr/log4j2.xml
ENV SOLR_INCLUDE=/etc/default/solr.in.sh
ENV SOLR_JETTY_HOST=0.0.0.0
# Solr 9's experimental JVM Security Manager sandbox denies file access
# through the /var/solr -> /data/solr symlink entrypoint.sh sets up (its
# policy grants access by the literal /var/solr path, but permission checks
# resolve the symlink to /data/solr first). Disable it for this demo.
ENV SOLR_SECURITY_MANAGER_ENABLED=false

ENV RAILS_ENV=production

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .
RUN mkdir -p /opt/solr/server/solr/configsets/nexus_config/conf \
    && cp -r solr/conf/* /opt/solr/server/solr/configsets/nexus_config/conf/

# SECRET_KEY_BASE_DUMMY scopes a throwaway secret to this one build step only
# (Rails' own supported mechanism for precompiling assets without real
# credentials) so nothing sensitive ends up baked into the image; the real
# secret is supplied via RAILS_MASTER_KEY at `docker run` time.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

EXPOSE 3000
VOLUME /data

ENTRYPOINT ["bin/entrypoint.sh"]
