defmodule Explorer.Repo.Migrations.ChangeAddressNamesNameToText do
  use Ecto.Migration

  def change do
    alter table(:address_names) do
      modify(:name, :text, null: false)
    end
  end
end
