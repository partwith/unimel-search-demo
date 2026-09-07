module Nexus
  module Mappers
    class Base
      def call(raw)
        raise NotImplementedError
      end

      # Derives the Solr document id a raw upstream identifier maps to,
      # without needing that record's full metadata. Callers that only have
      # an identifier (e.g. HarvestCollectionJob preserving a record that
      # failed to map this run, or a harvester translating "deleted"
      # identifiers into Solr id space) use this instead of #call.
      def id_for(raw_id)
        raise NotImplementedError
      end
    end
  end
end
