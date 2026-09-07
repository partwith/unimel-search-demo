require "sinatra/base"
require "builder"
require "time"
require_relative "../lib/nexus_upstream_store"

module NexusUpstream
  class App < Sinatra::Base
    PAGE_SIZE = 3

    # This is a local mock upstream, not a security-sensitive service; Sinatra
    # 4.x's default Host header allow-list rejects the host Rack::Test uses
    # ("example.org") as well as any non-localhost host a real deploy might
    # front it with (e.g. Fly.io's internal hostnames), so disable it here.
    set :host_authorization, permitted_hosts: []

    def self.store
      @store ||= NexusUpstreamStore.new(ENV.fetch("UPSTREAM_DATA_PATH", File.expand_path("data/grainger.yml", __dir__)))
    end

    get "/oai" do
      content_type "text/xml"
      case params["verb"]
      when "Identify" then identify
      when "ListMetadataFormats" then list_metadata_formats
      when "ListSets" then list_sets
      when "ListIdentifiers" then list_identifiers
      when "ListRecords" then list_records
      when "GetRecord" then get_record
      else halt 400, "unsupported verb"
      end
    end

    private

    def store = self.class.store

    def envelope(verb)
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct!
      xml.tag!("OAI-PMH", xmlns: "http://www.openarchives.org/OAI/2.0/") do
        xml.responseDate Time.now.utc.iso8601
        xml.request(verb: verb) { xml.text! request.url }
        yield xml
      end
      xml.target!
    end

    def identify
      envelope("Identify") { |xml| xml.Identify { xml.repositoryName "Nexus Grainger Mock Upstream" } }
    end

    def list_metadata_formats
      envelope("ListMetadataFormats") do |xml|
        xml.ListMetadataFormats { xml.metadataFormat { xml.metadataPrefix "oai_dc" } }
      end
    end

    def list_sets
      envelope("ListSets") { |xml| xml.ListSets { xml.set { xml.setSpec "grainger" } } }
    end

    def filtered_records
      from = parse_time(params["from"])
      until_ts = parse_time(params["until"])
      store.records.select do |r|
        ts = parse_time(r["updated_at"])
        (from.nil? || ts >= from) && (until_ts.nil? || ts <= until_ts)
      end.sort_by { |r| r["id"] }
    end

    def paginate(records)
      offset = (params["resumptionToken"] || 0).to_i
      page = records[offset, PAGE_SIZE] || []
      next_offset = offset + PAGE_SIZE
      token = next_offset < records.size ? next_offset.to_s : ""
      [ page, token, records.size, offset ]
    end

    def list_identifiers
      records, token, total, cursor = paginate(filtered_records)
      envelope("ListIdentifiers") do |xml|
        xml.ListIdentifiers do
          records.each { |r| identifier_header(xml, r) }
          xml.resumptionToken(token, completeListSize: total, cursor: cursor)
        end
      end
    end

    # Mirrors record_body's deleted-vs-live branching: ListIdentifiers must
    # mark deleted records with status="deleted" the same way ListRecords
    # does, or Nexus::Harvesters::OaiPmh#deleted_ids (which reads this verb)
    # never sees any record as deleted.
    def identifier_header(xml, record)
      if record["deleted"]
        xml.header(status: "deleted") { header_fields(xml, record) }
      else
        xml.header { header_fields(xml, record) }
      end
    end

    def list_records
      records, token, total, cursor = paginate(filtered_records)
      envelope("ListRecords") do |xml|
        xml.ListRecords do
          records.each { |r| xml.record { record_body(xml, r) } }
          xml.resumptionToken(token, completeListSize: total, cursor: cursor)
        end
      end
    end

    def get_record
      id = params["identifier"].to_s.split(":").last
      record = store.find(id)
      halt 404, "no such record" unless record

      envelope("GetRecord") { |xml| xml.GetRecord { xml.record { record_body(xml, record) } } }
    end

    def header_fields(xml, record)
      xml.identifier "oai:grainger.unimelb.edu.au:#{record['id']}"
      xml.datestamp Time.parse(record["updated_at"].to_s).utc.iso8601
      xml.setSpec "grainger" unless record["deleted"]
    end

    def record_body(xml, record)
      if record["deleted"]
        xml.header(status: "deleted") { header_fields(xml, record) }
      else
        xml.header { header_fields(xml, record) }
        xml.metadata do
          xml.tag!("oai_dc:dc", "xmlns:oai_dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/", "xmlns:dc" => "http://purl.org/dc/elements/1.1/") do
            xml.tag!("dc:title", record["title"]) if record["title"]
            Array(record["creator"]).each { |c| xml.tag!("dc:creator", c) }
            xml.tag!("dc:date", record["date"]) if record["date"]
            xml.tag!("dc:type", record["type"]) if record["type"]
            Array(record["subject"]).each { |s| xml.tag!("dc:subject", s) }
            xml.tag!("dc:coverage", record["coverage"]) if record["coverage"]
            xml.tag!("dc:description", record["description"]) if record["description"]
            xml.tag!("dc:rights", record["rights"]) if record["rights"]
            xml.tag!("dc:identifier", record["identifier"]) if record["identifier"]
          end
        end
      end
    end

    def parse_time(value)
      value.nil? || value == "" ? nil : Time.parse(value.to_s).utc
    end

    run! if app_file == $0
  end
end
