defmodule PhxMediaLibrary.MediaLiveFlowTest do
  # MediaLive driven through a LiveView: upload, list, delete.
  use PhxMediaLibrary.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, MediaLiveHost}

  @moduletag :db
  @endpoint PhxMediaLibrary.TestEndpoint

  setup do
    on_exit(fn -> for media <- TestRepo.all(Media), do: Media.delete_files(media) end)
    %{post: create_test_post()}
  end

  defp mount(post, collection, opts \\ %{}) do
    {:ok, view, html} =
      live_isolated(build_conn(), MediaLiveHost,
        session: %{
          "post" => post,
          "collection" => collection,
          "test_pid" => self(),
          "opts" => opts
        }
      )

    {view, html}
  end

  defp upload(view, files) do
    entries = for {name, content, type} <- files, do: %{name: name, content: content, type: type}
    input = file_input(view, "#post-media-upload-form", :media_upload_post_media, entries)
    results = for {name, _, _} <- files, do: render_upload(input, name)
    {input, results}
  end

  test "lists the record's media", %{post: post} do
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)
    {:ok, media} = post |> PhxMediaLibrary.add(txt) |> PhxMediaLibrary.to_collection(:documents)

    {_view, html} = mount(post, :documents)
    assert html =~ ~s(id="media-#{media.id}")
  end

  test "uploads files into the collection and tells the parent", %{post: post} do
    {view, _html} = mount(post, :documents)
    upload(view, [{"a.txt", "aaa", "text/plain"}, {"b.txt", "bbb", "text/plain"}])

    html = view |> form("#post-media-upload-form") |> render_submit()

    assert_receive {:media_live, {:uploaded, :documents, [_, _] = uploaded}}
    names = uploaded |> Enum.map(&Media.original_file_name/1) |> Enum.sort()
    assert names == ["a.txt", "b.txt"]

    assert Enum.map(PhxMediaLibrary.get_media(post, :documents), & &1.id) |> Enum.sort() ==
             uploaded |> Enum.map(& &1.id) |> Enum.sort()

    for media <- uploaded, do: assert(html =~ ~s(id="media-#{media.id}"))
  end

  test "refuses files the collection doesn't accept", %{post: post} do
    {view, _html} = mount(post, :documents)
    {_input, [result]} = upload(view, [{"photo.png", "not really", "image/png"}])

    assert {:error, [[_ref, :not_accepted]]} = result
    assert PhxMediaLibrary.get_media(post, :documents) == []
  end

  # Spec 02, B7: submitting with a refused file crashed the LiveView.
  test "a file LiveView refused is dropped on submit, and the page stays up", %{post: post} do
    {view, _html} = mount(post, :small_files)

    upload(view, [
      {"ok.txt", "fine", "text/plain"},
      {"big.txt", String.duplicate("x", 2_000), "text/plain"}
    ])

    html = view |> form("#post-media-upload-form") |> render_submit()

    assert Process.alive?(view.pid)
    refute html =~ "big.txt"
    # LiveView holds the valid file back while a refused one is listed; it
    # stays for the next submit.
    assert html =~ "ok.txt"
    assert PhxMediaLibrary.get_media(post, :small_files) == []
  end

  # Spec 02, B8: the parent heard nothing when one of the files failed.
  test "the parent hears of the saved files when another one fails", %{post: post} do
    {view, _html} = mount(post, :documents)

    upload(view, [
      {"ok.txt", "fine", "text/plain"},
      {"fake.txt", "MZ" <> String.duplicate("x", 100), "text/plain"}
    ])

    view |> form("#post-media-upload-form") |> render_submit()

    assert_receive {:media_live, {:uploaded, :documents, [saved]}}
    assert Media.original_file_name(saved) == "ok.txt"
  end

  test "deletes the record's media and tells the parent", %{post: post} do
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)
    {:ok, media} = post |> PhxMediaLibrary.add(txt) |> PhxMediaLibrary.to_collection(:documents)
    {view, _html} = mount(post, :documents)

    view |> element(~s([phx-click="delete_media"][phx-value-id="#{media.id}"])) |> render_click()

    assert_receive {:media_live, {:deleted, :documents, %Media{id: id}}}
    assert id == media.id
    refute TestRepo.get(Media, media.id)
    refute render(view) =~ ~s(id="media-#{media.id}")
  end

  # ADR-018: a client-supplied ID only deletes this component's media.
  test "won't delete another record's media", %{post: post} do
    txt = create_temp_file("notes", "notes.txt")
    on_exit(fn -> File.rm(txt) end)

    {:ok, other} =
      create_test_post() |> PhxMediaLibrary.add(txt) |> PhxMediaLibrary.to_collection(:documents)

    {view, _html} = mount(post, :documents)

    view |> with_target("#post-media") |> render_hook("delete_media", %{"id" => other.id})

    assert TestRepo.get(Media, other.id)
    refute_received {:media_live, {:deleted, _, _}}
  end

  test "cancels a pending upload", %{post: post} do
    {view, _html} = mount(post, :documents)
    {input, _} = upload(view, [{"a.txt", "aaa", "text/plain"}])
    [%{"ref" => ref} | _] = input.entries

    view |> with_target("#post-media") |> render_hook("cancel_upload", %{"ref" => ref})
    view |> form("#post-media-upload-form") |> render_submit()

    refute_received {:media_live, {:uploaded, _, [_ | _]}}
    assert PhxMediaLibrary.get_media(post, :documents) == []
  end
end
