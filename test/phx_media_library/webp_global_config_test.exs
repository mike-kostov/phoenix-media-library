defmodule PhxMediaLibrary.WebpGlobalConfigTest do
  # Spec 02, B3: the global `webp:` takes `true` and `false`, as documented.
  use ExUnit.Case, async: false

  alias PhxMediaLibrary.Config

  setup do
    previous = Application.fetch_env(:phx_media_library, :webp)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :webp, value)
        :error -> Application.delete_env(:phx_media_library, :webp)
      end
    end)
  end

  test "webp: true turns WebP on" do
    Application.put_env(:phx_media_library, :webp, true)
    assert Config.resolve_webp(nil)[:enabled] == true
    assert Config.resolve_webp(false)[:enabled] == false
  end

  test "webp: false turns it off; a collection can still turn it on" do
    Application.put_env(:phx_media_library, :webp, false)
    assert Config.resolve_webp(nil)[:enabled] == false
    assert Config.resolve_webp(true)[:enabled] == true
  end

  test "the keyword form is unchanged" do
    Application.put_env(:phx_media_library, :webp, quality: 70)
    assert Config.resolve_webp(nil)[:enabled] == false
    assert Config.resolve_webp(true)[:quality] == 70
  end
end
