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
      source_url: "https://github.com/Gazler/breeze_timeline",
      package: [
        files: ~w(lib examples mix.exs README.md LICENCE.md),
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
      breeze_dependency()
    ]
  end

  defp breeze_dependency do
    case System.get_env("BREEZE_TIMELINE_BREEZE_PATH") do
      path when is_binary(path) and path != "" -> {:breeze, path: path}
      _path -> {:breeze, "~> 0.5"}
    end
  end
end
