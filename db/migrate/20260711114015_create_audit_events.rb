class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events do |t|
      t.belongs_to :workspace
      t.belongs_to :user
      t.string :action, null: false
      t.references :subject, polymorphic: true
      t.json :metadata, default: {}, null: false
      t.string :ip
      t.datetime :created_at, null: false

      t.index %i[ workspace_id created_at ]
      t.index %i[ workspace_id action ]
    end
  end
end
