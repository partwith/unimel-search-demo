require "spec_helper"
require_relative "../../lib/nexus_upstream_store"
require "tmpdir"
require "fileutils"

RSpec.describe NexusUpstreamStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "grainger.yml")
      FileUtils.cp(File.expand_path("../../upstream/data/grainger.yml", __dir__), @path)
      example.run
    end
  end

  let(:store) { described_class.new(@path) }

  it "lists all records" do
    expect(store.records.map { |r| r["id"] }).to include("GM-0417", "GM-9999")
  end

  it "finds a record by id" do
    expect(store.find("GM-0417")["title"]).to eq("Free Music Machine, model 2")
  end

  it "updates a record and bumps updated_at" do
    before = store.find("GM-1102")["updated_at"]
    updated = store.update_record("GM-1102", "title" => "New Title")

    expect(updated["title"]).to eq("New Title")
    expect(store.find("GM-1102")["updated_at"]).to be > before
  end
end
