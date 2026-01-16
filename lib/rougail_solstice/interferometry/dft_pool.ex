defmodule RougailSolstice.Interferometry.DFT.Pool do
  @moduledoc """
  A pool of DFT preview workers with latest-wins semantics.

  When all workers are busy, new requests replace the pending request.
  This prevents lag buildup during high-framerate input - only the
  most recent frame is processed.

  ## Usage

      {:ok, pool} = DFT.Pool.start_link(
        pool_size: 10,
        dft_size: 512,
        callback: fn result -> handle_result(result) end
      )

      DFT.Pool.submit(pool, image_binary, circle)

  Results are delivered asynchronously via the callback function:
  - `{:ok, png_binary, metadata}` on success
  - `{:error, reason}` on failure

  The metadata map contains `:circle` and `:submitted_at` for correlation.
  """

  use GenServer

  require Logger

  alias RougailSolstice.Interferometry.DFT.Nx, as: DFTNx

  @default_pool_size 10
  @default_dft_size 512

  defstruct [
    :pool_size,
    :dft_size,
    :callback,
    :available,
    :busy,
    :pending,
    :stats
  ]

  @type submit_opts :: [priority: :normal | :high]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Submit a frame for DFT preview computation.

  If a worker is available, processing starts immediately.
  If all workers are busy, this frame becomes the pending frame,
  replacing any previous pending frame (latest-wins).

  Returns `:ok` immediately - results come via callback.
  """
  @spec submit(GenServer.server(), binary(), map()) :: :ok
  def submit(pool, image_binary, circle) do
    GenServer.cast(pool, {:submit, image_binary, circle, System.monotonic_time(:millisecond)})
  end

  @doc """
  Get current pool statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(pool) do
    GenServer.call(pool, :stats)
  end

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    dft_size = Keyword.get(opts, :dft_size, @default_dft_size)
    callback = Keyword.get(opts, :callback, fn _ -> :ok end)

    state = %__MODULE__{
      pool_size: pool_size,
      dft_size: dft_size,
      callback: callback,
      available: [],
      busy: %{},
      pending: nil,
      stats: %{
        submitted: 0,
        processed: 0,
        dropped: 0,
        errors: 0
      }
    }

    state = spawn_workers(state, pool_size)

    Logger.info("[DFT.Pool] Started with #{pool_size} workers, dft_size=#{dft_size}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:submit, image_binary, circle, submitted_at}, state) do
    state = update_in(state.stats.submitted, &(&1 + 1))

    case state.available do
      [worker | rest] ->
        state = dispatch_to_worker(state, worker, image_binary, circle, submitted_at)
        {:noreply, %{state | available: rest}}

      [] ->
        state =
          if state.pending != nil do
            update_in(state.stats.dropped, &(&1 + 1))
          else
            state
          end

        pending = %{
          image_binary: image_binary,
          circle: circle,
          submitted_at: submitted_at
        }

        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:available_workers, length(state.available))
      |> Map.put(:busy_workers, map_size(state.busy))
      |> Map.put(:has_pending, state.pending != nil)

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:worker_result, worker_pid, result, metadata}, state) do
    state = %{state | busy: Map.delete(state.busy, worker_pid)}

    case result do
      {:ok, png_binary} ->
        state = update_in(state.stats.processed, &(&1 + 1))
        safe_callback(state.callback, {:ok, png_binary, metadata})

      {:error, reason} ->
        state = update_in(state.stats.errors, &(&1 + 1))
        safe_callback(state.callback, {:error, reason})
    end

    state = maybe_process_pending(state, worker_pid)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.warning("[DFT.Pool] Worker #{inspect(pid)} died: #{inspect(reason)}, respawning")

    state = %{state | busy: Map.delete(state.busy, pid)}
    state = %{state | available: List.delete(state.available, pid)}

    state = spawn_workers(state, 1)
    state = maybe_process_pending(state, nil)

    {:noreply, state}
  end

  defp spawn_workers(state, count) do
    new_workers =
      for _ <- 1..count do
        {:ok, pid} = start_worker(state.dft_size)
        Process.monitor(pid)
        pid
      end

    %{state | available: state.available ++ new_workers}
  end

  defp start_worker(dft_size) do
    parent = self()

    pid =
      spawn_link(fn ->
        worker_loop(parent, dft_size)
      end)

    {:ok, pid}
  end

  defp worker_loop(parent, dft_size) do
    receive do
      {:compute, image_binary, circle, submitted_at} ->
        result = DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: dft_size)

        metadata = %{
          circle: circle,
          submitted_at: submitted_at,
          completed_at: System.monotonic_time(:millisecond)
        }

        send(parent, {:worker_result, self(), result, metadata})
        worker_loop(parent, dft_size)

      :stop ->
        :ok
    end
  end

  defp dispatch_to_worker(state, worker, image_binary, circle, submitted_at) do
    send(worker, {:compute, image_binary, circle, submitted_at})
    %{state | busy: Map.put(state.busy, worker, %{circle: circle, submitted_at: submitted_at})}
  end

  defp maybe_process_pending(state, worker_pid) do
    case {state.pending, worker_pid || List.first(state.available)} do
      {nil, _} ->
        if worker_pid do
          %{state | available: [worker_pid | state.available]}
        else
          state
        end

      {_pending, nil} ->
        state

      {pending, worker} ->
        state =
          dispatch_to_worker(
            state,
            worker,
            pending.image_binary,
            pending.circle,
            pending.submitted_at
          )

        available = if worker_pid, do: state.available, else: List.delete(state.available, worker)
        %{state | pending: nil, available: available}
    end
  end

  defp safe_callback(callback, result) do
    try do
      callback.(result)
    rescue
      e ->
        Logger.error("[DFT.Pool] Callback error: #{inspect(e)}")
    end
  end
end
