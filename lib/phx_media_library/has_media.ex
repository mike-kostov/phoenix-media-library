defmodule PhxMediaLibrary.HasMedia do
  @moduledoc """
  Adds media association capabilities to an Ecto schema.

  ## Usage

  There are two styles for defining collections and conversions: the
  **declarative DSL** (recommended) and the **function-based** approach.

  ### Declarative DSL — nested style (recommended)

  Nest `convert` calls inside `collection ... do ... end` blocks so it's
  immediately clear which conversions apply to which collections.
  Collections without image content (like `:documents`) omit the `do`
  block — no conversions will run for those uploads.

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        media_collections do
          collection :images, disk: :s3, max_files: 20 do
            convert :thumb, width: 150, height: 150, fit: :cover
            convert :preview, width: 800, quality: 85
            convert :banner, width: 1200, height: 400, fit: :crop
          end

          collection :documents, accepts: ~w(application/pdf)

          collection :avatar, single_file: true, fallback_url: "/images/default.png" do
            convert :thumb, width: 150, height: 150, fit: :cover
          end
        end
      end

  ### Declarative DSL — flat style

  Define collections and conversions in separate blocks. Always use the
  `:collections` option to scope conversions explicitly — without it, a
  conversion runs for **every** collection (including non-image ones like
  documents, which will cause processing errors):

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        media_collections do
          collection :images, disk: :s3, max_files: 20
          collection :documents, accepts: ~w(application/pdf)
          collection :avatar, single_file: true, fallback_url: "/images/default.png"
        end

        media_conversions do
          convert :thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]
          convert :preview, width: 800, quality: 85, collections: [:images]
          convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
        end
      end

  ### Function-based approach

      defmodule MyApp.Post do
        use Ecto.Schema
        use PhxMediaLibrary.HasMedia

        schema "posts" do
          field :title, :string
          has_media()
          timestamps()
        end

        def media_collections do
          [
            collection(:images, disk: :local),
            collection(:documents, accepts: ~w(application/pdf)),
            collection(:avatar, single_file: true)
          ]
        end

        def media_conversions do
          [
            # Always scope conversions to specific collections
            conversion(:thumb, width: 150, height: 150, fit: :cover, collections: [:images, :avatar]),
            conversion(:preview, width: 800, quality: 85, collections: [:images])
          ]
        end
      end

  ## How `has_media()` Works

  The `has_media()` macro injects a polymorphic `has_many :media` association
  into your schema. This enables standard Ecto preloading:

      post = Repo.preload(post, :media)
      post.media  #=> [%PhxMediaLibrary.Media{}, ...]

  Under the hood, the association uses `mediable_id` as the foreign key and
  a `:where` clause to scope results by `mediable_type` (derived from the
  schema's table name).

  You can also define collection-scoped associations:

      schema "posts" do
        has_media()
        has_media(:images)
        has_media(:documents)
      end

  Which enables:

      post = Repo.preload(post, [:media, :images, :documents])
      post.images  #=> only media in the "images" collection

  ## Overriding the Media Type

  By default the polymorphic `mediable_type` is the Ecto table name (e.g.
  `"posts"` for `schema "posts"`). You can override it at the module level:

      use PhxMediaLibrary.HasMedia, media_type: "blog_posts"

  Or override the `__media_type__/0` function:

      def __media_type__, do: "blog_posts"

  ## Collection Options

  - `:disk` - Storage disk to use (default: configured default)
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file in collection (default: false)
  - `:max_files` - Maximum number of files to keep
  - `:max_size` - Maximum file size in bytes (e.g. `10_000_000` for 10 MB)
  - `:fallback_url` - URL to use when collection is empty
  - `:verify_content_type` - Verify file content matches declared MIME type (default: true)

  ## Conversion Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - How to fit the image (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - JPEG/WebP quality (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`)
  - `:collections` - Only apply to specific collections

  """

  alias PhxMediaLibrary.{Collection, Conversion}

  # -------------------------------------------------------------------------
  # __using__ — sets up the caller module
  # -------------------------------------------------------------------------

  defmacro __using__(opts) do
    media_type_override = Keyword.get(opts, :media_type)

    quote do
      import PhxMediaLibrary.HasMedia,
        only: [
          has_media: 0,
          has_media: 1,
          collection: 1,
          collection: 2,
          conversion: 2,
          convert: 2
        ]

      import PhxMediaLibrary.HasMedia.DSL,
        only: [media_collections: 1, media_conversions: 1]

      @before_compile PhxMediaLibrary.HasMedia

      # Store the explicit override (nil if not provided) so we can
      # resolve it in __before_compile__ and has_media() macro.
      Module.put_attribute(__MODULE__, :__phx_media_type_override__, unquote(media_type_override))

      # Accumulators for the declarative DSL. When the developer uses
      # `media_collections do ... end` or `media_conversions do ... end`,
      # each `collection` / `convert` call inside the block appends to these.
      Module.register_attribute(__MODULE__, :__phx_media_collections__, accumulate: true)
      Module.register_attribute(__MODULE__, :__phx_media_conversions__, accumulate: true)

      # Used by nested `collection ... do convert ... end` blocks to
      # auto-scope conversions to the enclosing collection.
      Module.register_attribute(__MODULE__, :__phx_media_current_collection__, [])
      Module.put_attribute(__MODULE__, :__phx_media_current_collection__, nil)

      # Track whether the DSL blocks were used, so we know whether
      # to use the accumulated values or the default empty list.
      Module.put_attribute(__MODULE__, :__phx_media_collections_dsl__, false)
      Module.put_attribute(__MODULE__, :__phx_media_conversions_dsl__, false)

      # Default implementations that can be overridden by the user.
      # The DSL approach works differently — see __before_compile__.
      def media_collections, do: []
      def media_conversions, do: []

      defoverridable media_collections: 0, media_conversions: 0
    end
  end

  # -------------------------------------------------------------------------
  # __before_compile__ — injects __media_type__/0, DSL results, and helpers
  # -------------------------------------------------------------------------

  defmacro __before_compile__(env) do
    override = Module.get_attribute(env.module, :__phx_media_type_override__)
    user_defined_media_type? = Module.defines?(env.module, {:__media_type__, 0}, :def)

    # DSL-collected items (accumulated in reverse order)
    dsl_collections_used? = Module.get_attribute(env.module, :__phx_media_collections_dsl__)
    dsl_conversions_used? = Module.get_attribute(env.module, :__phx_media_conversions_dsl__)

    dsl_collections =
      env.module
      |> Module.get_attribute(:__phx_media_collections__)
      |> Enum.reverse()

    dsl_conversions =
      env.module
      |> Module.get_attribute(:__phx_media_conversions__)
      |> Enum.reverse()

    media_type_def = build_media_type_def(user_defined_media_type?, override)
    helpers = build_helpers()

    dsl_defs =
      build_dsl_defs(
        dsl_collections_used?,
        dsl_conversions_used?,
        dsl_collections,
        dsl_conversions
      )

    quote do
      unquote(media_type_def)
      unquote_splicing(dsl_defs)
      unquote(helpers)
    end
  end

  # Build the __media_type__/0 definition unless the user already defined one.
  defp build_media_type_def(true = _user_defined?, _override), do: nil

  defp build_media_type_def(_user_defined?, override) when not is_nil(override) do
    quote do
      @doc """
      Returns the polymorphic type string used to identify this schema
      in the `mediable_type` column.

      This value was explicitly set via
      `use PhxMediaLibrary.HasMedia, media_type: #{inspect(unquote(override))}`.
      """
      def __media_type__, do: unquote(override)
    end
  end

  defp build_media_type_def(_user_defined?, _override) do
    quote do
      @doc """
      Returns the polymorphic type string used to identify this schema
      in the `mediable_type` column.

      Defaults to the Ecto table name (via `__schema__(:source)`), which
      is the most reliable derivation strategy. For example,
      `MyApp.Post` with `schema "posts"` returns `"posts"`, and
      `MyApp.BlogCategory` with `schema "blog_categories"` returns
      `"blog_categories"`.

      Override this function if you need a custom type string:

          def __media_type__, do: "blog_posts"

      """
      def __media_type__ do
        __MODULE__.__schema__(:source)
      end
    end
  end

  # Build collection/conversion lookup helpers injected into every HasMedia module.
  defp build_helpers do
    quote do
      @doc """
      Get the collection configuration for this model by name.
      """
      def get_media_collection(name) do
        media_collections()
        |> Enum.find(fn %PhxMediaLibrary.Collection{name: n} -> n == name end)
      end

      @doc """
      Get all conversion configurations for this model, optionally filtered
      by collection name.
      """
      def get_media_conversions(collection_name \\ nil) do
        conversions = media_conversions()

        if collection_name do
          Enum.filter(conversions, fn %PhxMediaLibrary.Conversion{collections: cols} ->
            cols == [] or collection_name in cols
          end)
        else
          conversions
        end
      end
    end
  end

  # If the DSL was used, inject media_collections/0 and/or
  # media_conversions/0 that return the accumulated definitions.
  #
  # We use `defoverridable` + `def` to ensure the DSL definition
  # replaces the default empty-list implementation from __using__.
  defp build_dsl_defs(collections_used?, conversions_used?, collections, conversions) do
    List.flatten([
      build_dsl_collections_def(collections_used?, collections),
      build_dsl_conversions_def(conversions_used?, conversions)
    ])
  end

  defp build_dsl_collections_def(true, collections) do
    escaped = Macro.escape(collections)

    quote do
      defoverridable media_collections: 0
      def media_collections, do: unquote(escaped)
    end
  end

  defp build_dsl_collections_def(_, _collections), do: []

  defp build_dsl_conversions_def(true, conversions) do
    escaped = Macro.escape(conversions)

    quote do
      defoverridable media_conversions: 0
      def media_conversions, do: unquote(escaped)
    end
  end

  defp build_dsl_conversions_def(_, _conversions), do: []

  # -------------------------------------------------------------------------
  # has_media() macro — injects has_many inside the schema block
  # -------------------------------------------------------------------------

  @doc """
  Declares that this schema has media associations.

  When called without arguments (`has_media()`), it injects a polymorphic
  `has_many :media` association that references all media items for the
  model regardless of collection.

  When called with a collection name atom (`has_media(:images)`), it injects
  a collection-scoped `has_many` using that name. For example,
  `has_media(:images)` creates `has_many :images` scoped to the `"images"`
  collection.

  This macro **must** be called inside the `schema` block, after the
  `schema "table_name"` declaration so that the table name is available for
  the polymorphic `:where` clause.

  ## Examples

      schema "posts" do
        field :title, :string

        # All media for this model
        has_media()

        # Collection-scoped associations (optional convenience)
        has_media(:images)
        has_media(:documents)
        has_media(:avatar)

        timestamps()
      end

  Then you can preload naturally:

      post = Repo.preload(post, [:media, :images, :avatar])
      post.media     #=> all media items
      post.images    #=> only items in "images" collection
      post.avatar    #=> only items in "avatar" collection

  """
  defmacro has_media(collection_name \\ nil) do
    # We always delegate to __inject_has_many__/3 which runs at module
    # compilation time (inside the schema block's try/after). At that
    # point, both the @__phx_media_type_override__ attribute (set by
    # `use PhxMediaLibrary.HasMedia`) and the @ecto_struct_fields
    # attribute (set by Ecto.Schema.__schema__/5) have been evaluated.
    #
    # Reading attributes at macro expansion time does NOT work because
    # Elixir expands all macros before evaluating Module.put_attribute
    # calls in the module body.
    if collection_name do
      collection_str = to_string(collection_name)

      quote do
        PhxMediaLibrary.HasMedia.__inject_has_many__(
          __MODULE__,
          unquote(collection_name),
          unquote(collection_str)
        )
      end
    else
      quote do
        PhxMediaLibrary.HasMedia.__inject_has_many__(
          __MODULE__,
          :media,
          nil
        )
      end
    end
  end

  @doc false
  # Called at module compilation time from generated code inside the schema
  # block. At this point, both the @__phx_media_type_override__ attribute
  # (from `use PhxMediaLibrary.HasMedia, media_type: "..."`) and the
  # @ecto_struct_fields attribute (from Ecto.Schema.__schema__/5) have been
  # evaluated, so we can read them dynamically and pass them to
  # Ecto.Schema.__has_many__/4.
  def __inject_has_many__(module, assoc_name, collection_str) do
    media_type = resolve_media_type(module)

    opts =
      if collection_str do
        [
          foreign_key: :mediable_id,
          where: [mediable_type: media_type, collection_name: collection_str],
          defaults: [mediable_type: media_type, collection_name: collection_str]
        ]
      else
        [
          foreign_key: :mediable_id,
          where: [mediable_type: media_type],
          defaults: [mediable_type: media_type]
        ]
      end

    Ecto.Schema.__has_many__(module, assoc_name, PhxMediaLibrary.Media, opts)
  end

  @doc false
  # Resolves the media type string for a module at compilation time.
  # Priority: 1) explicit override, 2) Ecto schema source, 3) module name
  def resolve_media_type(module) do
    # Priority 1: explicit override from `use PhxMediaLibrary.HasMedia, media_type: "..."`
    case Module.get_attribute(module, :__phx_media_type_override__) do
      override when is_binary(override) ->
        override

      _ ->
        # Priority 2: Ecto schema source (table name) from @ecto_struct_fields
        resolve_source_from_ecto_fields(module)
    end
  end

  @doc false
  def resolve_source_from_ecto_fields(module) do
    case Module.get_attribute(module, :ecto_struct_fields) do
      fields when is_list(fields) ->
        Enum.find_value(fields, fn
          {:__meta__, %{source: source}} when is_binary(source) -> source
          _ -> nil
        end) || fallback_module_name(module)

      _ ->
        fallback_module_name(module)
    end
  end

  defp fallback_module_name(module) do
    # Fallback: underscored module name (without naive pluralization)
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  # -------------------------------------------------------------------------
  # Helper functions for building collection/conversion configs
  # -------------------------------------------------------------------------

  @doc """
  Define a media collection.

  Can be used in two ways:

  1. Inside a `media_collections do ... end` block (DSL style — the
     collection is automatically registered):

         media_collections do
           collection :images, disk: :s3
           collection :avatar, single_file: true
         end

  2. Inside a `media_collections/0` function (function style — return a
     list of collections):

         def media_collections do
           [
             collection(:images, disk: :s3),
             collection(:avatar, single_file: true)
           ]
         end

  ## Options

  - `:disk` - Storage disk to use
  - `:accepts` - List of accepted MIME types
  - `:single_file` - Only keep one file (default: false)
  - `:max_files` - Maximum number of files
  - `:fallback_url` - URL when collection is empty
  - `:fallback_path` - Path when collection is empty

  """
  def collection(name, opts \\ []) do
    Collection.new(name, opts)
  end

  @doc """
  Define a media conversion (function-style).

  Used inside a `media_conversions/0` function return list:

      def media_conversions do
        [
          conversion(:thumb, width: 150, height: 150, fit: :cover),
          conversion(:preview, width: 800, quality: 85)
        ]
      end

  ## Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - Resize strategy (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - Output quality for JPEG/WebP (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:original`)
  - `:collections` - Only apply to these collections (default: all)
  - `:queued` - Process asynchronously (default: true)

  """
  def conversion(name, opts) do
    Conversion.new(name, opts)
  end

  @doc """
  Define a media conversion (DSL-style).

  Used inside a `media_conversions do ... end` block:

      media_conversions do
        convert :thumb, width: 150, height: 150, fit: :cover
        convert :preview, width: 800, quality: 85
        convert :banner, width: 1200, height: 400, fit: :crop, collections: [:images]
      end

  This is an alias for `conversion/2` — both produce identical
  `PhxMediaLibrary.Conversion` structs. The `convert` name reads more
  naturally in the declarative DSL context.

  ## Options

  - `:width` - Target width in pixels
  - `:height` - Target height in pixels
  - `:fit` - Resize strategy (`:contain`, `:cover`, `:fill`, `:crop`)
  - `:quality` - Output quality for JPEG/WebP (1-100)
  - `:format` - Output format (`:jpg`, `:png`, `:webp`, `:original`)
  - `:collections` - Only apply to these collections (default: all)
  - `:queued` - Process asynchronously (default: true)

  """

  def convert(name, opts) do
    Conversion.new(name, opts)
  end
end
