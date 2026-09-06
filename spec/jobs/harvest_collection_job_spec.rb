require "rails_helper"

class FakeHarvester
  Raw = Struct.new(:id, :metadata, :datestamp, keyword_init: true)

  def initialize(records:, deleted: [])
    @records = records
    @deleted = deleted
  end

  def each(from:)
    @records.each { |r| yield Raw.new(id: r[:id], metadata: r[:metadata], datestamp: nil) }
  end

  def deleted_ids(from:)
    @deleted
  end

  def until
    Time.current
  end
end

class FakeMapper
  def call(raw)
    raise Nexus::MappingError, "#{raw.id}: broken" if raw.metadata == :broken

    { id: raw.id, title_tesim: [raw.metadata] }
  end
end

RSpec.describe HarvestCollectionJob do
  let(:source) do
    CollectionSource.create!(
      key: "grainger", name: "Grainger Museum", harvester: "oai_pmh",
      mapper: "FakeMapper", cursor: 1.hour.ago
    )
  end
  let(:fake_solr) { instance_spy("RSolr::Client", get: { "response" => { "docs" => [] } }) }

  before do
    allow(Nexus::Harvesters).to receive(:for).and_return(
      FakeHarvester.new(
        records: [
          { id: "grainger:GM-1", metadata: "Title One" },
          { id: "grainger:GM-2", metadata: :broken },
          { id: "grainger:GM-3", metadata: "Title Three" }
        ],
        deleted: ["grainger:GM-9999"]
      )
    )
    allow(Nexus::Indexer).to receive(:new).and_return(Nexus::Indexer.new(collection: "grainger", solr_client: fake_solr))
    allow(Nexus::Reconciler).to receive(:new).and_return(Nexus::Reconciler.new(source, solr_client: fake_solr))
  end

  it "indexes valid records, counts mapping errors, and records deletes" do
    described_class.perform_now("grainger")

    run = source.harvest_runs.last
    expect(run.status).to eq("success")
    expect(run.fetched).to eq(3)
    expect(run.indexed).to eq(2)
    expect(run.mapping_errors).to eq(1)
    expect(run.error_samples).to eq([{ "id" => "grainger:GM-2", "message" => "grainger:GM-2: broken" }])
    expect(run.deleted).to eq(1)
    expect(fake_solr).to have_received(:add).with([{ id: "grainger:GM-1", title_tesim: ["Title One"] }, { id: "grainger:GM-3", title_tesim: ["Title Three"] }])
  end

  it "advances the source cursor to the harvester's until time" do
    freeze_time do
      described_class.perform_now("grainger")
      expect(source.reload.cursor).to eq(Time.current)
    end
  end
end
