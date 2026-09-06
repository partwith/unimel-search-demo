require "rails_helper"

RSpec.describe "Admin::HarvestRuns", type: :request do
  let(:source) { CollectionSource.create!(key: "grainger", name: "Grainger Museum", harvester: "oai_pmh", mapper: "M") }

  it "lists runs with counts and error samples" do
    source.harvest_runs.create!(
      started_at: 1.minute.ago, finished_at: Time.current, status: "success",
      fetched: 3, indexed: 2, mapping_errors: 1,
      error_samples: [{ "id" => "grainger:GM-2", "message" => "broken" }]
    )

    get "/admin/harvest_runs"

    expect(response.body).to include("success")
    expect(response.body).to include("grainger:GM-2")
    expect(response.body).to include("broken")
  end
end
