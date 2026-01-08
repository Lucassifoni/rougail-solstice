defmodule RougailSolstice.Interferometry.Config do
  @moduledoc """
  Ecto schema for interferometry optical configurations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          diameter: float(),
          roc: float(),
          lambda: float(),
          conic: float(),
          obstruction: float(),
          is_default: boolean(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "interferometry_configs" do
    field :name, :string
    field :diameter, :float
    field :roc, :float
    field :lambda, :float, default: 518.0
    field :conic, :float, default: -1.0
    field :obstruction, :float, default: 0.0
    field :is_default, :boolean, default: false

    timestamps()
  end

  @required_fields [:name, :diameter, :roc]
  @optional_fields [:lambda, :conic, :obstruction, :is_default]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:diameter, greater_than: 0)
    |> validate_number(:roc, greater_than: 0)
    |> validate_number(:lambda, greater_than: 0)
    |> validate_number(:obstruction, greater_than_or_equal_to: 0, less_than: 1)
    |> unique_constraint(:name)
  end
end
