# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

CollectionSource.find_or_create_by!(key: "grainger") do |source|
  source.name = "Grainger Museum"
  source.harvester = "oai_pmh"
  source.mapper = "Nexus::Mappers::GraingerOaiDc"
  source.schedule = "every 15 minutes"
  source.config = {
    "base_url" => ENV.fetch("UPSTREAM_URL", "http://localhost:4567/oai"),
    "set" => "grainger",
    "metadata_prefix" => "oai_dc",
    "collection_label" => "Grainger Museum"
  }
end
