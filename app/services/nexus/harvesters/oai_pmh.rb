require "oai"

module Nexus
  module Harvesters
    class OaiPmh < Base
      def initialize(source, mapper)
        @client = OAI::Client.new(source.config["base_url"])
        @set = source.config["set"]
        @prefix = source.config["metadata_prefix"]
        @until = Time.now.utc
        @mapper = mapper
      end

      def each(from:)
        opts = list_opts(from)
        @client.list_records(opts).full.each do |rec|
          next if rec.deleted?

          yield Nexus::RawRecord.new(id: rec.header.identifier, metadata: unwrap_metadata(rec.metadata), datestamp: rec.header.datestamp)
        end
      end

      # Returns Solr document ids (the mapper's id space, e.g.
      # "grainger:GM-9999"), not raw OAI identifier URIs -- Reconciler passes
      # these straight to Solr's delete_by_id, which is a silent no-op
      # against ids that don't exist, so returning raw OAI identifiers here
      # would make incremental deletes never actually take effect.
      def deleted_ids(from:)
        opts = list_opts(from)
        @client.list_identifiers(opts).full.select(&:deleted?).map { |i| @mapper.id_for(i.identifier) }
      end

      attr_reader :until

      private

      def list_opts(from)
        opts = { metadata_prefix: @prefix, set: @set, until: @until }
        opts[:from] = from if from
        opts
      end

      # The oai gem's OAI::Client::Record#metadata is the <metadata> element
      # itself (per the OAI-PMH spec, a wrapper around exactly one child
      # element in whatever schema the record uses, e.g. <oai_dc:dc>) rather
      # than that inner element -- unwrap it so mappers (Nexus::DublinCore
      # in particular) see the actual Dublin Core container as their root,
      # not the <metadata> wrapper around it.
      def unwrap_metadata(metadata)
        return metadata unless metadata.respond_to?(:elements)

        metadata.elements.first || metadata
      end
    end
  end
end
