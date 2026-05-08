class AddAuthorToRecurringTasks < ActiveRecord::Migration[6.1]
  def change
    add_column :recurring_tasks, :author_id, :integer
    add_index :recurring_tasks, :author_id
    add_foreign_key :recurring_tasks, :users, column: :author_id
  end
end
