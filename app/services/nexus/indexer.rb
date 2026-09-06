require "rsolr"

module Nexus
  class Indexer
    def initialize(collection:, solr_client: RSolr.connect(url: ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")))
      @collection = collection
      @solr = solr_client
      @buffer = []
    end

    def add(doc)
      @buffer << doc
    end

    def commit
      @solr.add(@buffer) if @buffer.any?
      @solr.commit
      @buffer = []
    end
  end
end
