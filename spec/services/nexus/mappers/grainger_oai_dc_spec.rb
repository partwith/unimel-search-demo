require "rails_helper"

RSpec.describe Nexus::Mappers::GraingerOaiDc do
  let(:mapper) { described_class.new }
  let(:metadata) { File.read(Rails.root.join("spec/fixtures/files/oai_dc_record.xml")) }
  let(:raw) do
    Nexus::RawRecord.new(
      id: "oai:grainger.unimelb.edu.au:GM-0417",
      metadata: metadata,
      datestamp: "2026-09-05T10:12:00Z"
    )
  end

  it "maps Dublin Core fields into the unified schema" do
    doc = mapper.call(raw)

    expect(doc[:id]).to eq("grainger:GM-0417")
    expect(doc[:collection_ssim]).to eq(["Grainger Museum"])
    expect(doc[:title_tesim]).to eq(["Free Music Machine, model 2"])
    expect(doc[:creator_tesim]).to eq(["Grainger, Percy", "Cross, Burnett"])
    expect(doc[:date_start_isi]).to eq(1950)
    expect(doc[:date_end_isi]).to eq(1952)
    expect(doc[:source_url_ss]).to eq("https://grainger.unimelb.edu.au/collection/GM-0417")
    expect(doc[:source_system_ss]).to eq("Grainger Museum (OAI-PMH)")
  end

  it "strips attribution parentheticals from creator_ssim" do
    doc = mapper.call(raw)
    expect(doc[:creator_ssim]).to eq(["Grainger, Percy", "Cross, Burnett"])
  end

  it "handles a record with no creator" do
    no_creator_xml = metadata.sub(%r{<dc:creator>.*?</dc:creator>\s*}m, "").sub(%r{<dc:creator>.*?</dc:creator>\s*}m, "")
    raw_no_creator = Nexus::RawRecord.new(id: raw.id, metadata: no_creator_xml, datestamp: raw.datestamp)

    doc = mapper.call(raw_no_creator)

    expect(doc).not_to have_key(:creator_tesim)
    expect(doc).not_to have_key(:creator_ssim)
  end

  it "raises Nexus::MappingError when title is missing" do
    no_title_xml = metadata.sub(%r{<dc:title>.*?</dc:title>\s*}m, "")
    raw_no_title = Nexus::RawRecord.new(id: raw.id, metadata: no_title_xml, datestamp: raw.datestamp)

    expect { mapper.call(raw_no_title) }.to raise_error(Nexus::MappingError, /GM-0417/)
  end
end
