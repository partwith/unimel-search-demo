class HarvestCollectionJob < ApplicationJob
  queue_as :harvest

  def perform(collection_key, full: false)
    source = CollectionSource.find_by!(key: collection_key)
    run = source.harvest_runs.create!(
      started_at: Time.current, status: "running",
      cursor_from: full ? nil : (source.cursor ? source.cursor - 1.hour : nil)
    )

    mapper = source.mapper.constantize.new
    harvester = Nexus::Harvesters.for(source, mapper)
    indexer = Nexus::Indexer.new(collection: source.key)

    error_samples = []
    fetched = 0
    indexed = 0
    # The current full set of Solr ids known to still exist upstream this
    # run -- both successfully (re-)indexed records AND records that merely
    # failed to *map* this run (see the rescue branch below). A record isn't
    # "gone" just because this run's mapping choked on it; only the harvester
    # saying it's deleted, or a full sweep finding it absent entirely, means
    # that.
    current_ids = []

    harvester.each(from: run.cursor_from) do |raw|
      fetched += 1
      begin
        doc = mapper.call(raw)
        indexer.add(doc)
        indexed += 1
        current_ids << doc[:id]
      rescue Nexus::MappingError => e
        error_samples << { "id" => raw.id, "message" => e.message } if error_samples.size < 20
        # Preserve this id in the full set even though mapping failed: it may
        # still be validly indexed from a previous successful run, and a
        # transient mapping failure must not read as "upstream deleted this"
        # to the reconciler below (which would otherwise delete a good,
        # previously-indexed document).
        current_ids << mapper.id_for(raw.id)
      end
    end
    indexer.commit

    # full_id_set and the explicit deleted ids both have to be in Solr id
    # space ("grainger:GM-0417"), not the harvester's raw upstream identifier
    # space ("oai:grainger.unimelb.edu.au:GM-0417") -- Reconciler compares
    # full_id_set against Solr ids fetched from Solr itself, and passes the
    # deleted ids straight to Solr's delete_by_id (a silent no-op against ids
    # that don't exist). Nexus::Harvesters::OaiPmh#deleted_ids already
    # translates via the mapper for this reason. A full run re-fetches every
    # non-deleted upstream record (cursor_from is nil), so current_ids is
    # exactly the current full set.
    # An empty current_ids on a full run almost certainly means the upstream
    # returned nothing usable (outage, corrupt response, misconfiguration) --
    # not that the collection is genuinely now empty. Treating that as the
    # full set here would make the reconciler below diff every existing Solr
    # id against an empty set and delete the entire collection. Only pass a
    # full_id_set when the run actually observed at least one current id.
    deleted = Nexus::Reconciler.new(source).apply(
      harvester.deleted_ids(from: run.cursor_from),
      full_id_set: (full && current_ids.any?) ? current_ids : nil
    )

    run.update!(
      fetched: fetched, indexed: indexed, deleted: deleted,
      mapping_errors: error_samples.size, error_samples: error_samples,
      status: "success", finished_at: Time.current, cursor_until: harvester.until
    )
    source.update!(cursor: harvester.until)
    log_run(run)
  rescue => e
    run&.update!(status: "failed", finished_at: Time.current, error_samples: (run.error_samples + [{ "message" => e.message }]))
    log_run(run, error: e) if run
    raise
  end

  private

  def log_run(run, error: nil)
    Rails.logger.info({
      event: "harvest_run", collection: run.collection_source.key, status: run.status,
      fetched: run.fetched, indexed: run.indexed, deleted: run.deleted,
      mapping_errors: run.mapping_errors,
      duration_ms: run.finished_at ? ((run.finished_at - run.started_at) * 1000).to_i : nil,
      error: error&.message
    }.to_json)
  end
end
