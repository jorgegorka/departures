class CreateDomains < ActiveRecord::Migration[8.1]
  def change
    create_table :domains do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :status, default: "pending", null: false
      t.json :dkim_tokens, default: [], null: false
      t.datetime :last_checked_at

      t.timestamps
    end

    add_index :domains, %i[ project_id name ], unique: true
  end
end
