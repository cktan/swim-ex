defmodule SwimEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :swim_ex,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "SWIM+INF+Susp cluster membership library",
      package: package(),
      name: "SwimEx",
      source_url: "https://github.com/cktan/swim-ex",
      homepage_url: "https://hex.pm/packages/swim_ex",
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"],
        source_ref: "main",
        formatters: ["html", "epub"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/cktan/swim-ex",
        "Design" => "https://github.com/cktan/swim-ex/blob/main/DESIGN.md",
        "Algorithm" => "https://github.com/cktan/swim-ex/blob/main/ALGORITHM.md",
        "Usage" => "https://github.com/cktan/swim-ex/blob/main/USAGE.md"
      },
      maintainers: ["CK Tan"],
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end
end
