defmodule PhxMediaLibrary.Storage.S3PresignTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.Storage.S3

  @s3 [
    bucket: "media-bucket",
    region: "eu-central-1",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  ]

  defp policy_conditions(fields) do
    fields
    |> Map.fetch!("Policy")
    |> Base.decode64!()
    |> Jason.decode!()
    |> Map.fetch!("conditions")
  end

  describe "Storage.S3.presigned_upload_url/3" do
    test "returns a presigned POST whose policy enforces size, type and key" do
      assert {:ok, url, fields} =
               S3.presigned_upload_url(
                 "posts/1/uuid/photo.jpg",
                 [content_type: "image/jpeg", content_length_range: {0, 5_000_000}],
                 @s3
               )

      assert url =~ "media-bucket"
      assert fields["key"] == "posts/1/uuid/photo.jpg"
      assert fields["Content-Type"] == "image/jpeg"

      conditions = policy_conditions(fields)
      assert ["content-length-range", 0, 5_000_000] in conditions
      assert ["eq", "$Content-Type", "image/jpeg"] in conditions
      assert Enum.any?(conditions, &(&1 == %{"key" => "posts/1/uuid/photo.jpg"}))
    end

    test "omits conditions that weren't asked for" do
      assert {:ok, _url, fields} = S3.presigned_upload_url("a/b.jpg", [], @s3)

      refute Map.has_key?(fields, "Content-Type")
      refute Enum.any?(policy_conditions(fields), &match?(["content-length-range" | _], &1))
    end
  end

  describe "Storage.S3.stat/3" do
    alias PhxMediaLibrary.FakeS3Client

    setup do
      previous = Application.fetch_env(:ex_aws, :http_client)
      Application.put_env(:ex_aws, :http_client, FakeS3Client)
      FakeS3Client.reset()

      on_exit(fn ->
        case previous do
          {:ok, client} -> Application.put_env(:ex_aws, :http_client, client)
          :error -> Application.delete_env(:ex_aws, :http_client)
        end
      end)
    end

    test "returns the size from HEAD and the first bytes from a ranged GET" do
      FakeS3Client.put_object("posts/1/u/a.txt", String.duplicate("a", 1_500))

      assert {:ok, %{size: 1_500, header: header}} = S3.stat("posts/1/u/a.txt", 512, @s3)
      assert byte_size(header) == 512
      assert FakeS3Client.requests() == [{:head, "posts/1/u/a.txt"}, {:get, "posts/1/u/a.txt"}]
    end

    test "a missing object is :not_found" do
      assert {:error, :not_found} = S3.stat("posts/1/u/ghost.txt", 512, @s3)
    end

    test "an empty object is read without a ranged GET" do
      FakeS3Client.put_object("posts/1/u/empty.txt", "")

      assert {:ok, %{size: 0, header: ""}} = S3.stat("posts/1/u/empty.txt", 512, @s3)
      assert FakeS3Client.requests() == [{:head, "posts/1/u/empty.txt"}]
    end
  end

  describe "PhxMediaLibrary.presigned_upload_url/3" do
    @describetag :db

    setup do
      disks = Application.get_env(:phx_media_library, :disks)
      on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)

      Application.put_env(
        :phx_media_library,
        :disks,
        Keyword.put(disks, :s3, [adapter: S3] ++ @s3)
      )
    end

    test "limits the size to the collection's max_size by default" do
      # :small_files has max_size: 1_000
      assert {:ok, _url, fields, _key} =
               PhxMediaLibrary.presigned_upload_url(create_test_post(), :small_files,
                 filename: "notes.txt",
                 content_type: "text/plain",
                 disk: :s3
               )

      assert ["content-length-range", 0, 1_000] in policy_conditions(fields)
    end

    test "an explicit :max_size wins" do
      assert {:ok, _url, fields, _key} =
               PhxMediaLibrary.presigned_upload_url(create_test_post(), :small_files,
                 filename: "notes.txt",
                 disk: :s3,
                 max_size: 500
               )

      assert ["content-length-range", 0, 500] in policy_conditions(fields)
    end
  end
end
