# frozen_string_literal: true

class CreateAdminRoots < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_roots, id: :uuid do |t|
      t.string :name, null: false, default: "Admin"
      t.timestamps
    end
  end
end
