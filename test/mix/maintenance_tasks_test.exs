defmodule Mix.Tasks.PhxMediaLibrary.MaintenanceTasksTest do
  # The tasks are wrappers over PhxMediaLibrary.Doctor; these check the
  # wiring and the output.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias Mix.Tasks.PhxMediaLibrary.{PurgeDeleted, Stats}
  alias PhxMediaLibrary.Media
  alias PhxMediaLibrary.TestRepo, as: Repo

  @moduletag :db

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  test "stats prints the collection and disk tables" do
    create_media(%{
      collection_name: "images",
      mediable_type: "posts",
      disk: "memory",
      size: 1_000
    })

    Stats.run(["--type", "posts"])

    out = output()
    assert out =~ "PhxMediaLibrary Storage Stats"
    assert out =~ "images"
    assert out =~ "memory"
  end

  test "purge_deleted --dry-run lists, --yes purges" do
    previous = Application.fetch_env(:phx_media_library, :soft_deletes)
    Application.put_env(:phx_media_library, :soft_deletes, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phx_media_library, :soft_deletes, value)
        :error -> Application.delete_env(:phx_media_library, :soft_deletes)
      end
    end)

    long_ago = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.truncate(:second)
    media = create_media(%{disk: "memory", deleted_at: long_ago})

    PurgeDeleted.run(["--dry-run"])
    assert output() =~ "Dry run, no items were deleted."
    assert Repo.get(Media, media.id)

    PurgeDeleted.run(["--yes"])
    assert output() =~ "Purge complete!"
    refute Repo.get(Media, media.id)
  end
end
