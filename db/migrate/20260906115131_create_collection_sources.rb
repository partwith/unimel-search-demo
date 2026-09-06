class CreateCollectionSources < ActiveRecord::Migration[8.0]
  def change
    create_table :collection_sources do |t|
      t.string :key
      t.string :name
      t.string :harvester
      t.text :config, default: "{}"
      t.string :mapper
      t.datetime :cursor
      t.string :schedule

      t.timestamps
    end
    add_index :collection_sources, :key, unique: true
  end
end
