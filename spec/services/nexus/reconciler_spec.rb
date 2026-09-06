require "rails_helper"

RSpec.describe Nexus::Reconciler do
  let(:source) { CollectionSource.new(key: "grainger") }
  let(:fake_solr) { instance_spy("RSolr::Client") }
  let(:reconciler) { described_class.new(source, solr_client: fake_solr) }

  it "deletes the explicit deleted ids and returns the count" do
    count = reconciler.apply(["grainger:GM-9999"])

    expect(fake_solr).to have_received(:delete_by_id).with(["grainger:GM-9999"])
    expect(fake_solr).to have_received(:commit)
    expect(count).to eq(1)
  end

  it "also deletes orphans not present in a given full_id_set" do
    allow(fake_solr).to receive(:get).with("select", hash_including(params: hash_including(q: 'collection_ssim:"grainger"'))).and_return(
      "response" => { "docs" => [{ "id" => "grainger:GM-1" }, { "id" => "grainger:GM-2" }, { "id" => "grainger:GM-3" }] }
    )

    count = reconciler.apply([], full_id_set: ["grainger:GM-1", "grainger:GM-2"])

    expect(fake_solr).to have_received(:delete_by_id).with(["grainger:GM-3"])
    expect(count).to eq(1)
  end

  it "returns 0 and skips delete_by_id when there is nothing to delete" do
    count = reconciler.apply([])

    expect(fake_solr).not_to have_received(:delete_by_id)
    expect(count).to eq(0)
  end
end
