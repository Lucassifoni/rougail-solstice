defmodule RougailSolstice.ImageStore do
  @moduledoc """
  In-memory store for image binaries with metadata.
  Supports named instances for session-scoped usage.
  """

  use Agent

  @type entry :: %{
          binary: binary(),
          content_type: String.t(),
          dimensions: {non_neg_integer(), non_neg_integer()} | nil,
          updated_at: integer()
        }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def put(store, key, binary) when is_binary(key) and is_binary(binary) do
    put(store, key, binary, [])
  end

  def put(store, key, binary, opts) do
    content_type = Keyword.get(opts, :content_type, "image/jpeg")
    dimensions = Keyword.get(opts, :dimensions)

    Agent.update(store, fn state ->
      Map.put(state, key, %{
        binary: binary,
        content_type: content_type,
        dimensions: dimensions,
        updated_at: System.monotonic_time()
      })
    end)

    key
  end

  @spec get(GenServer.server(), String.t()) :: entry() | nil
  def get(store, key) do
    Agent.get(store, fn state -> Map.get(state, key) end)
  end

  def delete(store, key) do
    Agent.update(store, fn state -> Map.delete(state, key) end)
  end

  def delete_prefix(store, prefix) do
    Agent.update(store, fn state ->
      state
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.reduce(state, &Map.delete(&2, &1))
    end)
  end

  def session_url(session_id, key) do
    "/sessions/#{session_id}/images/#{key}"
  end

  @doc """
  Extracts the image key from a session URL.
  Returns {:ok, key} or :error.
  """
  @spec extract_key(String.t()) :: {:ok, String.t()} | :error
  def extract_key("/sessions/" <> rest) do
    case String.split(rest, "/images/", parts: 2) do
      [_session_id, key] -> {:ok, key}
      _ -> :error
    end
  end

  def extract_key("/images/" <> key), do: {:ok, key}
  def extract_key(_), do: :error

  @doc """
  Fetches binary data from a session URL.
  """
  @spec fetch_binary(GenServer.server(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_binary(store, url) do
    with {:ok, key} <- extract_key(url),
         %{binary: binary} when binary != nil <- get(store, key) do
      {:ok, binary}
    else
      nil -> {:error, :not_found}
      %{binary: nil} -> {:error, :not_found}
      :error -> {:error, :invalid_url}
    end
  end
end
