defmodule EZProfiler.MixFile do
  use Mix.Project

  def project do
    [
      app: :ezprofiler,
      version: "0.1.0",
      elixir: "~> 1.11",
      escript: escript(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:tools, :runtime_tools]
    ]
  end

  defp escript do
    [
      main_module: EZProfiler,
      embed_elixir: false,
      shebang: make_shebang()
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
     {:ex_doc, "~> 0.28.4", only: :dev, runtime: false}
    ]
  end

  defp make_shebang() do
    erlang_path = :code.lib_dir() |> to_string()
    elixir_path = :code.lib_dir(:elixir) |> to_string()
    logger_path = :code.lib_dir(:logger) |> to_string()
    "#! /usr/bin/env -S ERL_LIBS=" <> erlang_path <> ":" <> elixir_path <> ":" <> logger_path  <>" escript\n"
  end

end
