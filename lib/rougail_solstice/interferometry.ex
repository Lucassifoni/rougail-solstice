defmodule RougailSolstice.Interferometry do
  @moduledoc """
  Context module for interferometry configuration management.
  """

  import Ecto.Query

  alias RougailSolstice.Interferometry.Config
  alias RougailSolstice.Repo

  @spec list_configs() :: [Config.t()]
  def list_configs do
    Repo.all(from c in Config, order_by: [asc: c.name])
  end

  @spec get_config(integer()) :: Config.t() | nil
  def get_config(id), do: Repo.get(Config, id)

  @spec get_config!(integer()) :: Config.t()
  def get_config!(id), do: Repo.get!(Config, id)

  @spec get_default_config() :: Config.t() | nil
  def get_default_config do
    Config
    |> where(is_default: true)
    |> limit(1)
    |> Repo.one()
  end

  @spec create_config(map()) :: {:ok, Config.t()} | {:error, Ecto.Changeset.t()}
  def create_config(attrs) do
    %Config{}
    |> Config.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_config(Config.t(), map()) :: {:ok, Config.t()} | {:error, Ecto.Changeset.t()}
  def update_config(%Config{} = config, attrs) do
    config
    |> Config.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_config(Config.t()) :: {:ok, Config.t()} | {:error, Ecto.Changeset.t()}
  def delete_config(%Config{} = config) do
    Repo.delete(config)
  end

  @spec set_default(Config.t()) :: {:ok, Config.t()} | {:error, term()}
  def set_default(%Config{} = config) do
    Repo.transaction(fn ->
      from(c in Config, where: c.is_default == true)
      |> Repo.update_all(set: [is_default: false])

      config
      |> Config.changeset(%{is_default: true})
      |> Repo.update!()
    end)
  end

  @spec change_config(Config.t(), map()) :: Ecto.Changeset.t()
  def change_config(%Config{} = config, attrs \\ %{}) do
    Config.changeset(config, attrs)
  end
end
