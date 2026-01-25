defmodule RougailSolstice.OpticalPieces do
  @moduledoc """
  Context module for optical piece management.
  """

  import Ecto.Query

  alias RougailSolstice.OpticalPieces.OpticalPiece
  alias RougailSolstice.Repo

  @spec list_optical_pieces() :: [OpticalPiece.t()]
  def list_optical_pieces do
    Repo.all(from op in OpticalPiece, order_by: [asc: op.name])
  end

  @spec get_optical_piece(integer()) :: OpticalPiece.t() | nil
  def get_optical_piece(id), do: Repo.get(OpticalPiece, id)

  @spec get_optical_piece!(integer()) :: OpticalPiece.t()
  def get_optical_piece!(id), do: Repo.get!(OpticalPiece, id)

  @spec get_default_optical_piece() :: OpticalPiece.t() | nil
  def get_default_optical_piece do
    OpticalPiece
    |> where(is_default: true)
    |> limit(1)
    |> Repo.one()
  end

  @spec create_optical_piece(map()) :: {:ok, OpticalPiece.t()} | {:error, Ecto.Changeset.t()}
  def create_optical_piece(attrs) do
    %OpticalPiece{}
    |> OpticalPiece.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_optical_piece(OpticalPiece.t(), map()) ::
          {:ok, OpticalPiece.t()} | {:error, Ecto.Changeset.t()}
  def update_optical_piece(%OpticalPiece{} = optical_piece, attrs) do
    optical_piece
    |> OpticalPiece.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_optical_piece(OpticalPiece.t()) ::
          {:ok, OpticalPiece.t()} | {:error, Ecto.Changeset.t()}
  def delete_optical_piece(%OpticalPiece{} = optical_piece) do
    Repo.delete(optical_piece)
  end

  @spec set_default(OpticalPiece.t()) :: {:ok, OpticalPiece.t()} | {:error, term()}
  def set_default(%OpticalPiece{} = optical_piece) do
    Repo.transaction(fn ->
      from(op in OpticalPiece, where: op.is_default == true)
      |> Repo.update_all(set: [is_default: false])

      optical_piece
      |> OpticalPiece.changeset(%{is_default: true})
      |> Repo.update!()
    end)
  end

  @spec change_optical_piece(OpticalPiece.t(), map()) :: Ecto.Changeset.t()
  def change_optical_piece(%OpticalPiece{} = optical_piece, attrs \\ %{}) do
    OpticalPiece.changeset(optical_piece, attrs)
  end

  @spec to_optical_params(OpticalPiece.t()) :: map()
  def to_optical_params(%OpticalPiece{} = op) do
    %{
      diameter: op.diameter,
      roc: op.roc,
      lambda: op.lambda,
      conic: op.conic,
      obstruction: op.obstruction
    }
  end
end
