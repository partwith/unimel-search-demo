class HarvestCollectionJob < ApplicationJob
  queue_as :harvest

  def perform(collection_key, full: false)
    source = CollectionSource.find_by!(key: collection_key)
    run = source.harvest_runs.create!(
      started_at: Time.current, status: "running",
      cursor_from: full ? nil : (source.cursor ? source.cursor - 1.hour : nil)
    )

    harvester = Nexus::Harvesters.for(source)
    mapper = source.mapper.constantize.new
    indexer = Nexus::Indexer.new(collection: source.key)

    error_samples = []
    fetched = 0
    indexed = 0

    harvester.each(from: run.cursor_from) do |raw|
      fetched += 1
      begin
        indexer.add(mapper.call(raw))
        indexed += 1
      rescue Nexus::MappingError => e
        error_samples << { "id" => raw.id, "message" => e.message } if error_samples.size < 20
      end
    end
    indexer.commit

    deleted = Nexus::Reconciler.new(source).apply(
      harvester.deleted_ids(from: run.cursor_from),
      full_id_set: full ? nil : nil
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
