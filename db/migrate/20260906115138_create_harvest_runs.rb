class CreateHarvestRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :harvest_runs do |t|
      t.references :collection_source, null: false, foreign_key: true
      t.datetime :started_at
      t.datetime :finished_at
      t.string :status, default: "running", null: false
      t.integer :fetched, default: 0, null: false
      t.integer :indexed, default: 0, null: false
      t.integer :deleted, default: 0, null: false
      t.integer :mapping_errors, default: 0, null: false
      t.text :error_samples, default: "[]"
      t.datetime :cursor_from
      t.datetime :cursor_until

      t.timestamps
    end
  end
end
