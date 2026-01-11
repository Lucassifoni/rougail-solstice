alias RougailSolstice.Interferometry.WFT
alias RougailSolstice.Interferometry.WFT.Nx, as: WFTNx

sample_path = "priv/static/samples/sample.wft"
{:ok, content} = File.read(sample_path)

IO.puts("Warming up EXLA...")
{:ok, _} = WFTNx.parse(content)
IO.puts("Warmup complete.\n")

IO.puts("=" |> String.duplicate(60))
IO.puts("WFT Parsing + Zernike Fitting Benchmark")
IO.puts("=" |> String.duplicate(60))

Benchee.run(
  %{
    "WFT (list-based)" => fn -> WFT.parse(content) end,
    "WFT.Nx (tensor-based)" => fn -> WFTNx.parse(content) end
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)

IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("WFT Rendering Benchmark")
IO.puts("=" |> String.duplicate(60))

{:ok, wft_list} = WFT.parse(content)
{:ok, wft_nx} = WFTNx.parse(content)

Benchee.run(
  %{
    "WFT.render_to_png (list-based)" => fn -> WFT.render_to_png(wft_list) end,
    "WFT.Nx.render_to_png (tensor-based)" => fn -> WFTNx.render_to_png(wft_nx) end
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)

IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("Full Pipeline Benchmark (parse + render)")
IO.puts("=" |> String.duplicate(60))

Benchee.run(
  %{
    "WFT full pipeline (list-based)" => fn ->
      {:ok, wft} = WFT.parse(content)
      WFT.render_to_png(wft)
    end,
    "WFT.Nx full pipeline (tensor-based)" => fn ->
      {:ok, wft} = WFTNx.parse(content)
      WFTNx.render_to_png(wft)
    end
  },
  warmup: 2,
  time: 10,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ]
)
