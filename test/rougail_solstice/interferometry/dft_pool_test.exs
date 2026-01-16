defmodule RougailSolstice.Interferometry.DFT.PoolTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.DFT.Pool

  @sample_image_path "priv/static/samples/_MG_8459.JPG"
  @circle %{cx: 1700, cy: 1150, r: 950}

  describe "pool behavior" do
    setup do
      test_pid = self()
      ref = make_ref()

      callback = fn result ->
        send(test_pid, {ref, result})
      end

      {:ok, pool} =
        Pool.start_link(
          pool_size: 2,
          dft_size: 256,
          callback: callback
        )

      on_exit(fn ->
        if Process.alive?(pool), do: GenServer.stop(pool)
      end)

      {:ok, pool: pool, ref: ref}
    end

    test "processes a single frame", %{pool: pool, ref: ref} do
      image_binary = File.read!(@sample_image_path)

      :ok = Pool.submit(pool, image_binary, @circle)

      assert_receive {^ref, {:ok, png_binary, metadata}}, 5000
      assert is_binary(png_binary)
      assert byte_size(png_binary) > 1000
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = png_binary
      assert metadata.circle == @circle
    end

    test "reports correct stats", %{pool: pool} do
      stats = Pool.stats(pool)

      assert stats.submitted == 0
      assert stats.processed == 0
      assert stats.dropped == 0
      assert stats.available_workers == 2
      assert stats.busy_workers == 0
    end

    test "latest-wins: drops pending when all workers busy", %{pool: pool, ref: ref} do
      image_binary = File.read!(@sample_image_path)

      :ok = Pool.submit(pool, image_binary, @circle)
      :ok = Pool.submit(pool, image_binary, @circle)
      :ok = Pool.submit(pool, image_binary, @circle)
      :ok = Pool.submit(pool, image_binary, @circle)
      :ok = Pool.submit(pool, image_binary, @circle)

      results =
        Enum.reduce_while(1..10, [], fn _, acc ->
          receive do
            {^ref, result} -> {:cont, [result | acc]}
          after
            3000 -> {:halt, acc}
          end
        end)

      stats = Pool.stats(pool)

      assert stats.submitted == 5
      assert stats.dropped >= 2
      assert length(results) >= 2
      assert length(results) <= 3
    end
  end
end
