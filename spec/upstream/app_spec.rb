require "spec_helper"
require "rack/test"
require "tmpdir"
require "fileutils"

ENV["UPSTREAM_DATA_PATH"] ||= Dir.mktmpdir + "/grainger.yml"
FileUtils.cp(File.expand_path("../../upstream/data/grainger.yml", __dir__), ENV["UPSTREAM_DATA_PATH"])
require_relative "../../upstream/app"

RSpec.describe "Nexus upstream OAI-PMH mock" do
  include Rack::Test::Methods
  def app = NexusUpstream::App

  it "responds to Identify" do
    get "/oai", verb: "Identify"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("<Identify")
  end

  it "paginates ListRecords with a resumptionToken, 3 per page" do
    get "/oai", verb: "ListRecords", metadataPrefix: "oai_dc"
    expect(last_response.body).to include("<resumptionToken")
    expect(last_response.body.scan("<record>").size).to eq(3)
  end

  it "follows a resumptionToken to the next page" do
    get "/oai", verb: "ListRecords", metadataPrefix: "oai_dc", resumptionToken: "3"
    expect(last_response.body.scan("<record>").size).to eq(3)
  end

  it "marks a deleted record with header status=deleted and no metadata" do
    get "/oai", verb: "GetRecord", identifier: "oai:grainger.unimelb.edu.au:GM-9999", metadataPrefix: "oai_dc"
    expect(last_response.body).to include('status="deleted"')
    expect(last_response.body).not_to include("<metadata>")
  end

  it "filters ListIdentifiers by from" do
    get "/oai", verb: "ListIdentifiers", metadataPrefix: "oai_dc", from: "2026-09-02T00:00:00Z"
    expect(last_response.body.scan("<identifier>").size).to eq(1)
    expect(last_response.body).to include("GM-9999")
    expect(last_response.body).to include('status="deleted"')
  end
end
