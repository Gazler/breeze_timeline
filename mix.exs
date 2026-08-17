defmodule BreezeTimeline.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :breeze_timeline,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Opt-in runtime timeline for Breeze applications",
      name: "Breeze Timeline",
      source_url: "https://github.com/Gazler/breeze_timeline",
      docs: docs(),
      package: [
        files: ~w(lib mix.exs README.md LICENCE.md),
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/Gazler/breeze_timeline",
          "Breeze" => "https://github.com/Gazler/breeze"
        }
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Breeze.Timeline.Application, []}
    ]
  end

  defp deps do
    [
      breeze_dependency(),
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENCE.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp breeze_dependency do
    case System.get_env("BREEZE_TIMELINE_BREEZE_PATH") do
      path when is_binary(path) and path != "" -> {:breeze, path: path}
      _path -> {:breeze, "~> 0.5"}
    end
  end
end
