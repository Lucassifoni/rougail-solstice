defmodule RougailSolstice.Repo.Migrations.CreateInterferometryConfigs do
  use Ecto.Migration

  def change do
    create table(:interferometry_configs) do
      add :name, :string, null: false
      add :diameter, :float, null: false
      add :roc, :float, null: false
      add :lambda, :float, null: false, default: 518.0
      add :conic, :float, null: false, default: -1.0
      add :obstruction, :float, default: 0.0
      add :is_default, :boolean, default: false

      timestamps()
    end

    create unique_index(:interferometry_configs, [:name])
  end
end
