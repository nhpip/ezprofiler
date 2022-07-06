defmodule EZProfiler.MixFile do
  use Mix.Project

  def project do
    [
      app: :ezprofiler,
      version: "1.1.1",
      elixir: "~> 1.11",
      escript: escript(),
      package: package(),
      description: description(),
      name: "ezprofiler",
      aliases: aliases(),
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

  defp aliases do
    [
      compile:  "escript.build"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
     {:ex_doc, "~> 0.28.4", only: :dev, runtime: false}
    ]
  end

  defp description() do
    "Provides a simple to use profiling mechanism to inspect the behavior of an application on a target VM. 
     This runs as a stand-alone `escript` for both for ease of use and to minimize impact on the target VM.
     Supports Erlang's eprof, fprof or cprof profilers"
  end

  defp package() do
    [
      files: ~w(lib mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/nhpip/ezprofiler"}
    ]
  end

  defp make_shebang() do
    erlang_path = :code.lib_dir() |> to_string()
    elixir_path = :code.lib_dir(:elixir) |> to_string()
    logger_path = :code.lib_dir(:logger) |> to_string()
    "#! /usr/bin/env -S ERL_LIBS=" <> erlang_path <> ":" <> elixir_path <> ":" <> logger_path  <>" escript\n"
  end

end
