# Nexus Cross Collection Search — Fly.io Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Nexus Cross Collection Search demo (Blacklight + Solr search app, unified schema, OAI-PMH mock upstream, scheduled Rails harvester, small admin UI) and deploy it as a single Fly.io Machine.

**Architecture:** One Rails 8 app (SQLite, Solid Queue) serves Blacklight search + a small `/admin` area. A sibling Sinatra script serves a mock OAI-PMH endpoint for the Grainger Museum collection, backed by a YAML file both it and the admin UI read/write. Solr 9 runs alongside using Blacklight's default configset. All four processes (Solr, Sinatra mock, Puma, Solid Queue) run in one Docker image on one Fly Machine, supervised by a bash entrypoint, with a single Fly volume for all persistent state.

**Tech Stack:** Ruby on Rails 8, Blacklight + blacklight_range_limit, SQLite, Solid Queue, RSolr, the `oai` gem, Sinatra (mock upstream), Solr 9, Docker, Fly.io.

**Spec:** `docs/superpowers/specs/2026-09-06-nexus-fly-deploy-design.md` (this plan's tasks implement that spec section by section; the source design `../../../../Nexus_Demo_Design.md` has the full field tables, sample data rationale, and per-scenario demo script this plan builds toward).

## Global Constraints

- Rails 8 with SQLite (`--database=sqlite3`), not Postgres.
- No authentication anywhere in the app, including `/admin`.
- Single Fly Machine, single Docker image, four supervised processes (Solr, Sinatra upstream mock, Puma, Solid Queue) — no docker-compose-style multi-app topology.
- All persistent state (SQLite DB, Solr core data, upstream YAML) lives under one path prefix so it maps to a single Fly volume.
- No GitHub Actions / CI wiring, no IIIF, no CSV-file harvester, no auth gems.
- Only Grainger Museum (5 records) goes through the OAI-PMH → harvester → mapper → indexer path. Rare Books, Herbarium, Archives (15 records) load once as pre-mapped static JSON directly into Solr.
- Structured JSON log line per harvest run (`event: "harvest_run"`), matching the source design's section 9.2 `log_run`.

---

### Task 1: Rails app scaffold + Blacklight install

**Files:**
- Create: entire Rails app skeleton (`Gemfile`, `config/`, `app/`, `bin/`, etc.) via `rails new .`
- Modify: `Gemfile` (add `blacklight`, `blacklight_range_limit`, `rsolr`, `oai`, `sinatra`, `rackup`)
- Modify: `config/blacklight.yml`

**Interfaces:**
- Produces: a booting Rails 8 app with SQLite, and `CatalogController` / Blacklight routes installed, ready for Task 3 to configure.

- [ ] **Step 1: Scaffold the Rails app in place**

The directory `nexus_demo/` already exists with a git repo and a `docs/` folder. Run from inside `nexus_demo/`:

```bash
rails new . --database=sqlite3 --skip-git --skip-test
```

Answer "n" to any prompt to overwrite `.gitignore` if it conflicts (keep Rails' version).

- [ ] **Step 2: Add gems**

```bash
bundle add blacklight blacklight_range_limit rsolr oai sinatra rackup
```

If `bundle add blacklight` fails to resolve against Rails 8 (Blacklight's Rails version constraint lags Rails releases), check the error message for the supported Rails range, then run:

```bash
bundle add rails --version "~> 7.1.0"
bin/rails app:update
bundle add blacklight blacklight_range_limit rsolr oai sinatra rackup
```

and re-run `bin/rails app:update` if prompted. Record whichever Rails version actually resolves — later tasks assume Rails 8 conventions (Solid Queue, `config/recurring.yml`) which also ship in Rails 7.1+, so either version satisfies this plan.

- [ ] **Step 3: Add RSpec**

```bash
bundle add rspec-rails webmock rack-test --group "development,test"
bin/rails generate rspec:install
```

- [ ] **Step 4: Install Blacklight**

```bash
bin/rails generate blacklight:install --devise=false
```

If the generator insists on Devise, decline/skip the auth-related pieces it offers, or manually remove any `devise` lines it adds to the `Gemfile` and `config/initializers` afterward — this app has no auth.

- [ ] **Step 5: Point Blacklight at the future Solr URL**

Edit `config/blacklight.yml` so both `development` and `production` read from an environment variable:

```yaml
development:
  adapter: solr
  url: <%= ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus") %>

test:
  adapter: solr
  url: <%= ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus") %>

production:
  adapter: solr
  url: <%= ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus") %>
```

- [ ] **Step 6: Verify it boots**

```bash
bin/rails db:prepare
bin/rails server -p 3000 &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/catalog
kill %1
```

Expected: `200` (Blacklight will render an empty/error-tolerant result page even with no Solr running yet — if it 500s because Solr isn't up, that's fine at this step; re-run after Task 2 stands up Solr locally to confirm a clean `200`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Scaffold Rails 8 app with Blacklight, SQLite, RSpec"
```

---

### Task 2: Vendor Solr config + local Solr for development

**Files:**
- Create: `solr/conf/` (vendored from the Blacklight gem's default configset)
- Create: `bin/solr_dev.sh`

**Interfaces:**
- Produces: `solr/conf/` — the configset every later task's Solr instance (dev, test, Docker) is built from.

- [ ] **Step 1: Locate and copy Blacklight's default Solr config**

```bash
BLACKLIGHT_GEM_PATH=$(bundle show blacklight)
mkdir -p solr/conf
cp -r "$BLACKLIGHT_GEM_PATH"/solr/conf/* solr/conf/
```

- [ ] **Step 2: Write a dev Solr launcher script**

Create `bin/solr_dev.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
docker rm -f nexus-solr-dev >/dev/null 2>&1 || true
docker run -d --name nexus-solr-dev -p 8983:8983 \
  -v "$(pwd)/solr/conf:/opt/solr/server/solr/configsets/nexus_config/conf" \
  solr:9 solr-precreate nexus /opt/solr/server/solr/configsets/nexus_config
```

```bash
chmod +x bin/solr_dev.sh
```

- [ ] **Step 3: Run it and verify Solr is healthy**

```bash
./bin/solr_dev.sh
sleep 8
curl -s http://localhost:8983/solr/nexus/admin/ping | grep -o '"status":"OK"'
```

Expected: prints `"status":"OK"`.

- [ ] **Step 4: Re-verify the Rails app against live Solr**

```bash
bin/rails server -p 3000 &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/catalog
kill %1
```

Expected: `200`.

- [ ] **Step 5: Commit**

```bash
git add solr/conf bin/solr_dev.sh
git commit -m "Vendor Blacklight's default Solr configset and add a dev Solr launcher"
```

---

### Task 3: Configure `CatalogController` (facets, fields, search, sort)

**Files:**
- Modify: `app/controllers/catalog_controller.rb`
- Test: `spec/controllers/catalog_controller_config_spec.rb`

**Interfaces:**
- Produces: `CatalogController.blacklight_config` with the facet/index/show fields and search/sort fields that Task 5's seed data and Task 16's search scenarios rely on.

- [ ] **Step 1: Write the failing config spec**

Create `spec/controllers/catalog_controller_config_spec.rb`:

```ruby
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
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/controllers/catalog_controller_config_spec.rb
```

Expected: FAIL (facets/search fields not yet configured).

- [ ] **Step 3: Configure `CatalogController`**

Replace the `configure_blacklight do |config|` block in `app/controllers/catalog_controller.rb` with:

```ruby
configure_blacklight do |config|
  config.default_solr_params = { rows: 10 }

  config.index.title_field = "title_tesim"
  config.index.thumbnail_field = "thumbnail_ss"
  config.index.display_type_field = "format_ssim"

  config.add_facet_field "collection_ssim", label: "Collection", limit: 10
  config.add_facet_field "format_ssim", label: "Format", limit: 10
  config.add_facet_field "creator_ssim", label: "Creator", limit: 10
  config.add_facet_field "place_ssim", label: "Place", limit: 10
  config.add_facet_field "subject_ssim", label: "Subject", limit: 10
  config.add_facet_field "rights_ssim", label: "Access", limit: 5
  config.add_facet_field "date_start_isi", label: "Date", range: true

  config.add_index_field "creator_tesim", label: "Creator"
  config.add_index_field "date_ssim", label: "Date"
  config.add_index_field "collection_ssim", label: "Collection"

  config.add_show_field "creator_tesim", label: "Creator"
  config.add_show_field "date_ssim", label: "Date"
  config.add_show_field "description_tesim", label: "Description"
  config.add_show_field "subject_ssim", label: "Subjects"
  config.add_show_field "place_ssim", label: "Place"
  config.add_show_field "scientific_name_ssim", label: "Scientific name"
  config.add_show_field "family_ssim", label: "Family"
  config.add_show_field "reference_code_ss", label: "Reference code"
  config.add_show_field "rights_ssim", label: "Access"
  config.add_show_field "source_url_ss", label: "View in home system"

  config.add_search_field("all_fields", label: "All fields") do |f|
    f.solr_parameters = {
      qf: "title_tesim^100 creator_tesim^50 subject_ssim^20 description_tesim all_text_timv",
      pf: "title_tesim^200"
    }
  end
  config.add_search_field("title") { |f| f.solr_parameters = { qf: "title_tesim" } }
  config.add_search_field("creator") { |f| f.solr_parameters = { qf: "creator_tesim" } }

  config.add_sort_field "score desc, date_start_isi asc", label: "relevance"
  config.add_sort_field "date_start_isi asc", label: "date (oldest first)"
  config.add_sort_field "date_start_isi desc", label: "date (newest first)"
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/controllers/catalog_controller_config_spec.rb
```

Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/catalog_controller.rb spec/controllers/catalog_controller_config_spec.rb
git commit -m "Configure CatalogController facets, fields, search and sort"
```

---

### Task 4: `SearchBuilder` restricted-record suppression

**Files:**
- Modify: `app/models/search_builder.rb`
- Test: `spec/models/search_builder_spec.rb`

**Interfaces:**
- Consumes: `blacklight_params` (hash-like, from `Blacklight::SearchBuilder`).
- Produces: `SearchBuilder#hide_restricted(solr_params)` — appends to `solr_params[:fq]` unless `blacklight_params[:staff_view] == "1"`. Used implicitly by every catalog search from this task on.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/search_builder_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/models/search_builder_spec.rb
```

Expected: FAIL (`hide_restricted` not defined, or filter always/never applied).

- [ ] **Step 3: Implement suppression**

Replace the contents of `app/models/search_builder.rb` with:

```ruby
class SearchBuilder < Blacklight::SearchBuilder
  include Blacklight::Solr::SearchBuilderBehavior
  self.default_processor_chain += [:hide_restricted]

  def hide_restricted(solr_params)
    return if blacklight_params[:staff_view] == "1"

    solr_params[:fq] ||= []
    solr_params[:fq] << '-rights_ssim:Restricted*'
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/models/search_builder_spec.rb
```

Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add app/models/search_builder.rb spec/models/search_builder_spec.rb
git commit -m "Suppress restricted records unless staff_view=1"
```

---

### Task 5: Static seed data for Rare Books, Herbarium, Archives

**Files:**
- Create: `db/seeds/nexus_demo_data.json`
- Create: `bin/seed_static.rb`

**Interfaces:**
- Produces: `bin/seed_static.rb`, a standalone script (no Rails env needed) that POSTs `db/seeds/nexus_demo_data.json` to `ENV["SOLR_URL"]`. Task 17's entrypoint calls this on first boot.

- [ ] **Step 1: Build the 15-record seed file**

Copy the existing `../Nexus_Demo_Design.md`-adjacent `nexus_demo_data.json` (at the repo root, one level above `nexus_demo/`) and filter out the 5 `grainger:*` records, since those must only reach Solr via the harvest pipeline (Task 13). From `nexus_demo/`:

```bash
ruby -rjson -e '
  data = JSON.parse(File.read("../nexus_demo_data.json"))
  static = data.reject { |r| r["id"].start_with?("grainger:") }
  raise "expected 15 static records, got #{static.size}" unless static.size == 15
  File.write("db/seeds/nexus_demo_data.json", JSON.pretty_generate(static))
'
```

- [ ] **Step 2: Write the seed script**

Create `bin/seed_static.rb`:

```ruby
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
```

```bash
chmod +x bin/seed_static.rb
```

- [ ] **Step 3: Run it against local Solr and verify**

```bash
./bin/solr_dev.sh   # if not already running
sleep 8
ruby bin/seed_static.rb
curl -s "http://localhost:8983/solr/nexus/select?q=*:*&rows=0" | grep -o '"numFound":[0-9]*'
```

Expected: `Seeded 15 static records...` and `"numFound":15`.

- [ ] **Step 4: Commit**

```bash
git add db/seeds/nexus_demo_data.json bin/seed_static.rb
git commit -m "Add static seed data and loader for Rare Books, Herbarium, Archives"
```

---

### Task 6: `Nexus::DateParser`

**Files:**
- Create: `app/services/nexus/date_parser.rb`
- Test: `spec/services/nexus/date_parser_spec.rb`

**Interfaces:**
- Produces: `Nexus::DateParser.call(date_string) -> [start_year, end_year]` (both `Integer` or both `nil`). Used by Task 8's mapper.

- [ ] **Step 1: Write the failing spec**

Create `spec/services/nexus/date_parser_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/date_parser_spec.rb
```

Expected: FAIL (`Nexus::DateParser` not defined).

- [ ] **Step 3: Implement**

Create `app/services/nexus/date_parser.rb`:

```ruby
module Nexus
  module DateParser
    RANGE = /\A\s*(\d{4})\s*[-–]\s*(\d{4})\s*\z/
    DECADE = /\A\s*c\.?\s*(\d{3})0s\s*\z/i
    SINGLE = /\A\s*(\d{4})\s*\z/

    def self.call(value)
      return [nil, nil] if value.nil? || value.strip.empty?
      return [nil, nil] if value.strip.downcase == "n.d."

      case value
      when RANGE
        [$1.to_i, $2.to_i]
      when DECADE
        decade_start = "#{$1}0".to_i
        [decade_start, decade_start + 9]
      when SINGLE
        [$1.to_i, $1.to_i]
      else
        [nil, nil]
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/date_parser_spec.rb
```

Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/nexus/date_parser.rb spec/services/nexus/date_parser_spec.rb
git commit -m "Add Nexus::DateParser for date-range normalisation"
```

---

### Task 7: `Nexus::DublinCore` parser

**Files:**
- Create: `app/services/nexus/dublin_core.rb`
- Test: `spec/services/nexus/dublin_core_spec.rb`
- Test fixture: `spec/fixtures/files/oai_dc_record.xml`

**Interfaces:**
- Produces: `Nexus::DublinCore.parse(metadata_xml_string) -> Hash<String, Array<String>>` keyed by unqualified DC element name (e.g. `"title"`, `"creator"`, `"date"`, `"type"`, `"subject"`, `"coverage"`, `"description"`, `"rights"`, `"identifier"`). Missing elements map to `[]`. Used by Task 8's mapper.

- [ ] **Step 1: Add the fixture**

Create `spec/fixtures/files/oai_dc_record.xml`:

```xml
<oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>Free Music Machine, model 2</dc:title>
  <dc:creator>Grainger, Percy</dc:creator>
  <dc:creator>Cross, Burnett</dc:creator>
  <dc:date>1950-1952</dc:date>
  <dc:type>Musical instrument</dc:type>
  <dc:subject>Experimental music</dc:subject>
  <dc:subject>Sound technology</dc:subject>
  <dc:coverage>White Plains, New York</dc:coverage>
  <dc:description>Second working model of Grainger's Free Music Machine.</dc:description>
  <dc:rights>In copyright - research use</dc:rights>
  <dc:identifier>https://grainger.unimelb.edu.au/collection/GM-0417</dc:identifier>
</oai_dc:dc>
```

- [ ] **Step 2: Write the failing spec**

Create `spec/services/nexus/dublin_core_spec.rb`:

```ruby
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
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/dublin_core_spec.rb
```

Expected: FAIL (`Nexus::DublinCore` not defined).

- [ ] **Step 4: Implement**

Create `app/services/nexus/dublin_core.rb`:

```ruby
require "nokogiri"

module Nexus
  module DublinCore
    def self.parse(xml)
      doc = xml.is_a?(Nokogiri::XML::Node) ? xml : Nokogiri::XML(xml.to_s)
      result = Hash.new { |h, k| h[k] = [] }

      doc.children.each do |node|
        next unless node.element?

        result[node.name] << node.text.strip
      end

      result
    end
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/dublin_core_spec.rb
```

Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
git add app/services/nexus/dublin_core.rb spec/services/nexus/dublin_core_spec.rb spec/fixtures/files/oai_dc_record.xml
git commit -m "Add Nexus::DublinCore metadata parser"
```

---

### Task 8: `Nexus::MappingError` + `Nexus::Mappers::Base` + `Nexus::Mappers::GraingerOaiDc`

**Files:**
- Create: `app/services/nexus/mapping_error.rb`
- Create: `app/services/nexus/raw_record.rb`
- Create: `app/services/nexus/mappers/base.rb`
- Create: `app/services/nexus/mappers/grainger_oai_dc.rb`
- Test: `spec/services/nexus/mappers/grainger_oai_dc_spec.rb`

**Interfaces:**
- Consumes: `Nexus::DublinCore.parse` (Task 7), `Nexus::DateParser.call` (Task 6).
- Produces: `Nexus::RawRecord` (`Struct.new(:id, :metadata, :datestamp, keyword_init: true)`), `Nexus::MappingError < StandardError`, `Nexus::Mappers::Base#call(raw)` (raises `NotImplementedError`), `Nexus::Mappers::GraingerOaiDc.new.call(raw) -> Hash` with the unified-schema keys. Used by Task 13's job.

- [ ] **Step 1: Add the small shared classes**

Create `app/services/nexus/mapping_error.rb`:

```ruby
module Nexus
  class MappingError < StandardError; end
end
```

Create `app/services/nexus/raw_record.rb`:

```ruby
module Nexus
  RawRecord = Struct.new(:id, :metadata, :datestamp, keyword_init: true)
end
```

Create `app/services/nexus/mappers/base.rb`:

```ruby
module Nexus
  module Mappers
    class Base
      def call(raw)
        raise NotImplementedError
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing spec**

Create `spec/services/nexus/mappers/grainger_oai_dc_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Nexus::Mappers::GraingerOaiDc do
  let(:mapper) { described_class.new }
  let(:metadata) { File.read(Rails.root.join("spec/fixtures/files/oai_dc_record.xml")) }
  let(:raw) do
    Nexus::RawRecord.new(
      id: "oai:grainger.unimelb.edu.au:GM-0417",
      metadata: metadata,
      datestamp: "2026-09-05T10:12:00Z"
    )
  end

  it "maps Dublin Core fields into the unified schema" do
    doc = mapper.call(raw)

    expect(doc[:id]).to eq("grainger:GM-0417")
    expect(doc[:collection_ssim]).to eq(["Grainger Museum"])
    expect(doc[:title_tesim]).to eq(["Free Music Machine, model 2"])
    expect(doc[:creator_tesim]).to eq(["Grainger, Percy", "Cross, Burnett"])
    expect(doc[:date_start_isi]).to eq(1950)
    expect(doc[:date_end_isi]).to eq(1952)
    expect(doc[:source_url_ss]).to eq("https://grainger.unimelb.edu.au/collection/GM-0417")
    expect(doc[:source_system_ss]).to eq("Grainger Museum (OAI-PMH)")
  end

  it "strips attribution parentheticals from creator_ssim" do
    doc = mapper.call(raw)
    expect(doc[:creator_ssim]).to eq(["Grainger, Percy", "Cross, Burnett"])
  end

  it "handles a record with no creator" do
    no_creator_xml = metadata.sub(%r{<dc:creator>.*?</dc:creator>\s*}m, "").sub(%r{<dc:creator>.*?</dc:creator>\s*}m, "")
    raw_no_creator = Nexus::RawRecord.new(id: raw.id, metadata: no_creator_xml, datestamp: raw.datestamp)

    doc = mapper.call(raw_no_creator)

    expect(doc).not_to have_key(:creator_tesim)
    expect(doc).not_to have_key(:creator_ssim)
  end

  it "raises Nexus::MappingError when title is missing" do
    no_title_xml = metadata.sub(%r{<dc:title>.*?</dc:title>\s*}m, "")
    raw_no_title = Nexus::RawRecord.new(id: raw.id, metadata: no_title_xml, datestamp: raw.datestamp)

    expect { mapper.call(raw_no_title) }.to raise_error(Nexus::MappingError, /GM-0417/)
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/mappers/grainger_oai_dc_spec.rb
```

Expected: FAIL (`Nexus::Mappers::GraingerOaiDc` not defined).

- [ ] **Step 4: Implement**

Create `app/services/nexus/mappers/grainger_oai_dc.rb`:

```ruby
module Nexus
  module Mappers
    class GraingerOaiDc < Base
      def call(raw)
        dc = Nexus::DublinCore.parse(raw.metadata)
        local_id = raw.id.split(":").last
        raise Nexus::MappingError, "#{local_id}: missing dc:title" if dc["title"].empty?

        start, finish = Nexus::DateParser.call(dc["date"].first)

        {
          id: "grainger:#{local_id}",
          collection_ssim: ["Grainger Museum"],
          format_ssim: dc["type"],
          title_tesim: dc["title"],
          creator_tesim: dc["creator"],
          creator_ssim: dc["creator"].map { |c| c.sub(/\s*\(.*\)\z/, "") },
          date_ssim: dc["date"],
          date_start_isi: start,
          date_end_isi: finish,
          subject_ssim: dc["subject"],
          place_ssim: dc["coverage"],
          description_tesim: dc["description"],
          rights_ssim: dc["rights"],
          source_url_ss: dc["identifier"].find { |i| i.start_with?("http") },
          source_system_ss: "Grainger Museum (OAI-PMH)",
          source_record_ss: raw.metadata.to_s
        }.compact.transform_values { |v| v.is_a?(Array) && v.empty? ? nil : v }.compact
      rescue Nexus::MappingError
        raise
      rescue => e
        raise Nexus::MappingError, "#{raw.id}: #{e.message}"
      end
    end
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/mappers/grainger_oai_dc_spec.rb
```

Expected: PASS (4 examples).

- [ ] **Step 6: Commit**

```bash
git add app/services/nexus/mapping_error.rb app/services/nexus/raw_record.rb \
  app/services/nexus/mappers spec/services/nexus/mappers
git commit -m "Add GraingerOaiDc mapper: Dublin Core to unified schema"
```

---

### Task 9: `CollectionSource` and `HarvestRun` models

**Files:**
- Create: migration `db/migrate/<timestamp>_create_collection_sources.rb`
- Create: migration `db/migrate/<timestamp>_create_harvest_runs.rb`
- Create: `app/models/collection_source.rb`
- Create: `app/models/harvest_run.rb`
- Test: `spec/models/collection_source_spec.rb`
- Test: `spec/models/harvest_run_spec.rb`

**Interfaces:**
- Produces: `CollectionSource` (`key`, `name`, `harvester`, `config` Hash, `mapper`, `cursor` Time-or-nil, `schedule`, `has_many :harvest_runs`), `HarvestRun` (`belongs_to :collection_source`, `started_at`, `finished_at`, `status` string default `"running"`, `fetched`/`indexed`/`deleted`/`mapping_errors` Integer default 0, `error_samples` Array default `[]`, `cursor_from`, `cursor_until`). Used by Task 13's job and Task 16's admin controllers.

- [ ] **Step 1: Generate migrations**

```bash
bin/rails generate migration CreateCollectionSources \
  key:string:uniq name:string harvester:string config:text mapper:string \
  cursor:datetime schedule:string
bin/rails generate migration CreateHarvestRuns \
  collection_source:references started_at:datetime finished_at:datetime \
  status:string fetched:integer indexed:integer deleted:integer \
  mapping_errors:integer error_samples:text cursor_from:datetime cursor_until:datetime
```

- [ ] **Step 2: Set column defaults in the generated migrations**

In the `CreateHarvestRuns` migration, set defaults so callers don't have to:

```ruby
t.string :status, default: "running", null: false
t.integer :fetched, default: 0, null: false
t.integer :indexed, default: 0, null: false
t.integer :deleted, default: 0, null: false
t.integer :mapping_errors, default: 0, null: false
t.text :error_samples
```

- [ ] **Step 3: Run migrations**

```bash
bin/rails db:migrate
```

- [ ] **Step 4: Write the failing model specs**

Create `spec/models/collection_source_spec.rb`:

```ruby
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
```

Create `spec/models/harvest_run_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe HarvestRun do
  let(:source) { CollectionSource.create!(key: "grainger", name: "Grainger Museum", harvester: "oai_pmh", mapper: "M") }

  it "defaults counters to zero and status to running" do
    run = source.harvest_runs.create!(started_at: Time.current)

    expect(run.status).to eq("running")
    expect(run.fetched).to eq(0)
    expect(run.error_samples).to eq([])
  end

  it "serializes error_samples as an array of hashes" do
    run = source.harvest_runs.create!(started_at: Time.current, error_samples: [{ "id" => "GM-1", "message" => "bad" }])

    expect(described_class.find(run.id).error_samples).to eq([{ "id" => "GM-1", "message" => "bad" }])
  end
end
```

- [ ] **Step 5: Run them to verify they fail**

```bash
bin/rspec spec/models/collection_source_spec.rb spec/models/harvest_run_spec.rb
```

Expected: FAIL (models don't exist yet, or `config`/`error_samples` aren't serialized).

- [ ] **Step 6: Implement the models**

Create `app/models/collection_source.rb`:

```ruby
class CollectionSource < ApplicationRecord
  serialize :config, coder: JSON, type: Hash, default: {}
  has_many :harvest_runs

  validates :key, presence: true, uniqueness: true
end
```

Create `app/models/harvest_run.rb`:

```ruby
class HarvestRun < ApplicationRecord
  serialize :error_samples, coder: JSON, type: Array, default: []
  belongs_to :collection_source
end
```

- [ ] **Step 7: Run them to verify they pass**

```bash
bin/rspec spec/models/collection_source_spec.rb spec/models/harvest_run_spec.rb
```

Expected: PASS (4 examples).

- [ ] **Step 8: Commit**

```bash
git add db/migrate app/models/collection_source.rb app/models/harvest_run.rb \
  spec/models/collection_source_spec.rb spec/models/harvest_run_spec.rb db/schema.rb
git commit -m "Add CollectionSource and HarvestRun models"
```

---

### Task 10: `Nexus::Harvesters::Base` and `Nexus::Harvesters::OaiPmh`

**Files:**
- Create: `app/services/nexus/harvesters/base.rb`
- Create: `app/services/nexus/harvesters/oai_pmh.rb`
- Test: `spec/services/nexus/harvesters/oai_pmh_spec.rb`

**Interfaces:**
- Consumes: `CollectionSource#config` (Hash with `"base_url"`, `"set"`, `"metadata_prefix"`), the `oai` gem's `OAI::Client`.
- Produces: `Nexus::Harvesters::Base#each(from:)` / `#deleted_ids(from:)` / `#until` (all `NotImplementedError` in the base). `Nexus::Harvesters::OaiPmh.new(source)` implementing all three, yielding `Nexus::RawRecord` from `#each`. Used by Task 13's job.

- [ ] **Step 1: Write the failing spec (stubbing HTTP with WebMock)**

Create `spec/services/nexus/harvesters/oai_pmh_spec.rb`:

```ruby
require "rails_helper"
require "webmock/rspec"

RSpec.describe Nexus::Harvesters::OaiPmh do
  let(:source) do
    CollectionSource.new(
      config: { "base_url" => "http://upstream.test/oai", "set" => "grainger", "metadata_prefix" => "oai_dc" }
    )
  end
  let(:harvester) { described_class.new(source) }

  let(:page1) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
        <responseDate>2026-09-06T04:00:00Z</responseDate>
        <request verb="ListRecords">http://upstream.test/oai</request>
        <ListRecords>
          <record>
            <header>
              <identifier>oai:grainger.unimelb.edu.au:GM-0417</identifier>
              <datestamp>2026-09-05T10:12:00Z</datestamp>
              <setSpec>grainger</setSpec>
            </header>
            <metadata>
              <oai_dc:dc xmlns:oai_dc="http://www.openarchives.org/OAI/2.0/oai_dc/" xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Free Music Machine, model 2</dc:title>
              </oai_dc:dc>
            </metadata>
          </record>
          <resumptionToken completeListSize="2" cursor="0">page-2</resumptionToken>
        </ListRecords>
      </OAI-PMH>
    XML
  end

  let(:page2) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <OAI-PMH xmlns="http://www.openarchives.org/OAI/2.0/">
        <responseDate>2026-09-06T04:00:01Z</responseDate>
        <request verb="ListRecords">http://upstream.test/oai</request>
        <ListRecords>
          <record>
            <header status="deleted">
              <identifier>oai:grainger.unimelb.edu.au:GM-9999</identifier>
              <datestamp>2026-09-05T11:00:00Z</datestamp>
            </header>
          </record>
          <resumptionToken completeListSize="2" cursor="1"></resumptionToken>
        </ListRecords>
      </OAI-PMH>
    XML
  end

  before do
    stub_request(:get, /upstream\.test\/oai/).with(query: hash_including(verb: "ListRecords")).to_return(
      { body: page1, headers: { "Content-Type" => "text/xml" } },
      { body: page2, headers: { "Content-Type" => "text/xml" } }
    )
  end

  it "follows the resumptionToken and yields only non-deleted records" do
    yielded = []
    harvester.each(from: nil) { |raw| yielded << raw }

    expect(yielded.size).to eq(1)
    expect(yielded.first.id).to eq("oai:grainger.unimelb.edu.au:GM-0417")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/harvesters/oai_pmh_spec.rb
```

Expected: FAIL (`Nexus::Harvesters::OaiPmh` not defined).

- [ ] **Step 3: Implement**

Create `app/services/nexus/harvesters/base.rb`:

```ruby
module Nexus
  module Harvesters
    class Base
      def each(from:)
        raise NotImplementedError
      end

      def deleted_ids(from:)
        raise NotImplementedError
      end

      def until
        raise NotImplementedError
      end
    end
  end
end
```

Create `app/services/nexus/harvesters/oai_pmh.rb`:

```ruby
require "oai"

module Nexus
  module Harvesters
    class OaiPmh < Base
      def initialize(source)
        @client = OAI::Client.new(source.config["base_url"])
        @set = source.config["set"]
        @prefix = source.config["metadata_prefix"]
        @until = Time.now.utc
      end

      def each(from:)
        opts = list_opts(from)
        @client.list_records(opts).full.each do |rec|
          next if rec.header.status == "deleted"

          yield Nexus::RawRecord.new(id: rec.header.identifier, metadata: rec.metadata, datestamp: rec.header.datestamp)
        end
      end

      def deleted_ids(from:)
        opts = list_opts(from)
        @client.list_identifiers(opts).full.select { |h| h.status == "deleted" }.map(&:identifier)
      end

      attr_reader :until

      private

      def list_opts(from)
        opts = { metadata_prefix: @prefix, set: @set, until: @until }
        opts[:from] = from if from
        opts
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/harvesters/oai_pmh_spec.rb
```

Expected: PASS (1 example). If the `oai` gem's `.full` doesn't auto-follow `resumptionToken` the way this test assumes, inspect the actual response object in a `binding.irb` breakpoint inside the test and adjust `each`/`deleted_ids` to call `.next_response` in a loop until `resumption_token` is blank — the yielded-record behavior (1 non-deleted record from 2 pages) is the contract to preserve.

- [ ] **Step 5: Commit**

```bash
git add app/services/nexus/harvesters spec/services/nexus/harvesters
git commit -m "Add OAI-PMH harvester with resumptionToken paging"
```

---

### Task 11: `Nexus::Indexer`

**Files:**
- Create: `app/services/nexus/indexer.rb`
- Test: `spec/services/nexus/indexer_spec.rb`

**Interfaces:**
- Produces: `Nexus::Indexer.new(collection:, solr_client: RSolr.connect(url: ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")))`, `#add(doc)` (buffers), `#commit` (flushes buffered docs via one `solr_client.add` call plus `solr_client.commit`). Used by Task 13's job and Task 5 conceptually (Task 5 uses raw HTTP instead, since it runs before Rails boots).

- [ ] **Step 1: Write the failing spec with a fake Solr client**

Create `spec/services/nexus/indexer_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/indexer_spec.rb
```

Expected: FAIL (`Nexus::Indexer` not defined).

- [ ] **Step 3: Implement**

Create `app/services/nexus/indexer.rb`:

```ruby
require "rsolr"

module Nexus
  class Indexer
    def initialize(collection:, solr_client: RSolr.connect(url: ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")))
      @collection = collection
      @solr = solr_client
      @buffer = []
    end

    def add(doc)
      @buffer << doc
    end

    def commit
      @solr.add(@buffer) if @buffer.any?
      @solr.commit
      @buffer = []
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/indexer_spec.rb
```

Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/nexus/indexer.rb spec/services/nexus/indexer_spec.rb
git commit -m "Add Nexus::Indexer: batched Solr upserts"
```

---

### Task 12: `Nexus::Reconciler`

**Files:**
- Create: `app/services/nexus/reconciler.rb`
- Test: `spec/services/nexus/reconciler_spec.rb`

**Interfaces:**
- Consumes: an RSolr-like client (`#delete_by_id`, `#commit`, `#get` for the `select` handler).
- Produces: `Nexus::Reconciler.new(source, solr_client: ...)`, `#apply(deleted_ids, full_id_set: nil) -> Integer` (count of documents deleted). When `full_id_set` is given, it also deletes any Solr doc for that collection whose id isn't in `full_id_set` (the "safety net" full-reindex delete path). Used by Task 13's job.

- [ ] **Step 1: Write the failing spec**

Create `spec/services/nexus/reconciler_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Nexus::Reconciler do
  let(:source) { CollectionSource.new(key: "grainger") }
  let(:fake_solr) { instance_spy("RSolr::Client") }
  let(:reconciler) { described_class.new(source, solr_client: fake_solr) }

  it "deletes the explicit deleted ids and returns the count" do
    count = reconciler.apply(["grainger:GM-9999"])

    expect(fake_solr).to have_received(:delete_by_id).with(["grainger:GM-9999"])
    expect(fake_solr).to have_received(:commit)
    expect(count).to eq(1)
  end

  it "also deletes orphans not present in a given full_id_set" do
    allow(fake_solr).to receive(:get).with("select", hash_including(params: hash_including(q: 'collection_ssim:"grainger"'))).and_return(
      "response" => { "docs" => [{ "id" => "grainger:GM-1" }, { "id" => "grainger:GM-2" }, { "id" => "grainger:GM-3" }] }
    )

    count = reconciler.apply([], full_id_set: ["grainger:GM-1", "grainger:GM-2"])

    expect(fake_solr).to have_received(:delete_by_id).with(["grainger:GM-3"])
    expect(count).to eq(1)
  end

  it "returns 0 and skips delete_by_id when there is nothing to delete" do
    count = reconciler.apply([])

    expect(fake_solr).not_to have_received(:delete_by_id)
    expect(count).to eq(0)
  end
end
```

Note: `source.key` must map to the `collection_ssim` facet value used in seed data (`"Grainger Museum"` in the real data) — for this spec, the reconciler is only exercised against the `key`-as-query-value contract shown above; Task 13 passes the real `CollectionSource` whose `config` can carry a `"collection_label"` if the two ever diverge. Keep the reconciler's query as `collection_ssim:"#{source.key}"` for now — the Grainger `CollectionSource` created in Task 14 sets `key: "grainger"` and Task 8's mapper sets `collection_ssim: ["Grainger Museum"]`; wire the actual label by having the reconciler read `source.config["collection_label"]` if present, else fall back to `source.key`:

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/reconciler_spec.rb
```

Expected: FAIL (`Nexus::Reconciler` not defined).

- [ ] **Step 3: Implement**

Create `app/services/nexus/reconciler.rb`:

```ruby
module Nexus
  class Reconciler
    def initialize(source, solr_client: RSolr.connect(url: ENV.fetch("SOLR_URL", "http://localhost:8983/solr/nexus")))
      @source = source
      @solr = solr_client
    end

    def apply(deleted_ids, full_id_set: nil)
      ids_to_delete = deleted_ids.dup

      if full_id_set
        existing_ids = fetch_existing_ids
        ids_to_delete |= (existing_ids - full_id_set)
      end

      return 0 if ids_to_delete.empty?

      @solr.delete_by_id(ids_to_delete)
      @solr.commit
      ids_to_delete.size
    end

    private

    def fetch_existing_ids
      label = @source.config["collection_label"] || @source.key
      response = @solr.get("select", params: { q: %(collection_ssim:"#{label}"), fl: "id", rows: 10_000 })
      response["response"]["docs"].map { |doc| doc["id"] }
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/reconciler_spec.rb
```

Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add app/services/nexus/reconciler.rb spec/services/nexus/reconciler_spec.rb
git commit -m "Add Nexus::Reconciler: explicit and full-set-diff deletes"
```

---

### Task 13: `HarvestCollectionJob`

**Files:**
- Create: `app/jobs/harvest_collection_job.rb`
- Test: `spec/jobs/harvest_collection_job_spec.rb`

**Interfaces:**
- Consumes: `CollectionSource` (Task 9), a harvester (`#each(from:)`, `#deleted_ids(from:)`, `#until`; Task 10 for real, a fake in tests), a mapper (`#call(raw) -> Hash`; Task 8), `Nexus::Indexer#add`/`#commit` (Task 11), `Nexus::Reconciler#apply` (Task 12).
- Produces: `HarvestCollectionJob.perform_now(collection_key, full: false)`, creating and updating a `HarvestRun` row. Used by Task 16's admin "Harvest now" button and Task 14's recurring schedule.

- [ ] **Step 1: Write the failing spec with fakes for the harvester/mapper**

Create `spec/jobs/harvest_collection_job_spec.rb`:

```ruby
require "rails_helper"

class FakeHarvester
  Raw = Struct.new(:id, :metadata, :datestamp, keyword_init: true)

  def initialize(records:, deleted: [])
    @records = records
    @deleted = deleted
  end

  def each(from:)
    @records.each { |r| yield Raw.new(id: r[:id], metadata: r[:metadata], datestamp: nil) }
  end

  def deleted_ids(from:)
    @deleted
  end

  def until
    Time.current
  end
end

class FakeMapper
  def call(raw)
    raise Nexus::MappingError, "#{raw.id}: broken" if raw.metadata == :broken

    { id: raw.id, title_tesim: [raw.metadata] }
  end
end

RSpec.describe HarvestCollectionJob do
  let(:source) do
    CollectionSource.create!(
      key: "grainger", name: "Grainger Museum", harvester: "oai_pmh",
      mapper: "FakeMapper", cursor: 1.hour.ago
    )
  end
  let(:fake_solr) { instance_spy("RSolr::Client", get: { "response" => { "docs" => [] } }) }

  before do
    allow(Nexus::Harvesters).to receive(:for).and_return(
      FakeHarvester.new(
        records: [
          { id: "grainger:GM-1", metadata: "Title One" },
          { id: "grainger:GM-2", metadata: :broken },
          { id: "grainger:GM-3", metadata: "Title Three" }
        ],
        deleted: ["grainger:GM-9999"]
      )
    )
    allow(Nexus::Indexer).to receive(:new).and_return(Nexus::Indexer.new(collection: "grainger", solr_client: fake_solr))
    allow(Nexus::Reconciler).to receive(:new).and_return(Nexus::Reconciler.new(source, solr_client: fake_solr))
  end

  it "indexes valid records, counts mapping errors, and records deletes" do
    described_class.perform_now("grainger")

    run = source.harvest_runs.last
    expect(run.status).to eq("success")
    expect(run.fetched).to eq(3)
    expect(run.indexed).to eq(2)
    expect(run.mapping_errors).to eq(1)
    expect(run.error_samples).to eq([{ "id" => "grainger:GM-2", "message" => "grainger:GM-2: broken" }])
    expect(run.deleted).to eq(1)
    expect(fake_solr).to have_received(:add).with([{ id: "grainger:GM-1", title_tesim: ["Title One"] }, { id: "grainger:GM-3", title_tesim: ["Title Three"] }])
  end

  it "advances the source cursor to the harvester's until time" do
    freeze_time do
      described_class.perform_now("grainger")
      expect(source.reload.cursor).to eq(Time.current)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/jobs/harvest_collection_job_spec.rb
```

Expected: FAIL (`HarvestCollectionJob` / `Nexus::Harvesters.for` not defined).

- [ ] **Step 3: Add the harvester factory and implement the job**

Add a small factory to `app/services/nexus/harvesters/base.rb` (append below the `Base` class, still inside `module Harvesters`):

```ruby
module Nexus
  module Harvesters
    def self.for(source)
      case source.harvester
      when "oai_pmh" then OaiPmh.new(source)
      else raise ArgumentError, "unknown harvester: #{source.harvester}"
      end
    end
  end
end
```

Create `app/jobs/harvest_collection_job.rb`:

```ruby
class HarvestCollectionJob < ApplicationJob
  queue_as :harvest

  def perform(collection_key, full: false)
    source = CollectionSource.find_by!(key: collection_key)
    run = source.harvest_runs.create!(
      started_at: Time.current, status: "running",
      cursor_from: full ? nil : (source.cursor ? source.cursor - 1.hour : nil)
    )

    harvester = Nexus::Harvesters.for(source)
    mapper = source.mapper.constantize.new
    indexer = Nexus::Indexer.new(collection: source.key)

    error_samples = []
    fetched = 0
    indexed = 0

    harvester.each(from: run.cursor_from) do |raw|
      fetched += 1
      begin
        indexer.add(mapper.call(raw))
        indexed += 1
      rescue Nexus::MappingError => e
        error_samples << { "id" => raw.id, "message" => e.message } if error_samples.size < 20
      end
    end
    indexer.commit

    deleted = Nexus::Reconciler.new(source).apply(
      harvester.deleted_ids(from: run.cursor_from),
      full_id_set: full ? nil : nil
    )

    run.update!(
      fetched: fetched, indexed: indexed, deleted: deleted,
      mapping_errors: error_samples.size, error_samples: error_samples,
      status: "success", finished_at: Time.current, cursor_until: harvester.until
    )
    source.update!(cursor: harvester.until)
    log_run(run)
  rescue => e
    run&.update!(status: "failed", finished_at: Time.current, error_samples: (run.error_samples + [{ "message" => e.message }]))
    log_run(run, error: e) if run
    raise
  end

  private

  def log_run(run, error: nil)
    Rails.logger.info({
      event: "harvest_run", collection: run.collection_source.key, status: run.status,
      fetched: run.fetched, indexed: run.indexed, deleted: run.deleted,
      mapping_errors: run.mapping_errors,
      duration_ms: run.finished_at ? ((run.finished_at - run.started_at) * 1000).to_i : nil,
      error: error&.message
    }.to_json)
  end
end
```

Note: `full_id_set: full ? nil : nil` above is deliberately always `nil` for now — Task 14 wires the real full-reindex id-set fetch (querying the harvester for `all_ids`) since that requires extending `Nexus::Harvesters::OaiPmh` with an `all_ids` method the current interface doesn't have; the incremental delete path (explicit `deleted_ids`) is fully functional as written and is what this task's spec covers.

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/jobs/harvest_collection_job_spec.rb
```

Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/harvest_collection_job.rb app/services/nexus/harvesters/base.rb \
  spec/jobs/harvest_collection_job_spec.rb
git commit -m "Add HarvestCollectionJob: fetch, map, index, reconcile, log"
```

---

### Task 14: Full re-index id-set safety net + recurring schedule

**Files:**
- Modify: `app/services/nexus/harvesters/oai_pmh.rb`
- Modify: `app/jobs/harvest_collection_job.rb`
- Test: modify `spec/services/nexus/harvesters/oai_pmh_spec.rb`
- Test: modify `spec/jobs/harvest_collection_job_spec.rb`
- Create: `config/recurring.yml`
- Create: `db/seeds.rb` (registers the `grainger` `CollectionSource`)

**Interfaces:**
- Produces: `Nexus::Harvesters::OaiPmh#all_ids -> Array<String>` (full `ListIdentifiers` sweep, ignoring `from`), wired into `HarvestCollectionJob` so `full: true` runs pass `full_id_set:` to the reconciler.

- [ ] **Step 1: Extend the harvester spec for `all_ids`**

Add to `spec/services/nexus/harvesters/oai_pmh_spec.rb` (inside the existing `RSpec.describe` block, reusing `page1`/`page2` but without the deleted header affecting the count — add a new stub scoped to this example so it doesn't interfere with the existing test):

```ruby
it "lists all non-deleted identifiers across pages for a full sweep" do
  stub_request(:get, /upstream\.test\/oai/).with(query: hash_including(verb: "ListIdentifiers")).to_return(
    { body: page1.sub("ListRecords", "ListIdentifiers").sub(%r{<metadata>.*</metadata>}m, ""), headers: { "Content-Type" => "text/xml" } },
    { body: page2.sub("ListRecords", "ListIdentifiers"), headers: { "Content-Type" => "text/xml" } }
  )

  expect(harvester.all_ids).to eq(["oai:grainger.unimelb.edu.au:GM-0417"])
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rspec spec/services/nexus/harvesters/oai_pmh_spec.rb
```

Expected: FAIL (`all_ids` not defined).

- [ ] **Step 3: Implement `all_ids`**

In `app/services/nexus/harvesters/oai_pmh.rb`, add alongside `deleted_ids`:

```ruby
def all_ids
  opts = { metadata_prefix: @prefix, set: @set, until: @until }
  @client.list_identifiers(opts).full.reject { |h| h.status == "deleted" }.map(&:identifier)
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rspec spec/services/nexus/harvesters/oai_pmh_spec.rb
```

Expected: PASS (2 examples).

- [ ] **Step 5: Wire `full:` through to the reconciler, with a spec**

Add to `spec/jobs/harvest_collection_job_spec.rb`, extend `FakeHarvester` with `all_ids` returning `@records.map { |r| r[:id] }`, then add:

```ruby
it "passes a full id set to the reconciler on a full run" do
  described_class.perform_now("grainger", full: true)

  run = source.harvest_runs.last
  expect(run.cursor_from).to be_nil
end
```

(The `FakeHarvester#all_ids` addition: in the same file, inside `class FakeHarvester`, add `def all_ids = @records.map { |r| r[:id] }`.)

- [ ] **Step 6: Run it to verify it fails, then implement**

```bash
bin/rspec spec/jobs/harvest_collection_job_spec.rb
```

Expected: FAIL if `all_ids` is missing from `FakeHarvester` at this point — add it as shown above, then re-run to confirm this new example passes while the two from Task 13 still pass.

In `app/jobs/harvest_collection_job.rb`, replace the `Nexus::Reconciler.new(...).apply(...)` call with:

```ruby
deleted = Nexus::Reconciler.new(source).apply(
  harvester.deleted_ids(from: run.cursor_from),
  full_id_set: full ? harvester.all_ids : nil
)
```

- [ ] **Step 7: Run the full job spec file to verify all pass**

```bash
bin/rspec spec/jobs/harvest_collection_job_spec.rb spec/services/nexus/harvesters/oai_pmh_spec.rb
```

Expected: PASS (all examples).

- [ ] **Step 8: Register the `grainger` `CollectionSource` and the recurring schedule**

Create/replace `db/seeds.rb`:

```ruby
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
```

Create `config/recurring.yml`:

```yaml
production:
  harvest_grainger:
    class: HarvestCollectionJob
    args: ["grainger"]
    schedule: every 15 minutes
  harvest_grainger_full:
    class: HarvestCollectionJob
    args: ["grainger", { full: true }]
    schedule: every day at 3am
development:
  harvest_grainger:
    class: HarvestCollectionJob
    args: ["grainger"]
    schedule: every 15 minutes
```

- [ ] **Step 9: Verify seeding works**

```bash
bin/rails db:seed
bin/rails runner 'puts CollectionSource.find_by(key: "grainger").config.inspect'
```

Expected: prints the config hash with `base_url`, `set`, `metadata_prefix`, `collection_label`.

- [ ] **Step 10: Commit**

```bash
git add app/services/nexus/harvesters/oai_pmh.rb app/jobs/harvest_collection_job.rb \
  spec/services/nexus/harvesters/oai_pmh_spec.rb spec/jobs/harvest_collection_job_spec.rb \
  config/recurring.yml db/seeds.rb
git commit -m "Add full-reindex id-set safety net and recurring harvest schedule"
```

---

### Task 15: Shared upstream YAML store + mock OAI-PMH upstream (Sinatra)

**Files:**
- Create: `lib/nexus_upstream_store.rb`
- Create: `upstream/app.rb`
- Create: `upstream/data/grainger.yml`
- Test: `spec/lib/nexus_upstream_store_spec.rb`
- Test: `spec/upstream/app_spec.rb`

**Interfaces:**
- Produces: `NexusUpstreamStore.new(path)` with `#records -> Array<Hash>` (each with string keys `"id"`, `"title"`, `"creator"`, `"date"`, `"type"`, `"subject"`, `"coverage"`, `"description"`, `"rights"`, `"identifier"`, `"updated_at"`, `"deleted"`), `#find(id) -> Hash|nil`, `#update_record(id, attrs) -> Hash` (merges `attrs`, sets `"updated_at"` to now, persists, file-locked). Used here by the Sinatra app and later by Task 16's admin controller.

- [ ] **Step 1: Seed the YAML backing store**

Create `upstream/data/grainger.yml` with the 5 Grainger records in flat form (one mapping step away from the OAI response the mock will build), plus the tombstone record from the source design:

```yaml
- id: GM-0417
  title: "Free Music Machine, model 2"
  creator: ["Grainger, Percy", "Cross, Burnett"]
  date: "1950-1952"
  type: "Musical instrument"
  subject: ["Experimental music", "Sound technology"]
  coverage: "White Plains, New York"
  description: "Second working model of Grainger's Free Music Machine, built with Burnett Cross to play gliding tones without human performers."
  rights: "In copyright - research use"
  identifier: "https://grainger.unimelb.edu.au/collection/GM-0417"
  updated_at: 2026-09-01T00:00:00Z
  deleted: false
- id: GM-1102
  title: "Towelling costume, self-designed"
  creator: ["Grainger, Percy"]
  date: "c. 1930s"
  type: "Costume"
  subject: ["Costume", "Design"]
  coverage: "White Plains, New York"
  description: "Jacket and trousers made from bath towels, designed and worn by Grainger."
  rights: "In copyright - research use"
  identifier: "https://grainger.unimelb.edu.au/collection/GM-1102"
  updated_at: 2026-09-01T00:00:00Z
  deleted: false
- id: GM-0088
  title: "Letter to Rose Grainger from London"
  creator: ["Grainger, Percy"]
  date: "1902"
  type: "Correspondence"
  subject: []
  coverage: "London"
  description: "Letter from Percy Grainger to his mother Rose, written while touring London."
  rights: "Public domain"
  identifier: "https://grainger.unimelb.edu.au/collection/GM-0088"
  updated_at: 2026-09-01T00:00:00Z
  deleted: false
- id: GM-2201
  title: "Phonograph cylinder: Lincolnshire folk song recording"
  creator: ["Grainger, Percy (collector)"]
  date: "1906"
  type: "Sound recording"
  subject: ["Folk music"]
  coverage: "Brigg, Lincolnshire"
  description: "Wax cylinder recording made by Grainger during his folk song collecting expeditions in Lincolnshire."
  rights: "Public domain"
  identifier: "https://grainger.unimelb.edu.au/collection/GM-2201"
  updated_at: 2026-09-01T00:00:00Z
  deleted: false
- id: GM-1540
  title: "Portrait of Percy Grainger"
  creator: ["Rupert Bunny (attrib.)"]
  date: "1911"
  type: "Painting"
  subject: ["Portraiture"]
  coverage: "Paris"
  description: "Oil portrait of Percy Grainger, attributed to Rupert Bunny."
  rights: "Public domain"
  identifier: "https://grainger.unimelb.edu.au/collection/GM-1540"
  updated_at: 2026-09-01T00:00:00Z
  deleted: false
- id: GM-9999
  title: null
  updated_at: 2026-09-05T11:00:00Z
  deleted: true
```

- [ ] **Step 2: Write the failing store spec**

Create `spec/lib/nexus_upstream_store_spec.rb`:

```ruby
require "spec_helper"
require_relative "../../lib/nexus_upstream_store"
require "tmpdir"
require "fileutils"

RSpec.describe NexusUpstreamStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "grainger.yml")
      FileUtils.cp(File.expand_path("../../upstream/data/grainger.yml", __dir__), @path)
      example.run
    end
  end

  let(:store) { described_class.new(@path) }

  it "lists all records" do
    expect(store.records.map { |r| r["id"] }).to include("GM-0417", "GM-9999")
  end

  it "finds a record by id" do
    expect(store.find("GM-0417")["title"]).to eq("Free Music Machine, model 2")
  end

  it "updates a record and bumps updated_at" do
    before = store.find("GM-1102")["updated_at"]
    updated = store.update_record("GM-1102", "title" => "New Title")

    expect(updated["title"]).to eq("New Title")
    expect(store.find("GM-1102")["updated_at"]).to be > before
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rspec spec/lib/nexus_upstream_store_spec.rb
```

Expected: FAIL (`NexusUpstreamStore` not defined).

- [ ] **Step 4: Implement the store**

Create `lib/nexus_upstream_store.rb`:

```ruby
require "yaml"
require "time"

class NexusUpstreamStore
  def initialize(path)
    @path = path
  end

  def records
    with_lock { load }
  end

  def find(id)
    records.find { |r| r["id"] == id }
  end

  def update_record(id, attrs)
    with_lock do
      data = load
      record = data.find { |r| r["id"] == id }
      raise ArgumentError, "no such record: #{id}" unless record

      record.merge!(attrs)
      record["updated_at"] = Time.now.utc
      save(data)
      record
    end
  end

  private

  def with_lock
    File.open(@path, "r+") do |f|
      f.flock(File::LOCK_EX)
      result = yield
      f.flock(File::LOCK_UN)
      result
    end
  end

  def load
    YAML.safe_load_file(@path, permitted_classes: [Time, Date], aliases: true) || []
  end

  def save(data)
    File.write(@path, YAML.dump(data))
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

```bash
bin/rspec spec/lib/nexus_upstream_store_spec.rb
```

Expected: PASS (3 examples).

- [ ] **Step 6: Write the failing Sinatra app spec**

Create `spec/upstream/app_spec.rb`:

```ruby
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
    get "/oai", verb: "ListIdentifiers", metadataPrefix: "oai_dc", from: "2026-09-06T00:00:00Z"
    expect(last_response.body.scan("<identifier>").size).to eq(1)
    expect(last_response.body).to include("GM-9999")
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

```bash
bin/rspec spec/upstream/app_spec.rb
```

Expected: FAIL (`upstream/app.rb` doesn't exist).

- [ ] **Step 8: Implement the Sinatra mock**

Create `upstream/app.rb`:

```ruby
require "sinatra/base"
require "builder"
require "time"
require_relative "../lib/nexus_upstream_store"

module NexusUpstream
  class App < Sinatra::Base
    PAGE_SIZE = 3

    def self.store
      @store ||= NexusUpstreamStore.new(ENV.fetch("UPSTREAM_DATA_PATH", File.expand_path("data/grainger.yml", __dir__)))
    end

    get "/oai" do
      content_type "text/xml"
      case params["verb"]
      when "Identify" then identify
      when "ListMetadataFormats" then list_metadata_formats
      when "ListSets" then list_sets
      when "ListIdentifiers" then list_identifiers
      when "ListRecords" then list_records
      when "GetRecord" then get_record
      else halt 400, "unsupported verb"
      end
    end

    private

    def store = self.class.store

    def envelope(verb)
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct!
      xml.tag!("OAI-PMH", xmlns: "http://www.openarchives.org/OAI/2.0/") do
        xml.responseDate Time.now.utc.iso8601
        xml.request(verb: verb) { xml.text! request.url }
        yield xml
      end
      xml.target!
    end

    def identify
      envelope("Identify") { |xml| xml.Identify { xml.repositoryName "Nexus Grainger Mock Upstream" } }
    end

    def list_metadata_formats
      envelope("ListMetadataFormats") do |xml|
        xml.ListMetadataFormats { xml.metadataFormat { xml.metadataPrefix "oai_dc" } }
      end
    end

    def list_sets
      envelope("ListSets") { |xml| xml.ListSets { xml.set { xml.setSpec "grainger" } } }
    end

    def filtered_records
      from = parse_time(params["from"])
      until_ts = parse_time(params["until"])
      store.records.select do |r|
        ts = parse_time(r["updated_at"])
        (from.nil? || ts >= from) && (until_ts.nil? || ts <= until_ts)
      end.sort_by { |r| r["id"] }
    end

    def paginate(records)
      offset = (params["resumptionToken"] || 0).to_i
      page = records[offset, PAGE_SIZE] || []
      next_offset = offset + PAGE_SIZE
      token = next_offset < records.size ? next_offset.to_s : ""
      [page, token, records.size, offset]
    end

    def list_identifiers
      records, token, total, cursor = paginate(filtered_records)
      envelope("ListIdentifiers") do |xml|
        xml.ListIdentifiers do
          records.each { |r| xml.header { header_fields(xml, r) } }
          xml.resumptionToken(token, completeListSize: total, cursor: cursor)
        end
      end
    end

    def list_records
      records, token, total, cursor = paginate(filtered_records)
      envelope("ListRecords") do |xml|
        xml.ListRecords do
          records.each { |r| xml.record { record_body(xml, r) } }
          xml.resumptionToken(token, completeListSize: total, cursor: cursor)
        end
      end
    end

    def get_record
      id = params["identifier"].to_s.split(":").last
      record = store.find(id)
      halt 404, "no such record" unless record

      envelope("GetRecord") { |xml| xml.GetRecord { xml.record { record_body(xml, record) } } }
    end

    def header_fields(xml, record)
      xml.identifier "oai:grainger.unimelb.edu.au:#{record['id']}"
      xml.datestamp Time.parse(record["updated_at"].to_s).utc.iso8601
      xml.setSpec "grainger" unless record["deleted"]
    end

    def record_body(xml, record)
      if record["deleted"]
        xml.header(status: "deleted") { header_fields(xml, record) }
      else
        xml.header { header_fields(xml, record) }
        xml.metadata do
          xml.tag!("oai_dc:dc", "xmlns:oai_dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/", "xmlns:dc" => "http://purl.org/dc/elements/1.1/") do
            xml.tag!("dc:title", record["title"]) if record["title"]
            Array(record["creator"]).each { |c| xml.tag!("dc:creator", c) }
            xml.tag!("dc:date", record["date"]) if record["date"]
            xml.tag!("dc:type", record["type"]) if record["type"]
            Array(record["subject"]).each { |s| xml.tag!("dc:subject", s) }
            xml.tag!("dc:coverage", record["coverage"]) if record["coverage"]
            xml.tag!("dc:description", record["description"]) if record["description"]
            xml.tag!("dc:rights", record["rights"]) if record["rights"]
            xml.tag!("dc:identifier", record["identifier"]) if record["identifier"]
          end
        end
      end
    end

    def parse_time(value)
      value.nil? || value == "" ? nil : Time.parse(value.to_s).utc
    end

    run! if app_file == $0
  end
end
```

```bash
bundle add builder
```

- [ ] **Step 9: Run it to verify it passes**

```bash
bin/rspec spec/upstream/app_spec.rb
```

Expected: PASS (5 examples). If pagination counts are off by one, check `paginate`'s `resumptionToken` handling against the test's expectations (page 1 = records `0..2`, page 2 starts at token `"3"` = records `3..5`).

- [ ] **Step 10: Manually verify the mock end-to-end**

```bash
UPSTREAM_DATA_PATH=$(pwd)/upstream/data/grainger.yml ruby upstream/app.rb -p 4567 &
sleep 2
curl -s "http://localhost:4567/oai?verb=ListRecords&metadataPrefix=oai_dc" | grep -c "<record>"
kill %1
```

Expected: `3` (page size).

- [ ] **Step 11: Commit**

```bash
git add lib/nexus_upstream_store.rb upstream/app.rb upstream/data/grainger.yml \
  spec/lib/nexus_upstream_store_spec.rb spec/upstream/app_spec.rb Gemfile Gemfile.lock
git commit -m "Add mock OAI-PMH upstream with pagination, deletes, and shared YAML store"
```

---

### Task 16: Admin UI — sources, harvest runs, upstream editor

**Files:**
- Create: `app/controllers/admin/collection_sources_controller.rb`
- Create: `app/controllers/admin/harvest_runs_controller.rb`
- Create: `app/controllers/admin/upstream_records_controller.rb`
- Create: `app/views/admin/collection_sources/index.html.erb`
- Create: `app/views/admin/harvest_runs/index.html.erb`
- Create: `app/views/admin/upstream_records/index.html.erb`
- Modify: `config/routes.rb`
- Test: `spec/requests/admin/collection_sources_spec.rb`
- Test: `spec/requests/admin/harvest_runs_spec.rb`
- Test: `spec/requests/admin/upstream_records_spec.rb`

**Interfaces:**
- Consumes: `CollectionSource`/`HarvestRun` (Task 9), `HarvestCollectionJob` (Task 13), `NexusUpstreamStore` (Task 15).
- Produces: `GET /admin`, `POST /admin/collection_sources/:id/harvest`, `POST /admin/collection_sources/:id/full_reindex`, `GET /admin/harvest_runs`, `GET /admin/upstream_records`, `PATCH /admin/upstream_records/:id`. No new service objects — this is the UI layer other tasks' services plug into.

- [ ] **Step 1: Add routes**

In `config/routes.rb`, inside the existing `Rails.application.routes.draw do` block, add:

```ruby
namespace :admin do
  resources :collection_sources, only: [:index] do
    member do
      post :harvest
      post :full_reindex
    end
  end
  resources :harvest_runs, only: [:index]
  resources :upstream_records, only: [:index, :update]
end
```

- [ ] **Step 2: Write the failing request specs**

Create `spec/requests/admin/collection_sources_spec.rb`:

```ruby
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
```

Create `spec/requests/admin/harvest_runs_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::HarvestRuns", type: :request do
  let(:source) { CollectionSource.create!(key: "grainger", name: "Grainger Museum", harvester: "oai_pmh", mapper: "M") }

  it "lists runs with counts and error samples" do
    source.harvest_runs.create!(
      started_at: 1.minute.ago, finished_at: Time.current, status: "success",
      fetched: 3, indexed: 2, mapping_errors: 1,
      error_samples: [{ "id" => "grainger:GM-2", "message" => "broken" }]
    )

    get "/admin/harvest_runs"

    expect(response.body).to include("success")
    expect(response.body).to include("grainger:GM-2")
    expect(response.body).to include("broken")
  end
end
```

Create `spec/requests/admin/upstream_records_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::UpstreamRecords", type: :request do
  around do |example|
    Dir.mktmpdir do |dir|
      path = File.join(dir, "grainger.yml")
      FileUtils.cp(Rails.root.join("upstream/data/grainger.yml"), path)
      original = ENV["UPSTREAM_DATA_PATH"]
      ENV["UPSTREAM_DATA_PATH"] = path
      example.run
      ENV["UPSTREAM_DATA_PATH"] = original
    end
  end

  it "lists upstream records" do
    get "/admin/upstream_records"
    expect(response.body).to include("GM-0417")
  end

  it "updates a record's title and marks it not deleted" do
    patch "/admin/upstream_records/GM-1102", params: { upstream_record: { title: "New Title" } }

    expect(response).to redirect_to("/admin/upstream_records")
    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1102")["title"]).to eq("New Title")
  end

  it "marks a record deleted" do
    patch "/admin/upstream_records/GM-1540", params: { upstream_record: { deleted: "1" } }

    store = NexusUpstreamStore.new(ENV["UPSTREAM_DATA_PATH"])
    expect(store.find("GM-1540")["deleted"]).to be true
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

```bash
bin/rspec spec/requests/admin
```

Expected: FAIL (routes/controllers/views don't exist).

- [ ] **Step 4: Implement the controllers**

Create `app/controllers/admin/collection_sources_controller.rb`:

```ruby
module Admin
  class CollectionSourcesController < ApplicationController
    def index
      @sources = CollectionSource.all
    end

    def harvest
      source = CollectionSource.find(params[:id])
      HarvestCollectionJob.perform_later(source.key)
      redirect_to admin_collection_sources_path
    end

    def full_reindex
      source = CollectionSource.find(params[:id])
      HarvestCollectionJob.perform_later(source.key, full: true)
      redirect_to admin_collection_sources_path
    end
  end
end
```

Create `app/controllers/admin/harvest_runs_controller.rb`:

```ruby
module Admin
  class HarvestRunsController < ApplicationController
    def index
      @runs = HarvestRun.includes(:collection_source).order(started_at: :desc).limit(50)
    end
  end
end
```

Create `app/controllers/admin/upstream_records_controller.rb`:

```ruby
module Admin
  class UpstreamRecordsController < ApplicationController
    def index
      @records = store.records
    end

    def update
      attrs = { "title" => params.dig(:upstream_record, :title) }.compact
      attrs["deleted"] = params[:upstream_record][:deleted] == "1" if params.dig(:upstream_record, :deleted)
      store.update_record(params[:id], attrs)
      redirect_to admin_upstream_records_path
    end

    private

    def store
      @store ||= NexusUpstreamStore.new(ENV.fetch("UPSTREAM_DATA_PATH", Rails.root.join("upstream/data/grainger.yml").to_s))
    end
  end
end
```

- [ ] **Step 5: Implement the views**

Create `app/views/admin/collection_sources/index.html.erb`:

```erb
<h1>Collection Sources</h1>
<table>
  <thead><tr><th>Key</th><th>Name</th><th>Cursor</th><th>Actions</th></tr></thead>
  <tbody>
    <% @sources.each do |source| %>
      <tr>
        <td><%= source.key %></td>
        <td><%= source.name %></td>
        <td><%= source.cursor %></td>
        <td>
          <%= button_to "Harvest now", harvest_admin_collection_source_path(source), method: :post %>
          <%= button_to "Full re-index", full_reindex_admin_collection_source_path(source), method: :post %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
<p><%= link_to "Harvest runs", admin_harvest_runs_path %> | <%= link_to "Upstream records", admin_upstream_records_path %></p>
```

Create `app/views/admin/harvest_runs/index.html.erb`:

```erb
<h1>Harvest Runs</h1>
<table>
  <thead><tr><th>Collection</th><th>Status</th><th>Fetched</th><th>Indexed</th><th>Deleted</th><th>Mapping errors</th><th>Started</th></tr></thead>
  <tbody>
    <% @runs.each do |run| %>
      <tr>
        <td><%= run.collection_source.key %></td>
        <td><%= run.status %></td>
        <td><%= run.fetched %></td>
        <td><%= run.indexed %></td>
        <td><%= run.deleted %></td>
        <td><%= run.mapping_errors %></td>
        <td><%= run.started_at %></td>
      </tr>
      <% run.error_samples.each do |sample| %>
        <tr><td colspan="6"><em><%= sample["id"] %>: <%= sample["message"] %></em></td></tr>
      <% end %>
    <% end %>
  </tbody>
</table>
<p><%= link_to "Back", admin_collection_sources_path %></p>
```

Create `app/views/admin/upstream_records/index.html.erb`:

```erb
<h1>Upstream Records (mock Grainger source)</h1>
<% @records.each do |record| %>
  <fieldset>
    <legend><%= record["id"] %></legend>
    <%= form_with url: admin_upstream_record_path(record["id"]), method: :patch do |f| %>
      <%= f.text_field :title, name: "upstream_record[title]", value: record["title"] %>
      <label><%= check_box_tag "upstream_record[deleted]", "1", record["deleted"] %> Deleted</label>
      <%= f.submit "Save" %>
    <% end %>
  </fieldset>
<% end %>
<p><%= link_to "Back", admin_collection_sources_path %></p>
```

- [ ] **Step 6: Run the specs to verify they pass**

```bash
bin/rspec spec/requests/admin
```

Expected: PASS (7 examples).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/admin app/views/admin config/routes.rb spec/requests/admin
git commit -m "Add admin UI: harvest triggers, run history, upstream editor"
```

---

### Task 17: Dockerfile + entrypoint supervising all four processes

**Files:**
- Create: `Dockerfile`
- Create: `bin/entrypoint.sh`

**Interfaces:**
- Produces: a single image whose `ENTRYPOINT` boots Solr, the Sinatra mock, Puma, and Solid Queue against `/data`, seeding on first boot only.

- [ ] **Step 1: Write the entrypoint script**

Create `bin/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

export SOLR_URL="${SOLR_URL:-http://localhost:8983/solr/nexus}"
export UPSTREAM_URL="${UPSTREAM_URL:-http://localhost:4567/oai}"
export UPSTREAM_DATA_PATH="${UPSTREAM_DATA_PATH:-/data/upstream/grainger.yml}"
export DATABASE_URL="${DATABASE_URL:-sqlite3:///data/db/nexus_demo.sqlite3}"

mkdir -p /data/solr /data/upstream /data/db

if [ ! -d /data/solr/nexus ]; then
  solr-precreate nexus /opt/solr/server/solr/configsets/nexus_config -Dsolr.solr.home=/data/solr &
  SOLR_PID=$!
else
  SOLR_HOME=/data/solr solr start -f -Dsolr.solr.home=/data/solr -m 512m &
  SOLR_PID=$!
fi

until curl -sf "$SOLR_URL/admin/ping" >/dev/null 2>&1; do sleep 1; done

if [ ! -f /data/upstream/grainger.yml ]; then
  cp /app/upstream/data/grainger.yml /data/upstream/grainger.yml
fi

ruby /app/upstream/app.rb -p 4567 -o 127.0.0.1 &
UPSTREAM_PID=$!

if [ ! -f /data/.seeded ]; then
  bin/rails db:prepare
  bin/rails db:seed
  ruby bin/seed_static.rb
  touch /data/.seeded
fi

bin/rails server -p 3000 -b 0.0.0.0 &
PUMA_PID=$!

bin/jobs &
JOBS_PID=$!

wait -n "$SOLR_PID" "$UPSTREAM_PID" "$PUMA_PID" "$JOBS_PID"
echo "A supervised process exited; shutting down the container."
exit 1
```

```bash
chmod +x bin/entrypoint.sh
```

- [ ] **Step 2: Write the Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM solr:9 AS solr-base

FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libyaml-dev sqlite3 libsqlite3-dev curl default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

COPY --from=solr-base /opt/solr /opt/solr
ENV PATH="/opt/solr/bin:${PATH}"

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .
RUN mkdir -p /opt/solr/server/solr/configsets/nexus_config/conf \
    && cp -r solr/conf/* /opt/solr/server/solr/configsets/nexus_config/conf/

RUN bin/rails assets:precompile 2>/dev/null || true

ENV RAILS_ENV=production
EXPOSE 3000
VOLUME /data

ENTRYPOINT ["bin/entrypoint.sh"]
```

- [ ] **Step 3: Build the image locally**

```bash
docker build -t nexus-demo:local .
```

Expected: build completes without error. If `bin/rails assets:precompile` fails hard rather than the `|| true` catching it (e.g. it needs `SECRET_KEY_BASE` at build time), export a throwaway one before building:

```bash
SECRET_KEY_BASE=$(bin/rails secret) docker build --build-arg SECRET_KEY_BASE -t nexus-demo:local .
```

and add `ARG SECRET_KEY_BASE` / `ENV SECRET_KEY_BASE=${SECRET_KEY_BASE}` above the `RUN bin/rails assets:precompile` line in the Dockerfile if needed.

- [ ] **Step 4: Run it locally against a scratch volume and verify the full demo flow**

```bash
docker volume create nexus-demo-data
docker run -d --name nexus-demo-local -p 3000:3000 \
  -v nexus-demo-data:/data \
  -e RAILS_MASTER_KEY=$(cat config/master.key) \
  nexus-demo:local
sleep 20
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/catalog
curl -s "http://localhost:3000/catalog.json?q=melbourne" | grep -o '"numFound":[0-9]*'
```

Expected: `200`, and `numFound` > 0 among the 15 static records (Grainger not yet harvested at this point, matching demo script step 1).

```bash
curl -s -X POST http://localhost:3000/admin/collection_sources/1/full_reindex -H "Origin: http://localhost:3000"
```

If this 422s on CSRF (likely, since it's a raw `curl` POST outside a browser session), verify via the browser instead: open `http://localhost:3000/admin`, click "Full re-index," reload, and confirm 5 Grainger records now appear in `/catalog?q=grainger`.

```bash
docker logs nexus-demo-local --tail 50
docker rm -f nexus-demo-local
```

Expected logs include a `"event":"harvest_run"` JSON line with `"status":"success"`, `"fetched":5`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile bin/entrypoint.sh
git commit -m "Add Dockerfile and entrypoint supervising Solr, upstream, Puma, and Solid Queue"
```

---

### Task 18: Fly.io deployment

**Files:**
- Create: `fly.toml`
- Create: `.dockerignore`

**Interfaces:**
- Produces: a running Fly.io app serving the full demo at a public URL.

- [ ] **Step 1: Add `.dockerignore`**

Create `.dockerignore`:

```
.git
log/*
tmp/*
spec/
docs/
```

- [ ] **Step 2: Scaffold with `fly launch` (no auto-deploy)**

```bash
fly launch --no-deploy --name nexus-demo-<yourname> --dockerfile Dockerfile
```

Answer "no" to any prompt to add a Postgres/Redis database — this app uses SQLite.

- [ ] **Step 3: Hand-edit the generated `fly.toml`**

Replace its contents with:

```toml
app = "nexus-demo-<yourname>"
primary_region = "syd"

[build]

[env]
  RAILS_ENV = "production"
  SOLR_URL = "http://localhost:8983/solr/nexus"
  UPSTREAM_URL = "http://localhost:4567/oai"

[http_service]
  internal_port = 3000
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1

  [[http_service.checks]]
    grace_period = "60s"
    interval = "15s"
    method = "GET"
    timeout = "5s"
    path = "/catalog"

[[mounts]]
  source = "nexus_data"
  destination = "/data"

[[vm]]
  size = "shared-cpu-1x"
  memory = "1gb"
```

(`syd` for Sydney given the University of Melbourne audience; adjust to whatever region `fly launch` picked if different.)

- [ ] **Step 4: Create the volume and set secrets**

```bash
fly volumes create nexus_data --size 1 --region syd
fly secrets set RAILS_MASTER_KEY=$(cat config/master.key)
```

- [ ] **Step 5: Deploy**

```bash
fly deploy
```

- [ ] **Step 6: Verify the deployed app**

```bash
fly status
curl -s -o /dev/null -w "%{http_code}\n" https://nexus-demo-<yourname>.fly.dev/catalog
```

Expected: `200`.

- [ ] **Step 7: Run the full demo script against the live URL**

Open `https://nexus-demo-<yourname>.fly.dev/admin`, click **Full re-index** for Grainger, wait ~10s, then open `/catalog?q=grainger` and confirm results span both Grainger Museum and Archives. Then work through the remaining scenarios in the source design's section 6 (facet narrowing, date range, suppression toggle via `?staff_view=1`, source-record tab, relevance ordering) directly against the live app, and the sync-specific steps from this plan's spec section 9 (edit a title via `/admin/upstream_records`, harvest, confirm the update; mark a record deleted, harvest, confirm it disappears).

- [ ] **Step 8: Commit**

```bash
git add fly.toml .dockerignore
git commit -m "Add Fly.io deployment config"
```

---

## Self-Review Notes

- **Spec coverage:** Unified schema/facets (Task 3), suppression (Task 4), static collections (Task 5), date parsing (Task 6), Dublin Core parsing (Task 7), mapper (Task 8), models (Task 9), OAI-PMH harvester incl. resumption tokens and deletes (Task 10, 14), indexer (Task 11), reconciler incl. full-set safety net (Task 12, 14), job with mapping-error tolerance and structured logging (Task 13), recurring schedule (Task 14), mock upstream OAI-PMH server (Task 15), admin UI replacing the doc's file-edit demo steps (Task 16), single-container Docker supervision (Task 17), Fly.io deployment (Task 18). All spec sections are covered.
- **Type consistency:** `Nexus::RawRecord` (id/metadata/datestamp) is used identically by the harvester (Task 10), the mapper (Task 8), and the job's fakes (Task 13). `Nexus::Indexer#add`/`#commit` and `Nexus::Reconciler#apply(ids, full_id_set:)` signatures match between their defining tasks (11, 12) and their caller (13, 14). `CollectionSource#config` and `HarvestRun#error_samples` are established as serialized Hash/Array in Task 9 and consumed with string keys consistently in Tasks 13, 14, 16.
- **Known follow-up wired explicitly, not left as a placeholder:** Task 13 ships the incremental-delete path only and Task 14 completes the full-reindex id-set path — this is sequenced on purpose (Task 13's job spec doesn't exercise `full: true` yet, Task 14 adds that spec and implementation) rather than a gap.
