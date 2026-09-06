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
