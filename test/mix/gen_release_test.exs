defmodule Mix.Tasks.PhxMediaLibrary.Gen.ReleaseTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhxMediaLibrary.Gen.Release

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "generates the release module and an executable bin/media_doctor", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Release.run([]) end)

    module = File.read!(Path.join(tmp, "lib/phx_media_library/media_release.ex"))
    assert module =~ "defmodule PhxMediaLibrary.MediaRelease do"
    assert module =~ "PhxMediaLibrary.Doctor.CLI.main(argv)"
    assert module =~ "Ecto.Migrator.with_repo"

    script_path = Path.join(tmp, "rel/overlays/bin/media_doctor")
    script = File.read!(script_path)

    assert script =~
             ~S|exec ./phx_media_library eval "PhxMediaLibrary.MediaRelease.doctor()" "$@"|

    assert File.stat!(script_path).mode |> Bitwise.band(0o111) != 0
  end

  test "asks before overwriting", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Release.run([]) end)
    path = Path.join(tmp, "lib/phx_media_library/media_release.ex")
    File.write!(path, "edited")

    send(self(), {:mix_shell_input, :yes?, false})
    send(self(), {:mix_shell_input, :yes?, false})
    File.cd!(tmp, fn -> Release.run([]) end)

    assert File.read!(path) == "edited"
  end
end
