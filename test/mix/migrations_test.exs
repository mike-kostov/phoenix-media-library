defmodule Mix.Tasks.PhxMediaLibrary.MigrationsTest do
  # Spec 02, C3: the media table's indexes.
  use PhxMediaLibrary.DataCase, async: false

  alias Ecto.Migration.Runner
  alias Mix.Tasks.PhxMediaLibrary.{Gen, Install}
  alias PhxMediaLibrary.TestRepo, as: Repo

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp migration(tmp, pattern) do
    [path] = Path.wildcard(Path.join([tmp, "priv/repo/migrations", pattern]))
    File.read!(path)
  end

  @tag :tmp_dir
  test "new installs get the lean index set", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Install.run([]) end)
    content = migration(tmp, "*_create_media_table.exs")

    assert content =~ "create unique_index(:media, [:uuid])"
    assert content =~ "create index(:media, [:mediable_type, :mediable_id, :collection_name])"
    assert content =~ ~s|where: "deleted_at IS NOT NULL"|
    refute content =~ "create index(:media, [:mediable_type, :mediable_id])\n"
    refute content =~ "[:collection_name])"
    refute content =~ "[:checksum]"
  end

  @tag :tmp_dir
  test "gen.migration --indexes writes the upgrade for existing apps", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Gen.Migration.run(["--indexes"]) end)
    content = migration(tmp, "*_lean_media_indexes.exs")

    assert content =~ "@disable_ddl_transaction true"
    assert content =~ "concurrently: concurrently"
    assert content =~ "drop_if_exists index(:media, [:checksum]"
    assert content =~ ~s|where: "deleted_at IS NOT NULL"|
  end

  # Spec 02, F6.
  @tag :tmp_dir
  test "new installs get the processing columns", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Install.run([]) end)
    content = migration(tmp, "*_create_media_table.exs")

    for column <- ~w(processing_started_at processing_finished_at processing_failed_at),
        do: assert(content =~ "add :#{column}, :utc_datetime")

    assert content =~ "add :processing_error, :text"
  end

  @tag :tmp_dir
  test "gen.migration --processing-status writes the 0.10 upgrade", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Gen.Migration.run(["--processing-status", "--table", "attachments"]) end)
    content = migration(tmp, "*_add_media_processing_status.exs")

    assert content =~ "alter table(:attachments)"
    assert content =~ "ALTER TABLE attachments ALTER COLUMN processing_finished_at DROP DEFAULT"
  end

  # Spec 02, F10: the install migration runs on Postgres and on SQLite. The
  # upgrades (--indexes, --processing-status) run on both too: the test
  # database applies them over a 0.9 media table before every run.
  @tag :db
  @tag :tmp_dir
  test "the install migration runs on this database", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Install.run(["--table", "media_probe"]) end)

    [{module, _}] =
      tmp
      |> migration("*_create_media_probe_table.exs")
      |> String.replace(~r/defmodule \S+\.Migrations\./, "defmodule ProbeMigrations.")
      |> Code.compile_string()

    Runner.run(Repo, Repo.config(), 1, module, :forward, :change, :up, log: false)

    %{columns: columns} = Repo.query!("SELECT * FROM media_probe LIMIT 0")
    assert "processing_finished_at" in columns
    assert "mediable_id" in columns
  end

  @tag :tmp_dir
  test "--table names the table", %{tmp_dir: tmp} do
    File.cd!(tmp, fn -> Gen.Migration.run(["--indexes", "--table", "attachments"]) end)
    assert migration(tmp, "*_lean_media_indexes.exs") =~ "index(:attachments, [:checksum]"
  end

  @tag :db
  @tag :postgres
  test "the upgrade leaves the test database with the lean set" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'media' ORDER BY indexname")

    assert List.flatten(rows) == [
             "media_deleted_at_partial_index",
             "media_mediable_type_mediable_id_collection_name_index",
             "media_pkey",
             "media_uuid_index"
           ]
  end

  @tag :db
  @tag :sqlite
  test "on SQLite, the upgrade leaves the lean set too" do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'media' " <>
          "AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name"
      )

    assert List.flatten(rows) == [
             "media_deleted_at_partial_index",
             "media_mediable_type_mediable_id_collection_name_index",
             "media_uuid_index"
           ]
  end

  @tag :db
  @tag :sqlite
  test "on SQLite, get_media reads through an index" do
    query =
      PhxMediaLibrary.media_query(%PhxMediaLibrary.TestPost{id: Ecto.UUID.generate()}, :images)

    {sql, params} = Repo.to_sql(:all, query)
    %{rows: plan} = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params)

    assert plan |> List.flatten() |> Enum.join("\n") =~
             "media_mediable_type_mediable_id_collection_name_index"
  end

  @tag :db
  @tag :postgres
  test "get_media still reads through an index" do
    query =
      PhxMediaLibrary.media_query(%PhxMediaLibrary.TestPost{id: Ecto.UUID.generate()}, :images)

    {sql, params} = Repo.to_sql(:all, query)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL enable_seqscan = off")
      %{rows: plan} = Repo.query!("EXPLAIN " <> sql, params)

      assert plan |> List.flatten() |> Enum.join("\n") =~
               "media_mediable_type_mediable_id_collection_name_index"
    end)
  end
end
