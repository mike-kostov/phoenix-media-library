# PhxMediaLibrary

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phx_media_library` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phx_media_library, "~> 0.1.0"}
  ]
end
```

## Usage Examples

```elixir
# Initial installation
mix phx_media_library.install

# Run the generated migration
mix ecto.migrate

# Regenerate all thumbnails
mix phx_media_library.regenerate --conversion thumb

# See what orphaned files exist (dry run)
mix phx_media_library.clean

# Actually delete orphaned files
mix phx_media_library.clean --force

# Generate a migration to add a custom field
mix phx_media_library.gen.migration add_blurhash_field
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/phx_media_library>.
