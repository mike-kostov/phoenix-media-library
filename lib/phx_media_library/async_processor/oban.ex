if Code.ensure_loaded?(Oban) do
  defmodule PhxMediaLibrary.AsyncProcessor.Oban do
    @moduledoc """
    Oban-based async processor for reliable background processing.

    Requires `oban` as a dependency and proper Oban configuration in your app.
    Unlike the default `Task`-based processor, Oban jobs are persisted to the
    database, survive application restarts, and support automatic retries with
    configurable backoff.

    ## Setup

    1. Add `:oban` to your dependencies and configure it:

           # mix.exs
           {:oban, "~> 2.18"}

           # config/config.exs
           config :my_app, Oban,
             repo: MyApp.Repo,
             queues: [media: 10]

    2. Tell PhxMediaLibrary to use the Oban adapter:

           config :phx_media_library,
             async_processor: PhxMediaLibrary.AsyncProcessor.Oban

    ## Queue Configuration

    The worker uses the `:media` queue by default. Adjust concurrency to
    match your server's CPU/memory capacity:

        # Low-traffic app
        queues: [media: 5]

        # High-traffic app with beefy servers
        queues: [media: 20]

    ## Retry Behaviour

    The `ProcessConversions` worker is configured with `max_attempts: 3`.
    Failed jobs use Oban's default exponential backoff. You can monitor
    failed jobs via Oban's built-in dashboard or `Oban.Web`.

    ## How It Works

    When media is uploaded and conversions are defined, the processor enqueues
    an Oban job with the media ID, the conversion names, and the `mediable_type`
    so the worker can look up the originating model module and retrieve the full
    `Conversion` definitions (with dimensions, quality, fit mode, etc.).

    This avoids the pitfall of serializing only conversion names and losing all
    configuration — the previous implementation created empty `Conversion` structs
    with only a `:name` field.
    """

    @behaviour PhxMediaLibrary.AsyncProcessor

    alias PhxMediaLibrary.{Conversions, Workers.ProcessConversions}

    @impl true
    def process_async(media, conversions) do
      conversion_names = Enum.map(conversions, &to_string(&1.name))

      %{
        media_id: media.id,
        conversions: conversion_names,
        mediable_type: media.mediable_type
      }
      |> ProcessConversions.new()
      |> Oban.insert()

      :ok
    end

    @doc """
    Process conversions synchronously, bypassing the Oban queue.

    Useful for tests or situations where you need conversions to complete
    before continuing (e.g. generating a thumbnail before returning a
    response).

    ## Examples

        PhxMediaLibrary.AsyncProcessor.Oban.process_sync(media, conversions)

    """
    @impl true
    def process_sync(media, conversions) do
      Conversions.process(media, conversions)
    end
  end

  defmodule PhxMediaLibrary.Workers.ProcessConversions do
    @moduledoc """
    Oban worker for processing media conversions.

    Resolves full `Conversion` definitions from the model's
    `media_conversions/0` callback, ensuring that width, height, quality,
    fit mode, format, and all other options are preserved during async
    processing.

    ## Job Args

    - `"media_id"` — the binary ID of the `Media` record
    - `"conversions"` — list of conversion name strings (e.g. `["thumb", "preview"]`)
    - `"mediable_type"` — the polymorphic type string (e.g. `"posts"`) used to
      discover the originating Ecto schema module and its conversion definitions
    """

    use Oban.Worker,
      queue: :media,
      max_attempts: 3

    alias PhxMediaLibrary.{Config, Conversion, Conversions, ModelRegistry}

    require Logger

    @impl Oban.Worker
    def perform(%Oban.Job{
          args: %{
            "media_id" => media_id,
            "conversions" => conversion_names,
            "mediable_type" => mediable_type
          }
        }) do
      repo = Config.repo()

      case repo.get(PhxMediaLibrary.Media, media_id) do
        nil ->
          Logger.warning(
            "[PhxMediaLibrary] Media #{media_id} not found, skipping conversion processing"
          )

          {:discard, :media_not_found}

        media ->
          conversions = resolve_conversions(mediable_type, conversion_names, media)

          case conversions do
            [] ->
              Logger.warning(
                "[PhxMediaLibrary] No conversion definitions resolved for media #{media_id} " <>
                  "(requested: #{inspect(conversion_names)}, mediable_type: #{mediable_type})"
              )

              :ok

            conversions ->
              Conversions.process(media, conversions)
          end
      end
    end

    # Also handle legacy job args that don't include mediable_type
    def perform(%Oban.Job{
          args: %{"media_id" => media_id, "conversions" => conversion_names}
        }) do
      repo = Config.repo()

      case repo.get(PhxMediaLibrary.Media, media_id) do
        nil ->
          {:discard, :media_not_found}

        media ->
          conversions =
            resolve_conversions(media.mediable_type, conversion_names, media)

          case conversions do
            [] ->
              Logger.warning(
                "[PhxMediaLibrary] No conversion definitions resolved for media #{media_id} " <>
                  "(legacy job without mediable_type, requested: #{inspect(conversion_names)})"
              )

              :ok

            conversions ->
              Conversions.process(media, conversions)
          end
      end
    end

    # -------------------------------------------------------------------------
    # Conversion Resolution
    # -------------------------------------------------------------------------

    @doc false
    def resolve_conversions(mediable_type, conversion_names, media) do
      requested_atoms = Enum.map(conversion_names, &safe_to_atom/1)

      case ModelRegistry.find_model_module(mediable_type) do
        {:ok, module} ->
          collection_name = safe_to_atom(media.collection_name)

          module
          |> ModelRegistry.get_model_conversions(collection_name)
          |> Enum.filter(fn %Conversion{name: name} -> name in requested_atoms end)

        :error ->
          Logger.warning(
            "[PhxMediaLibrary] Could not find model module for mediable_type #{inspect(mediable_type)}. " <>
              "Falling back to name-only conversions (no dimensions/quality/format)."
          )

          # Last resort fallback: create minimal Conversion structs.
          # These will have default values (:contain fit, no width/height)
          # which is better than silently doing nothing, but may produce
          # unexpected results. The warning above alerts the developer.
          Enum.map(requested_atoms, &Conversion.new(&1, []))
      end
    end

    # -------------------------------------------------------------------------
    # Model Module Discovery — delegates to ModelRegistry
    # -------------------------------------------------------------------------

    @doc """
    Finds the model module for the given mediable type.

    Delegates to `PhxMediaLibrary.ModelRegistry.find_model_module/1`.
    Kept for backwards compatibility.
    """
    @spec find_model_module(String.t()) :: {:ok, module()} | :error
    defdelegate find_model_module(mediable_type), to: ModelRegistry

    # Safely converts a string to an existing atom, returning the string
    # as-is (converted to atom via String.to_existing_atom) if it exists,
    # or falling back to String.to_atom for known-safe internal values
    # like conversion names that were originally atoms.
    defp safe_to_atom(value) when is_atom(value), do: value

    defp safe_to_atom(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> String.to_atom(value)
    end
  end
end
