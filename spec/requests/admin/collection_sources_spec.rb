require "rails_helper"

RSpec.describe "Admin::CollectionSources", type: :request do
  let!(:source) { CollectionSource.create!(key: "grainger", name: "Grainger Museum", harvester: "oai_pmh", mapper: "Nexus::Mappers::GraingerOaiDc") }

  it "lists sources" do
    get "/admin"
    expect(response.body).to include("Grainger Museum")
  end

  it "enqueues an incremental harvest" do
    expect { post "/admin/collection_sources/#{source.id}/harvest" }.to have_enqueued_job(HarvestCollectionJob).with("grainger")
    expect(response).to redirect_to("/admin")
  end

  it "enqueues a full re-index" do
    expect { post "/admin/collection_sources/#{source.id}/full_reindex" }.to have_enqueued_job(HarvestCollectionJob).with("grainger", full: true)
  end
end
