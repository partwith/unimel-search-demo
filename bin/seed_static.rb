#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"

solr_url = ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")
data_path = File.expand_path("../db/seeds/nexus_demo_data.json", __dir__)

records = JSON.parse(File.read(data_path))
uri = URI("#{solr_url}/update?commit=true")

request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
request.body = JSON.generate(records)

response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
unless response.is_a?(Net::HTTPSuccess)
  warn "Solr seed failed: #{response.code} #{response.body}"
  exit 1
end

puts "Seeded #{records.size} static records into #{solr_url}"
