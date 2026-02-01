defmodule RougailSolstice.Repo.Migrations.AddRobotPortToOpticalPieces do
  use Ecto.Migration

  def change do
    alter table(:optical_pieces) do
      add :robot_port, :string
    end
  end
end
