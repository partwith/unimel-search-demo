require "rails_helper"

RSpec.describe SearchBuilder do
  let(:scope) { CatalogController.new }
  let(:builder) { described_class.new(scope) }

  it "suppresses restricted records by default" do
    allow(builder).to receive(:blacklight_params).and_return({})
    params = {}
    builder.hide_restricted(params)
    expect(params[:fq]).to include('-rights_ssim:Restricted*')
  end

  it "admits restricted records when staff_view=1" do
    allow(builder).to receive(:blacklight_params).and_return({ staff_view: "1" })
    params = {}
    builder.hide_restricted(params)
    expect(params[:fq]).to be_nil
  end
end