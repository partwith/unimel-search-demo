require "nokogiri"

module Nexus
  module DublinCore
    def self.parse(xml)
      doc = xml.is_a?(Nokogiri::XML::Node) ? xml : Nokogiri::XML(xml.to_s)
      result = Hash.new { |h, k| h[k] = [] }

      doc.root.children.each do |node|
        next unless node.element?

        result[node.name] << node.text.strip
      end

      result
    end
  end
end
