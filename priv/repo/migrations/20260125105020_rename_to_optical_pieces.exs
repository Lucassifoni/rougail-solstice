defmodule RougailSolstice.Repo.Migrations.RenameToOpticalPieces do
  use Ecto.Migration

  def change do
    rename table(:interferometry_configs), to: table(:optical_pieces)

    alter table(:optical_pieces) do
      add :camera_port, :string
      add :camera_model, :string
      add :notes, :text
    end

    drop unique_index(:optical_pieces, [:name], name: :interferometry_configs_name_index)
    create unique_index(:optical_pieces, [:name])
  end
end
