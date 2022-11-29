defmodule MC714.P2.MixProject do
  use Mix.Project

  def project do
    [
      app: :mc714_p2,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {MC714.P2.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:libcluster, "~> 3.3.1"},
      {:plug_cowboy, "~> 2.6.0"},
      {:poison, "~> 5.0.0"}
    ]
  end
end
