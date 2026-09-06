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
