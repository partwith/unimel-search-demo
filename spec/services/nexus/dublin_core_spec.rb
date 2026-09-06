require "rails_helper"

RSpec.describe Nexus::DublinCore do
  let(:xml) { File.read(Rails.root.join("spec/fixtures/files/oai_dc_record.xml")) }
  let(:dc) { described_class.parse(xml) }

  it "collects repeated elements into arrays" do
    expect(dc["creator"]).to eq(["Grainger, Percy", "Cross, Burnett"])
    expect(dc["subject"]).to eq(["Experimental music", "Sound technology"])
  end

  it "collects single elements as one-item arrays" do
    expect(dc["title"]).to eq(["Free Music Machine, model 2"])
    expect(dc["date"]).to eq(["1950-1952"])
  end

  it "returns an empty array for a missing element" do
    expect(dc["publisher"]).to eq([])
  end
end
