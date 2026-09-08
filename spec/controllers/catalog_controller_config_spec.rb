require "rails_helper"

RSpec.describe CatalogController do
  let(:config) { described_class.blacklight_config }

  it "exposes the cross-collection facets" do
    expect(config.facet_fields.keys).to include(
      "collection_ssim", "format_ssim", "creator_ssim",
      "place_ssim", "subject_ssim", "rights_ssim", "date_start_isi"
    )
  end

  it "boosts title and creator in the all_fields search" do
    qf = config.search_fields["all_fields"].solr_parameters[:qf]
    expect(qf).to include("title_tesim^100").and include("creator_tesim^50")
  end

  it "sorts by relevance then date by default" do
    expect(config.sort_fields.keys.first).to eq("score desc, date_start_isi asc")
  end

  it "preserves staff_view through Blacklight's search state filtering" do
    expect(config.search_state_fields).to include(:staff_view)
  end
end
