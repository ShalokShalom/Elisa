defmodule HermesBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :hermes_beam,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {HermesBeam.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # --- Core Ash Stack ---
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      # ash_ai is under active development; >= 0.5.0 allows patch and minor
      # upgrades while still bounding the major API surface.
      {:ash_ai, ">= 0.5.0 and < 1.0.0"},
      {:reactor, "~> 0.9"},

      # --- Database ---
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},

      # --- ML Stack ---
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      {:bumblebee, "~> 0.6"},

      # --- Distributed Clustering ---
      {:libcluster, "~> 3.3"},
      {:libcluster_postgres, "~> 0.2"},

      # --- Phoenix LiveView Dashboard ---
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # --- Utilities ---
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # --- Dev / Test ---
      {:floki, ">= 0.30.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind hermes_beam", "esbuild hermes_beam"],
      "assets.deploy": [
        "tailwind hermes_beam --minify",
        "esbuild hermes_beam --minify",
        "phx.digest"
      ]
    ]
  end
end
