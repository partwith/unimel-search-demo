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

  def all_ids = @records.map { |r| r[:id] }

  def until
    Time.current
  end
end

class FakeMapper
  def call(raw)
    raise Nexus::MappingError, "#{raw.id}: broken" if raw.metadata == :broken

    { id: raw.id, title_tesim: [raw.metadata] }
  end

  def id_for(raw_id) = raw_id
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

  it "passes a full id set to the reconciler on a full run" do
    described_class.perform_now("grainger", full: true)

    run = source.harvest_runs.last
    expect(run.cursor_from).to be_nil
  end

  # These two full-run reconciliation tests use their own harvester stub
  # with no explicit deleted ids, isolating the full_id_set/orphan-detection
  # behavior from the "deleted: ['grainger:GM-9999']" fixture the other
  # tests use.
  def stub_harvester_with_no_explicit_deletes
    allow(Nexus::Harvesters).to receive(:for).and_return(
      FakeHarvester.new(
        records: [
          { id: "grainger:GM-1", metadata: "Title One" },
          { id: "grainger:GM-2", metadata: :broken },
          { id: "grainger:GM-3", metadata: "Title Three" }
        ],
        deleted: []
      )
    )
  end

  it "deletes a stale document that is no longer present in a full run's upstream set" do
    stub_harvester_with_no_explicit_deletes
    allow(fake_solr).to receive(:get).and_return(
      "response" => {
        "docs" => [
          { "id" => "grainger:GM-1" }, { "id" => "grainger:GM-2" }, { "id" => "grainger:GM-3" },
          { "id" => "grainger:GM-STALE" }
        ]
      }
    )

    described_class.perform_now("grainger", full: true)

    expect(fake_solr).to have_received(:delete_by_id).with(["grainger:GM-STALE"])
  end

  # Regression test for the id-space/mapping-failure fix: GM-2 fails to map
  # this run but is already present in Solr from some earlier run. A full
  # run's full_id_set must still include it (via mapper#id_for), or the
  # reconciler would wrongly treat a transient mapping failure as proof
  # upstream deleted the record and delete otherwise-good, previously-
  # indexed data.
  it "does not delete a previously-indexed record that merely fails to map this run" do
    stub_harvester_with_no_explicit_deletes
    allow(fake_solr).to receive(:get).and_return(
      "response" => { "docs" => [{ "id" => "grainger:GM-1" }, { "id" => "grainger:GM-2" }, { "id" => "grainger:GM-3" }] }
    )

    described_class.perform_now("grainger", full: true)

    expect(fake_solr).not_to have_received(:delete_by_id)
  end
end
