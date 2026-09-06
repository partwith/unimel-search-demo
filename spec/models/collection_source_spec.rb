require "rails_helper"

RSpec.describe CollectionSource do
  it "serializes config as a hash" do
    source = described_class.create!(
      key: "grainger", name: "Grainger Museum", harvester: "oai_pmh",
      config: { "base_url" => "http://upstream:4567/oai", "set" => "grainger", "metadata_prefix" => "oai_dc" },
      mapper: "Nexus::Mappers::GraingerOaiDc", schedule: "every 15 minutes"
    )

    expect(described_class.find(source.id).config).to eq(
      "base_url" => "http://upstream:4567/oai", "set" => "grainger", "metadata_prefix" => "oai_dc"
    )
  end

  it "requires a unique key" do
    described_class.create!(key: "grainger", name: "A", harvester: "oai_pmh", mapper: "M")
    dup = described_class.new(key: "grainger", name: "B", harvester: "oai_pmh", mapper: "M")

    expect(dup).not_to be_valid
  end
end
