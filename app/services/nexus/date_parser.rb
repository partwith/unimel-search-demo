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
