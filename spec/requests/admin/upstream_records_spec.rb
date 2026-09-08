require "rails_helper"

RSpec.describe "Admin::UpstreamRecords", type: :request do
  around do |example|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "grainger.yml")
      FileUtils.cp(Rails.root.join("upstream/data/grainger.yml"), path)
      original = ENV["UPSTREAM_DATA_PATH"]
      ENV["UPSTREAM_DATA_PATH"] = path
      example.run
      ENV["UPSTREAM_DATA_PATH"] = original
    end
  end

  it "lists upstream records" do
    get "/admin/upstream_records"
    expect(response.body).to include("GM-0417")
  end

  it "updates a record's title and marks it not deleted" do
    patch "/admin/upstream_records/GM-1102", params: { upstream_record: { title: "New Title" } }

    expect(response).to redirect_to("/admin/upstream_records")
    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1102")["title"]).to eq("New Title")
  end

  it "marks a record deleted" do
    patch "/admin/upstream_records/GM-1540", params: { upstream_record: { deleted: "1" } }

    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1540")["deleted"]).to be true
  end

  it "un-marks a record as deleted when the checkbox is unchecked" do
    patch "/admin/upstream_records/GM-1540", params: { upstream_record: { deleted: "1" } }
    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1540")["deleted"]).to be true

    patch "/admin/upstream_records/GM-1540", params: { upstream_record: { deleted: "0" } }
    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1540")["deleted"]).to be false
  end
end
