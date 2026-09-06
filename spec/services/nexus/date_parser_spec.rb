require "rails_helper"

RSpec.describe Nexus::DateParser do
  it "parses a single year" do
    expect(described_class.call("1867")).to eq([1867, 1867])
  end

  it "parses a year range" do
    expect(described_class.call("1950-1952")).to eq([1950, 1952])
  end

  it "parses an en-dash year range" do
    expect(described_class.call("1950–1952")).to eq([1950, 1952])
  end

  it "parses a decade" do
    expect(described_class.call("c. 1930s")).to eq([1930, 1939])
  end

  it "returns nils for n.d." do
    expect(described_class.call("n.d.")).to eq([nil, nil])
  end

  it "returns nils for blank input" do
    expect(described_class.call(nil)).to eq([nil, nil])
    expect(described_class.call("")).to eq([nil, nil])
  end
end
