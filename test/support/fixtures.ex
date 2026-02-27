defmodule PhxMediaLibrary.Fixtures do
  @moduledoc """
  Test fixtures for PhxMediaLibrary tests.
  """

  alias PhxMediaLibrary.{Media, TestRepo}

  @fixtures_path Path.expand("fixtures", __DIR__)

  @doc """
  Returns the path to a test fixture file.
  """
  def fixture_path(filename) do
    Path.join(@fixtures_path, filename)
  end

  @doc """
  Creates a temporary file with the given content.
  Returns the path to the temporary file.
  """
  def create_temp_file(content, filename \\ "test_file.txt") do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phx_media_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    path
  end

  @doc """
  Creates a temporary image file.
  Returns the path to the temporary file.
  """
  def create_temp_image(opts \\ []) do
    width = Keyword.get(opts, :width, 100)
    height = Keyword.get(opts, :height, 100)
    color = Keyword.get(opts, :color, "red")
    format = Keyword.get(opts, :format, :png)

    filename = "test_image_#{:erlang.unique_integer([:positive])}.#{format}"
    path = Path.join(System.tmp_dir!(), filename)

    # Create a simple colored image using Image library
    case Image.new(width, height, color: color) do
      {:ok, image} ->
        Image.write!(image, path)
        path

      {:error, _reason} ->
        # Fallback: create a minimal valid PNG
        create_minimal_png(path)
        path
    end
  end

  @doc """
  Creates a minimal valid PNG file.
  """
  def create_minimal_png(path) do
    # Minimal 1x1 red PNG
    png_data =
      <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
        0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4, 0xEF, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82>>

    File.write!(path, png_data)
  end

  @doc """
  Creates a test post model for media association tests.
  """
  def create_test_post(attrs \\ %{}) do
    default_attrs = %{
      id: Ecto.UUID.generate(),
      title: "Test Post"
    }

    struct(PhxMediaLibrary.TestPost, Map.merge(default_attrs, attrs))
  end

  @doc """
  Creates a media record directly in the database.
  """
  def create_media(attrs \\ %{}) do
    default_attrs = %{
      uuid: Ecto.UUID.generate(),
      collection_name: "default",
      name: "test-file",
      file_name: "test-file.jpg",
      mime_type: "image/jpeg",
      disk: "memory",
      size: 1024,
      mediable_type: "posts",
      mediable_id: Ecto.UUID.generate(),
      custom_properties: %{},
      generated_conversions: %{},
      responsive_images: %{},
      order_column: 1
    }

    attrs = Map.merge(default_attrs, Enum.into(attrs, %{}))

    %Media{}
    |> Media.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Cleans up temporary test files.
  """
  def cleanup_temp_files(paths) when is_list(paths) do
    Enum.each(paths, &File.rm/1)
  end

  def cleanup_temp_files(path) when is_binary(path) do
    File.rm(path)
  end

  @doc """
  Sets up a temporary directory for file storage tests.
  Returns the path and a cleanup function.
  """
  def setup_temp_storage do
    dir = Path.join(System.tmp_dir!(), "phx_media_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_cleanup = fn ->
      File.rm_rf!(dir)
    end

    {dir, on_cleanup}
  end
end
