defmodule RougailSolstice.Robot.CameraAdapter.Liveview.StreamTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Robot.CameraAdapter.Liveview.JpegParser
  alias RougailSolstice.Robot.CameraAdapter.Liveview.Stream

  @soi JpegParser.soi_marker()
  @eoi JpegParser.eoi_marker()

  defp make_frame(payload) do
    @soi <> payload <> @eoi
  end

  describe "start_link/1" do
    test "starts with default options" do
      test_pid = self()

      port_spawner = fn args ->
        send(test_pid, {:port_spawned, args})
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      assert_receive {:port_spawned, ["gphoto2", "--capture-movie", "--stdout"]}
      assert Stream.status(pid) == :running
      Stream.stop(pid)
    end

    test "starts with camera port option" do
      test_pid = self()

      port_spawner = fn args ->
        send(test_pid, {:port_spawned, args})
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} =
        Stream.start_link(
          camera_port: "usb:001,002",
          port_spawner: port_spawner
        )

      assert_receive {:port_spawned,
                      ["gphoto2", "--port", "usb:001,002", "--capture-movie", "--stdout"]}

      Stream.stop(pid)
    end
  end

  describe "frame delivery" do
    test "stores latest frame for retrieval" do
      port_spawner = fn _args ->
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      assert {:error, :no_frame} = Stream.get_latest_frame(pid)

      frame = make_frame(<<1, 2, 3, 4, 5>>)
      send(pid, {get_port(pid), {:data, frame}})
      Process.sleep(10)

      assert {:ok, ^frame} = Stream.get_latest_frame(pid)
      Stream.stop(pid)
    end

    test "keeps latest frame from multiple frames in single chunk" do
      port_spawner = fn _args ->
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      frame1 = make_frame(<<1, 2>>)
      frame2 = make_frame(<<3, 4>>)
      send(pid, {get_port(pid), {:data, frame1 <> frame2}})
      Process.sleep(10)

      assert {:ok, ^frame2} = Stream.get_latest_frame(pid)
      Stream.stop(pid)
    end

    test "assembles frames across data chunks" do
      port_spawner = fn _args ->
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      port = get_port(pid)
      send(pid, {port, {:data, @soi <> <<1, 2>>}})
      Process.sleep(10)
      assert {:error, :no_frame} = Stream.get_latest_frame(pid)

      send(pid, {port, {:data, <<3, 4>> <> @eoi}})
      Process.sleep(10)

      expected_frame = make_frame(<<1, 2, 3, 4>>)
      assert {:ok, ^expected_frame} = Stream.get_latest_frame(pid)
      Stream.stop(pid)
    end
  end

  describe "port failure handling" do
    test "schedules restart on port exit" do
      test_pid = self()
      spawn_count = :counters.new(1, [])

      port_spawner = fn args ->
        :counters.add(spawn_count, 1, 1)
        count = :counters.get(spawn_count, 1)
        send(test_pid, {:port_spawned, count, args})
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      assert_receive {:port_spawned, 1, _}, 1000
      port = get_port(pid)
      send(pid, {port, {:exit_status, 1}})

      assert_receive {:port_spawned, 2, _}, 3000
      Stream.stop(pid)
    end

    test "stops after max restart attempts with exception" do
      test_pid = self()
      spawn_count = :counters.new(1, [])

      port_spawner = fn _args ->
        :counters.add(spawn_count, 1, 1)
        count = :counters.get(spawn_count, 1)
        send(test_pid, {:port_spawned, count})
        raise "simulated port failure"
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      assert_receive {:port_spawned, 1}, 500
      assert_receive {:port_spawned, 2}, 2500
      assert_receive {:port_spawned, 3}, 3500

      Process.sleep(5000)
      assert Stream.status(pid) == :failed
      assert :counters.get(spawn_count, 1) == 3
      Stream.stop(pid)
    end

    test "stops after max restart attempts with port exits" do
      test_pid = self()
      spawn_count = :counters.new(1, [])

      port_spawner = fn _args ->
        :counters.add(spawn_count, 1, 1)
        count = :counters.get(spawn_count, 1)
        send(test_pid, {:port_spawned, count})
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)

      for _ <- 1..3 do
        assert_receive {:port_spawned, _}, 4000
        port = get_port(pid)

        if port do
          send(pid, {port, {:exit_status, 1}})
        end
      end

      Process.sleep(5000)
      assert Stream.status(pid) == :failed
      assert :counters.get(spawn_count, 1) == 3
      Stream.stop(pid)
    end
  end

  describe "stop/1" do
    test "stops the server cleanly" do
      port_spawner = fn _args ->
        Port.open({:spawn, "cat"}, [:binary, :exit_status])
      end

      {:ok, pid} = Stream.start_link(port_spawner: port_spawner)
      ref = Process.monitor(pid)

      assert :ok = Stream.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  defp get_port(pid) do
    :sys.get_state(pid).port
  end
end
