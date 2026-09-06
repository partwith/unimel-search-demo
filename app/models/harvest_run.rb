class HarvestRun < ApplicationRecord
  serialize :error_samples, coder: JSON, type: Array
  belongs_to :collection_source
end
