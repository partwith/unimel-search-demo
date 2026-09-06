module Nexus
  module Mappers
    class GraingerOaiDc < Base
      def call(raw)
        dc = Nexus::DublinCore.parse(raw.metadata)
        local_id = raw.id.split(":").last
        raise Nexus::MappingError, "#{local_id}: missing dc:title" if dc["title"].empty?

        start, finish = Nexus::DateParser.call(dc["date"].first)

        {
          id: "grainger:#{local_id}",
          collection_ssim: ["Grainger Museum"],
          format_ssim: dc["type"],
          title_tesim: dc["title"],
          creator_tesim: dc["creator"],
          creator_ssim: dc["creator"].map { |c| c.sub(/\s*\(.*\)\z/, "") },
          date_ssim: dc["date"],
          date_start_isi: start,
          date_end_isi: finish,
          subject_ssim: dc["subject"],
          place_ssim: dc["coverage"],
          description_tesim: dc["description"],
          rights_ssim: dc["rights"],
          source_url_ss: dc["identifier"].find { |i| i.start_with?("http") },
          source_system_ss: "Grainger Museum (OAI-PMH)",
          source_record_ss: raw.metadata.to_s
        }.compact.transform_values { |v| v.is_a?(Array) && v.empty? ? nil : v }.compact
      rescue Nexus::MappingError
        raise
      rescue => e
        raise Nexus::MappingError, "#{raw.id}: #{e.message}"
      end
    end
  end
end
