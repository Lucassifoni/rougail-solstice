defmodule RougailSolstice.ImageStore do
  use Agent

  @type entry :: %{
          binary: binary(),
          content_type: String.t(),
          dimensions: {non_neg_integer(), non_neg_integer()} | nil,
          updated_at: integer()
        }

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def put(key, binary, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "image/jpeg")
    dimensions = Keyword.get(opts, :dimensions)

    Agent.update(__MODULE__, fn state ->
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
  def get(key) do
    Agent.get(__MODULE__, fn state -> Map.get(state, key) end)
  end

  def delete(key) do
    Agent.update(__MODULE__, fn state -> Map.delete(state, key) end)
  end

  def delete_prefix(prefix) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.reduce(state, &Map.delete(&2, &1))
    end)
  end

  def url(key) do
    "/images/#{key}"
  end
end
