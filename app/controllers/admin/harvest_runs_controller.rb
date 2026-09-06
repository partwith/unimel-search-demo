module Admin
  class HarvestRunsController < ApplicationController
    def index
      @runs = HarvestRun.includes(:collection_source).order(started_at: :desc).limit(50)
    end
  end
end
