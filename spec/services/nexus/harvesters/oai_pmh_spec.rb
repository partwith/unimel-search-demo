require "rails_helper"
require "webmock/rspec"

RSpec.describe Nexus::Harvesters::OaiPmh do
  let(:source) do
    CollectionSource.new(
      config: { "base_url" => "http://upstream.test/oai", "set" => "grainger", "metadata_prefix" => "oai_dc" }
    )
  end
  let(:mapper) { Nexus::Mappers::GraingerOaiDc.new }
  let(:harvester) { described_class.new(source, mapper) }

  let(:page1) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
        <responseDate>2026-09-06T04:00:00Z</responseDate>
        <request verb="ListRecords">http://upstream.test/oai</request>
        <ListRecords>
          <record>
            <header>
              <identifier>oai:grainger.unimelb.edu.au:GM-0417</identifier>
              <datestamp>2026-09-05T10:12:00Z</datestamp>
              <setSpec>grainger</setSpec>
            </header>
            <metadata>
              <oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Free Music Machine, model 2</dc:title>
              </oai_dc:dc>
            </metadata>
          </record>
          <resumptionToken completeListSize="2" cursor="0">page-2</resumptionToken>
        </ListRecords>
      </OAI-PMH>
    XML
  end

  let(:page2) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
        <responseDate>2026-09-06T04:00:01Z</responseDate>
        <request verb="ListRecords">http://upstream.test/oai</request>
        <ListRecords>
          <record>
            <header status="deleted">
              <identifier>oai:grainger.unimelb.edu.au:GM-9999</identifier>
              <datestamp>2026-09-05T11:00:00Z</datestamp>
            </header>
          </record>
          <resumptionToken completeListSize="2" cursor="1"></resumptionToken>
        </ListRecords>
      </OAI-PMH>
    XML
  end

  before do
    stub_request(:get, /upstream\.test\/oai/).with(query: hash_including(verb: "ListRecords")).to_return(
      { body: page1, headers: { "Content-Type" => "text/xml" } },
      { body: page2, headers: { "Content-Type" => "text/xml" } }
    )
  end

  it "follows the resumptionToken and yields only non-deleted records" do
    yielded = []
    harvester.each(from: nil) { |raw| yielded << raw }

    expect(yielded.size).to eq(1)
    expect(yielded.first.id).to eq("oai:grainger.unimelb.edu.au:GM-0417")
  end

  # Regression test: OAI::Client::Record#metadata is the <metadata> wrapper
  # element itself, not the <oai_dc:dc> element inside it. DublinCore.parse
  # needs the latter as its root, or every field comes back empty.
  it "yields metadata that DublinCore can parse into actual Dublin Core fields" do
    yielded = []
    harvester.each(from: nil) { |raw| yielded << raw }

    dc = Nexus::DublinCore.parse(yielded.first.metadata)
    expect(dc["title"]).to eq(["Free Music Machine, model 2"])
  end

  # ListIdentifiers responses expose bare <header> elements as direct children
  # of <ListIdentifiers>, unlike ListRecords which wraps each <header> in a
  # <record>. So reusing page1/page2 needs both the container tag renamed and
  # the <record> wrapper stripped (a plain single `sub` of "ListRecords" would
  # only hit the `verb="ListRecords"` attribute, since that text appears
  # earlier in the document than the actual <ListRecords> element).
  def as_list_identifiers(xml)
    xml.gsub("<ListRecords>", "<ListIdentifiers>")
       .gsub("</ListRecords>", "</ListIdentifiers>")
       .gsub(%r{</?record>\n?}, "")
  end

  # Regression test: deleted_ids must return Solr document ids, not raw OAI
  # identifier URIs -- Reconciler passes these straight to Solr's
  # delete_by_id, which silently no-ops against ids that don't exist.
  it "translates deleted identifiers into Solr id space via the mapper" do
    stub_request(:get, /upstream\.test\/oai/).with(query: hash_including(verb: "ListIdentifiers")).to_return(
      { body: as_list_identifiers(page1).sub(%r{<metadata>.*</metadata>\n}m, ""), headers: { "Content-Type" => "text/xml" } },
      { body: as_list_identifiers(page2), headers: { "Content-Type" => "text/xml" } }
    )

    expect(harvester.deleted_ids(from: nil)).to eq(["grainger:GM-9999"])
  end
end
