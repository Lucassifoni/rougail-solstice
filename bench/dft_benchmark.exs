alias RougailSolstice.Interferometry.DFT.Nx, as: DFTNx
alias RougailSolstice.Interferometry.Sidecar.{Supervisor, Worker}

sample_path = "priv/static/samples/_MG_8459.JPG"
{:ok, image_binary} = File.read(sample_path)

circle = %{cx: 1700, cy: 1150, r: 950}

IO.puts("Warming up EXLA...")
{:ok, _} = DFTNx.compute_magnitude_preview(image_binary, circle)
IO.puts("Warmup complete.\n")

sidecar_available =
  try do
    worker = Supervisor.preview_worker()
    case Worker.send_preview(worker, image_binary, circle) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

IO.puts("=" |> String.duplicate(60))
IO.puts("DFT Magnitude Preview Benchmark")
IO.puts("=" |> String.duplicate(60))
IO.puts("Image: #{sample_path}")
IO.puts("Circle: cx=#{circle.cx}, cy=#{circle.cy}, r=#{circle.r}")
IO.puts("Sidecar available: #{sidecar_available}")
IO.puts("=" |> String.duplicate(60))

nx_benchmarks = %{
  "DFT.Nx (512x512)" => fn ->
    DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 512)
  end
}

sidecar_benchmarks =
  if sidecar_available do
    %{
      "Sidecar (C++)" => fn ->
        worker = Supervisor.preview_worker()
        Worker.send_preview(worker, image_binary, circle)
      end
    }
  else
    IO.puts("\n⚠️  Sidecar not available - skipping sidecar benchmark")
    IO.puts("   Start Docker and run again for full comparison\n")
    %{}
  end

benchmarks = Map.merge(nx_benchmarks, sidecar_benchmarks)

Benchee.run(
  benchmarks,
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)

IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("DFT.Nx Size Comparison")
IO.puts("=" |> String.duplicate(60))

Benchee.run(
  %{
    "DFT.Nx (256x256)" => fn ->
      DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 256)
    end,
    "DFT.Nx (512x512)" => fn ->
      DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 512)
    end,
    "DFT.Nx (1024x1024)" => fn ->
      DFTNx.compute_magnitude_preview(image_binary, circle, dft_size: 1024)
    end
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)
