defmodule PhxMediaLibrary.ModelRegistry do
  @moduledoc """
  Discovers and caches the Ecto schema module for a given `mediable_type` string.

  This is the inverse of `HasMedia.__media_type__/0` — given a string like
  `"posts"`, it finds the module (e.g. `MyApp.Post`) that declared
  `use PhxMediaLibrary.HasMedia` and whose `__media_type__/0` returns that
  string.

  ## Lookup Strategy

  1. Check the explicit registry in application config (`:model_registry`)
  2. Scan all loaded modules that export `__media_type__/0`

  Results are cached in `:persistent_term` for fast repeated lookups.

  ## Explicit Registry

  For production deployments where module scanning is undesirable, you can
  configure an explicit mapping:

      config :phx_media_library,
        model_registry: %{
          "posts" => MyApp.Post,
          "users" => MyApp.User
        }

  """

  @doc """
  Finds the Ecto schema module that corresponds to the given `mediable_type`.

  Returns `{:ok, module}` on success, or `:error` if no module could be found.

  ## Examples

      iex> PhxMediaLibrary.ModelRegistry.find_model_module("posts")
      {:ok, MyApp.Post}

      iex> PhxMediaLibrary.ModelRegistry.find_model_module("unknown")
      :error

  """
  @spec find_model_module(String.t()) :: {:ok, module()} | :error
  def find_model_module(mediable_type) do
    cache_key = {__MODULE__, :model_lookup, mediable_type}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found ->
        result = do_find_model_module(mediable_type)

        case result do
          {:ok, module} ->
            :persistent_term.put(cache_key, module)
            {:ok, module}

          :error ->
            :error
        end

      module ->
        {:ok, module}
    end
  end

  @doc """
  Returns the conversions defined on `module` for the given `collection_name`.

  Tries `get_media_conversions/1` first (which filters by collection), then
  falls back to `media_conversions/0` (unfiltered list). Returns `[]` if the
  module doesn't define either function.

  ## Examples

      iex> PhxMediaLibrary.ModelRegistry.get_model_conversions(MyApp.Post, :images)
      [%PhxMediaLibrary.Conversion{name: :thumb, ...}, ...]

  """
  @spec get_model_conversions(module(), atom()) :: [PhxMediaLibrary.Conversion.t()]
  def get_model_conversions(module, collection_name) do
    cond do
      function_exported?(module, :get_media_conversions, 1) ->
        module.get_media_conversions(collection_name)

      function_exported?(module, :media_conversions, 0) ->
        module.media_conversions()

      true ->
        []
    end
  end

  # -- Private ----------------------------------------------------------------

  defp do_find_model_module(mediable_type) do
    # Strategy 1: Check explicit registry in config
    registry = Application.get_env(:phx_media_library, :model_registry, %{})

    case Map.get(registry, mediable_type) do
      nil ->
        # Strategy 2: Scan loaded modules. In mix tasks and dev (interactive
        # mode) schemas load lazily, so on a miss load every application's
        # modules and scan once more.
        with :error <- scan_for_model_module(mediable_type) do
          load_application_modules()
          scan_for_model_module(mediable_type)
        end

      module when is_atom(module) ->
        {:ok, module}
    end
  end

  defp load_application_modules do
    for {app, _desc, _vsn} <- :application.loaded_applications(),
        {:ok, modules} <- [:application.get_key(app, :modules)],
        module <- modules do
      Code.ensure_loaded(module)
    end
  end

  defp scan_for_model_module(mediable_type) do
    # Look through all loaded modules for one that has __media_type__/0
    # returning the matching type string.
    result =
      :code.all_loaded()
      |> Enum.find_value(fn {module, _path} ->
        if function_exported?(module, :__media_type__, 0) do
          try do
            if module.__media_type__() == mediable_type do
              module
            end
          rescue
            _ -> nil
          end
        end
      end)

    case result do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
