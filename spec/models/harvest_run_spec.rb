require "rails_helper"

RSpec.describe HarvestRun do
  let(:source) { CollectionSource.create!(key: "grainger", name: "Grainger Museum", harvester: "oai_pmh", mapper: "M") }

  it "defaults counters to zero and status to running" do
    run = source.harvest_runs.create!(started_at: Time.current)

    expect(run.status).to eq("running")
    expect(run.fetched).to eq(0)
    expect(run.error_samples).to eq([])
  end

  it "serializes error_samples as an array of hashes" do
    run = source.harvest_runs.create!(started_at: Time.current, error_samples: [{ "id" => "GM-1", "message" => "bad" }])

    expect(described_class.find(run.id).error_samples).to eq([{ "id" => "GM-1", "message" => "bad" }])
  end
end
