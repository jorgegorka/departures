class FixProjectsForeignKey < ActiveRecord::Migration[8.1]
  def change
    # SQLite doesn't support modifying foreign keys, so we need to recreate the table
    drop_table :projects

    execute <<-SQL
      CREATE TABLE projects (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        workspace_id INTEGER NOT NULL,
        name VARCHAR NOT NULL,
        slug VARCHAR NOT NULL,
        default_environment VARCHAR DEFAULT 'production' NOT NULL,
        archived_at DATETIME(6),
        created_at DATETIME(6) NOT NULL,
        updated_at DATETIME(6) NOT NULL,
        CONSTRAINT fk_projects_workspace_id
        FOREIGN KEY (workspace_id)
        REFERENCES workspaces(id)
        ON DELETE CASCADE
      )
    SQL

    add_index :projects, [ :workspace_id, :slug ], unique: true
    add_index :projects, :workspace_id
  end
end
