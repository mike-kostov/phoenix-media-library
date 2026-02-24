if Code.ensure_loaded?(Oban) do
  defmodule PhxMediaLibrary.AsyncProcessor.Oban do
    @moduledoc """
    Oban-based async processor for reliable background processing.

    Requires `oban` as a dependency and proper Oban configuration in your app.

    ## Configuration

        config :phx_media_library,
          async_processor: PhxMediaLibrary.AsyncProcessor.Oban

        # In your Oban config, add the queue:
        config :my_app, Oban,
          queues: [media: 10]

    """

    @behaviour PhxMediaLibrary.AsyncProcessor

    @impl true
    def process_async(media, conversions) do
      conversion_names = Enum.map(conversions, & &1.name)

      %{media_id: media.id, conversions: conversion_names}
      |> PhxMediaLibrary.Workers.ProcessConversions.new()
      |> Oban.insert()

      :ok
    end
  end

  defmodule PhxMediaLibrary.Workers.ProcessConversions do
    @moduledoc """
    Oban worker for processing media conversions.
    """

    use Oban.Worker,
      queue: :media,
      max_attempts: 3

    alias PhxMediaLibrary.{Config, Conversions}

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"media_id" => media_id, "conversions" => conversion_names}}) do
      repo = Config.repo()

      case repo.get(PhxMediaLibrary.Media, media_id) do
        nil ->
          {:error, :media_not_found}

        media ->
          # Get conversion configs from the model
          conversions = get_conversions(media, conversion_names)
          Conversions.process(media, conversions)
      end
    end

    defp get_conversions(media, conversion_names) do
      # This is simplified - in reality we'd need to look up the model
      # and get its conversion definitions
      Enum.map(conversion_names, fn name ->
        %PhxMediaLibrary.Conversion{name: String.to_atom(name)}
      end)
    end
  end
end
