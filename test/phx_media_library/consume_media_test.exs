defmodule PhxMediaLibrary.ConsumeMediaTest do
  use PhxMediaLibrary.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, UploadLive}

  @moduletag :db
  @endpoint PhxMediaLibrary.TestEndpoint

  # :small_files accepts text/plain up to 1_000 bytes.
  defp upload_and_save(files) do
    post = create_test_post()

    {:ok, view, _html} =
      live_isolated(build_conn(), UploadLive,
        session: %{"post" => post, "collection" => :small_files, "test_pid" => self()}
      )

    entries =
      for {name, content} <- files, do: %{name: name, content: content, type: "text/plain"}

    input = file_input(view, "form", :files, entries)
    for {name, _content} <- files, do: render_upload(input, name)

    view |> element("form") |> render_submit()
    assert_receive {:consumed, result}
    on_exit(fn -> delete_saved(result) end)
    result
  end

  defp delete_saved({:ok, saved}), do: Enum.each(saved, &Media.delete_files/1)
  defp delete_saved({:error, {:partial, saved, _failed}}), do: delete_saved({:ok, saved})

  test "every entry saved: {:ok, media} and :media_added, as before" do
    assert {:ok, [_, _] = saved} = upload_and_save([{"a.txt", "aaa"}, {"b.txt", "bbb"}])
    assert_receive {:media_added, ^saved}
    refute_received {:media_error, _}
  end

  test "some entries failing: the saved media and each failure's reason" do
    result =
      upload_and_save([
        {"a.txt", "aaa"},
        {"big.txt", String.duplicate("x", 2_000)},
        {"b.txt", "bbb"}
      ])

    assert {:error, {:partial, saved, [{entry, reason}]}} = result

    assert saved |> Enum.map(& &1.metadata["original_file_name"]) |> Enum.sort() == [
             "a.txt",
             "b.txt"
           ]

    assert entry.client_name == "big.txt"
    assert {:file_too_large, 2_000, 1_000} = reason

    assert_receive {:media_added, ^saved}
    assert_receive {:media_error, {:partial, ^saved, [{_entry, _reason}]}}
  end

  test "every entry failing: {:error, {:partial, [], failed}}" do
    assert {:error, {:partial, [], [_failure]}} =
             upload_and_save([{"big.txt", String.duplicate("x", 2_000)}])

    refute_received {:media_added, _}
    assert_receive {:media_error, {:partial, [], [_failure]}}
  end
end
