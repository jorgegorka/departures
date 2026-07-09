class CreateTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :templates do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :subject
      t.text :html_body
      t.text :text_body

      t.timestamps
    end

    add_index :templates, %i[ project_id slug ], unique: true
  end
end
