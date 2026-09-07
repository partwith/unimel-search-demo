# frozen_string_literal: true

# Blacklight controller that handles searches and document requests
class CatalogController < ApplicationController

  include Blacklight::Catalog

  # If you'd like to handle errors returned by Solr in a certain way,
  # you can use Rails rescue_from with a method you define in this controller,
  # uncomment:
  #
  # rescue_from Blacklight::Exceptions::InvalidRequest, with: :my_handling_method

  configure_blacklight do |config|
    config.default_solr_params = { rows: 10 }

    # SearchBuilder#hide_restricted reads staff_view from blacklight_params
    # (see app/models/search_builder.rb), but Blacklight's SearchState
    # strips any request parameter not listed here by default
    # (filter_search_state_fields: true) -- without this, ?staff_view=1
    # is silently dropped before the search builder ever sees it.
    config.search_state_fields += [:staff_view]

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
end
