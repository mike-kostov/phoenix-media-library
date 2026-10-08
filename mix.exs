defmodule PhxMediaLibrary.MixProject do
  use Mix.Project

  @version "0.9.0"
  @source_url "https://github.com/mike-kostov/phoenix-media-library"

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
      docs: docs(),

      # Dialyzer
      dialyzer: dialyzer()
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
      {:req, "~> 0.7.4"},
      {:mime, "~> 2.0"},
      {:telemetry, "~> 1.0"},

      # === Optional: Image processing (libvips) ===
      {:image, "~> 0.54", optional: true},

      # === Optional: S3 Storage ===
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},

      # === Optional: Oban-based async processing ===
      {:oban, "~> 2.18", optional: true},

      # === Optional: Phoenix view helpers ===
      {:phoenix_live_view, "~> 1.1", optional: true},

      # === Dev/Test ===
      {:postgrex, ">= 0.0.0", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "cmd --cd . sh -c 'MIX_ENV=test mix test'"
      ]
    ]
  end

  defp description do
    """
    Attach files to Ecto schemas: collections, image conversions, WebP and
    AVIF, responsive images, placeholders, LiveView components, and local,
    S3 or R2 storage. Inspired by Spatie's Laravel Media Library.
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
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      # The CHANGELOG names functions that later releases removed.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "guides/upgrading-to-0.10.md"],
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/collections-and-conversions.md",
        "guides/liveview.md",
        "guides/storage.md",
        "guides/error-handling.md",
        "guides/telemetry.md",
        "guides/advanced.md",
        "guides/multi-tenant.md",
        "guides/upgrading-to-0.10.md",
        "guides/upgrading-to-0.9.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/collections-and-conversions.md",
          "guides/liveview.md",
          "guides/storage.md",
          "guides/error-handling.md",
          "guides/telemetry.md",
          "guides/advanced.md",
          "guides/multi-tenant.md",
          "guides/upgrading-to-0.10.md",
          "guides/upgrading-to-0.9.md"
        ]
      ],
      groups_for_modules: [
        Core: [
          PhxMediaLibrary,
          PhxMediaLibrary.HasMedia,
          PhxMediaLibrary.HasMedia.DSL,
          PhxMediaLibrary.Media,
          PhxMediaLibrary.Collection,
          PhxMediaLibrary.Conversion,
          PhxMediaLibrary.FileName,
          PhxMediaLibrary.UUIDv7,
          PhxMediaLibrary.Config
        ],
        "Phoenix and LiveView": [
          PhxMediaLibrary.ViewHelpers,
          PhxMediaLibrary.Components,
          PhxMediaLibrary.LiveUpload,
          PhxMediaLibrary.MediaLive,
          PhxMediaLibrary.Plug.MediaDownload,
          PhxMediaLibrary.Plug.StaticHeaders
        ],
        "URLs and downloads": [
          PhxMediaLibrary.UrlGenerator,
          PhxMediaLibrary.SignedUrl,
          PhxMediaLibrary.Downloader
        ],
        Storage: [
          PhxMediaLibrary.Storage,
          PhxMediaLibrary.Storage.Disk,
          PhxMediaLibrary.Storage.S3,
          PhxMediaLibrary.Storage.Memory,
          PhxMediaLibrary.PathGenerator,
          PhxMediaLibrary.PathGenerator.Default,
          PhxMediaLibrary.PathGenerator.Flat,
          PhxMediaLibrary.PathGenerator.DateBased,
          PhxMediaLibrary.PathGenerator.Tenant
        ],
        "Images and video": [
          PhxMediaLibrary.ResponsiveImages,
          PhxMediaLibrary.Blurhash,
          PhxMediaLibrary.ImageProcessor,
          PhxMediaLibrary.ImageProcessor.Image,
          PhxMediaLibrary.ImageProcessor.Null,
          PhxMediaLibrary.VideoProcessor,
          PhxMediaLibrary.VideoProcessor.FFmpeg,
          PhxMediaLibrary.VideoProcessor.Null,
          PhxMediaLibrary.DocumentRenderer,
          PhxMediaLibrary.DocumentRenderer.Pdftoppm,
          PhxMediaLibrary.DocumentRenderer.Vips,
          PhxMediaLibrary.DocumentRenderer.Null,
          PhxMediaLibrary.MetadataExtractor,
          PhxMediaLibrary.MetadataExtractor.Default,
          PhxMediaLibrary.MimeDetector,
          PhxMediaLibrary.MimeDetector.Default
        ],
        "Background work": [
          PhxMediaLibrary.AsyncProcessor,
          PhxMediaLibrary.AsyncProcessor.Task,
          PhxMediaLibrary.AsyncProcessor.Oban,
          PhxMediaLibrary.AsyncProcessor.Inline,
          PhxMediaLibrary.Workers.ProcessConversions,
          PhxMediaLibrary.Workers.Doctor
        ],
        "Health and repairs": [
          PhxMediaLibrary.Doctor,
          PhxMediaLibrary.Doctor.CLI,
          PhxMediaLibrary.Doctor.Schedule,
          PhxMediaLibrary.Health,
          PhxMediaLibrary.Pipeline
        ],
        "Errors and telemetry": [
          PhxMediaLibrary.Error,
          PhxMediaLibrary.StorageError,
          PhxMediaLibrary.ValidationError,
          PhxMediaLibrary.Telemetry
        ],
        Internals: [
          PhxMediaLibrary.Model,
          PhxMediaLibrary.ModelRegistry,
          PhxMediaLibrary.MediaAdder,
          PhxMediaLibrary.Transfer,
          PhxMediaLibrary.Import,
          PhxMediaLibrary.Conversions,
          PhxMediaLibrary.LocalSource,
          PhxMediaLibrary.Webp,
          PhxMediaLibrary.Avif,
          PhxMediaLibrary.ResponsiveImages.WidthCalculator
        ]
      ]
    ]
  end
end
