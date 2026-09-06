module Admin
  class CollectionSourcesController < ApplicationController
    def index
      @sources = CollectionSource.all
    end

    def harvest
      source = CollectionSource.find(params[:id])
      HarvestCollectionJob.perform_later(source.key)
      redirect_to admin_root_path
    end

    def full_reindex
      source = CollectionSource.find(params[:id])
      HarvestCollectionJob.perform_later(source.key, full: true)
      redirect_to admin_root_path
    end
  end
end
