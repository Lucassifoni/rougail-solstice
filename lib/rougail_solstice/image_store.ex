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

  def put(key, binary, opts) when is_binary(key) and is_binary(binary) and is_list(opts) do
    put(__MODULE__, key, binary, opts)
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

  @spec get(String.t()) :: entry() | nil
  def get(key) when is_binary(key), do: get(__MODULE__, key)

  @spec get(GenServer.server(), String.t()) :: entry() | nil
  def get(store, key) do
    Agent.get(store, fn state -> Map.get(state, key) end)
  end

  def delete(key) when is_binary(key), do: delete(__MODULE__, key)

  def delete(store, key) do
    Agent.update(store, fn state -> Map.delete(state, key) end)
  end

  def delete_prefix(prefix) when is_binary(prefix), do: delete_prefix(__MODULE__, prefix)

  def delete_prefix(store, prefix) do
    Agent.update(store, fn state ->
      state
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.reduce(state, &Map.delete(&2, &1))
    end)
  end

  def url(key) do
    "/images/#{key}"
  end

  def session_url(session_id, key) do
    "/sessions/#{session_id}/images/#{key}"
  end
end
