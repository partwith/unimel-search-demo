require "rails_helper"

RSpec.describe Nexus::Indexer do
  let(:fake_solr) { instance_spy("RSolr::Client") }
  let(:indexer) { described_class.new(collection: "grainger", solr_client: fake_solr) }

  it "buffers added docs and sends them in one batch on commit" do
    indexer.add({ id: "grainger:GM-1" })
    indexer.add({ id: "grainger:GM-2" })
    indexer.commit

    expect(fake_solr).to have_received(:add).with([{ id: "grainger:GM-1" }, { id: "grainger:GM-2" }])
    expect(fake_solr).to have_received(:commit)
  end

  it "does not call add if nothing was buffered" do
    indexer.commit

    expect(fake_solr).not_to have_received(:add)
    expect(fake_solr).to have_received(:commit)
  end
end
