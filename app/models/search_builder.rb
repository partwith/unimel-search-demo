# frozen_string_literal: true
class SearchBuilder < Blacklight::SearchBuilder
  include Blacklight::Solr::SearchBuilderBehavior
  self.default_processor_chain += [:hide_restricted]

  def hide_restricted(solr_params)
    return if blacklight_params[:staff_view] == "1"

    solr_params[:fq] ||= []
    solr_params[:fq] << '-rights_ssim:Restricted*'
  end
end
