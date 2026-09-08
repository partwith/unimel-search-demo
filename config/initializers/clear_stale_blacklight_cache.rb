# Blacklight's #application_name helper caches its result under the fixed
# key "blacklight/application_name" via Rails.cache with no expiry (see
# Blacklight::BlacklightHelperBehavior#application_name). In this app,
# Rails.cache is solid_cache_store, backed by a SQLite db on the persistent
# /data volume -- so a value cached before a config/locales/blacklight.en.yml
# change (or before any deploy at all) survives redeploys and machine
# restarts indefinitely, silently pinning the displayed application name to
# whatever it was the first time this helper ever ran on this volume.
#
# Clear it on every boot so the configured application_name always takes
# effect after a deploy, rather than requiring a manual cache flush.
Rails.application.config.after_initialize do
  Rails.cache.delete("blacklight/application_name")
rescue StandardError => e
  Rails.logger.warn("Could not clear cached blacklight/application_name: #{e.message}")
end
