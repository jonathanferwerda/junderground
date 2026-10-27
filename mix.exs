defmodule Junderground.MixProject do
  use Mix.Project

  def project do
    [
      app: :junderground,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Junderground.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"}
    ]
  end
end
