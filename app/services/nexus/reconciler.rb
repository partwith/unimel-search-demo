module Nexus
  class Reconciler
    def initialize(source, solr_client: RSolr.connect(url: ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")))
      @source = source
      @solr = solr_client
    end

    def apply(deleted_ids, full_id_set: nil)
      ids_to_delete = deleted_ids.dup

      if full_id_set
        existing_ids = fetch_existing_ids
        ids_to_delete |= (existing_ids - full_id_set)
      end

      return 0 if ids_to_delete.empty?

      @solr.delete_by_id(ids_to_delete)
      @solr.commit
      ids_to_delete.size
    end

    private

    def fetch_existing_ids
      label = @source.config["collection_label"] || @source.key
      response = @solr.get("select", params: { q: %(collection_ssim:"#{label}"), fl: "id", rows: 10_000 })
      response["response"]["docs"].map { |doc| doc["id"] }
    end
  end
end
