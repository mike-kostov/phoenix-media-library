defmodule PhxMediaLibrary.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/mike-kostov/phx_media_library"

  def project do
    [
      app: :phx_media_library,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "PhxMediaLibrary",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PhxMediaLibrary.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # === Required ===
      {:ecto_sql, "~> 3.12"},
      {:image, "~> 0.54"},
      {:req, "~> 0.5"},
      {:mime, "~> 2.0"},

      # === Optional: S3 Storage ===
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},

      # === Optional: Oban-based async processing ===
      {:oban, "~> 2.18", optional: true},

      # === Optional: Phoenix view helpers ===
      {:phoenix_live_view, "~> 1.0", optional: true},

      # === Dev/Test ===
      {:postgrex, ">= 0.0.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: ["format", "credo --strict", "dialyzer", "test"]
    ]
  end

  defp description do
    """
    Associate media files with Ecto schemas. Provides image conversions,
    responsive images, and multiple storage backends (local, S3).
    Inspired by Spatie's Laravel Media Library.
    """
  end

  defp package do
    [
      maintainers: ["Mike Kostov"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
