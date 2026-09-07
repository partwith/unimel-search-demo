module Nexus
  module Harvesters
    def self.for(source, mapper)
      case source.harvester
      when "oai_pmh" then OaiPmh.new(source, mapper)
      else raise ArgumentError, "unknown harvester: #{source.harvester}"
      end
    end
  end
end
