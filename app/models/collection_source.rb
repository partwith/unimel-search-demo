class CollectionSource < ApplicationRecord
  serialize :config, coder: JSON, type: Hash
  has_many :harvest_runs

  validates :key, presence: true, uniqueness: true
end
