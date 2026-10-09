defmodule PhxMediaLibrary.ColocatedHooksTest do
  # Spec 02, B13: LiveView writes phoenix-colocated/phx_media_library/index.js,
  # which apps import the hooks from, only for a project that runs its
  # compiler.
  use ExUnit.Case, async: true

  test "the library runs LiveView's compiler when LiveView is present" do
    assert :phx_media_library_hooks in PhxMediaLibrary.MixProject.project()[:compilers]
    assert Code.ensure_loaded?(Mix.Tasks.Compile.PhoenixLiveView)
  end
end
