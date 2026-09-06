require "oai"

module Nexus
  module Harvesters
    class OaiPmh < Base
      def initialize(source)
        @client = OAI::Client.new(source.config["base_url"])
        @set = source.config["set"]
        @prefix = source.config["metadata_prefix"]
        @until = Time.now.utc
      end

      def each(from:)
        opts = list_opts(from)
        @client.list_records(opts).full.each do |rec|
          next if rec.deleted?

          yield Nexus::RawRecord.new(id: rec.header.identifier, metadata: rec.metadata, datestamp: rec.header.datestamp)
        end
      end

      def deleted_ids(from:)
        opts = list_opts(from)
        @client.list_identifiers(opts).full.select(&:deleted?).map(&:identifier)
      end

      def all_ids
        opts = { metadata_prefix: @prefix, set: @set, until: @until }
        @client.list_identifiers(opts).full.reject(&:deleted?).map(&:identifier)
      end

      attr_reader :until

      private

      def list_opts(from)
        opts = { metadata_prefix: @prefix, set: @set, until: @until }
        opts[:from] = from if from
        opts
      end
    end
  end
end
