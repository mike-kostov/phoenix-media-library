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

  describe "Storage.S3.presigned_upload/3 on a :post disk" do
    test "returns a presigned POST whose policy enforces size, type and key" do
      assert {:ok, %{method: :post, url: url, fields: fields}} =
               S3.presigned_upload(
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
      assert {:ok, %{fields: fields}} = S3.presigned_upload("a/b.jpg", [], @s3)

      refute Map.has_key?(fields, "Content-Type")
      refute Enum.any?(policy_conditions(fields), &match?(["content-length-range" | _], &1))
    end
  end

  describe "PhxMediaLibrary.presigned_upload/3" do
    @describetag :db

    setup do
      disks = Application.get_env(:phx_media_library, :disks)
      on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)

      Application.put_env(
        :phx_media_library,
        :disks,
        disks
        |> Keyword.put(:s3, [adapter: S3] ++ @s3)
        |> Keyword.put(:s3_put, [adapter: S3, direct_upload: :put] ++ @s3)
      )
    end

    test "a :post disk returns a form POST with its policy" do
      assert {:ok, upload} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :documents,
                 filename: "notes.txt",
                 content_type: "text/plain",
                 disk: :s3
               )

      assert %{method: :post, headers: headers, fields: fields, key: key} = upload
      assert headers == %{}
      assert fields["key"] == key
      assert fields["Content-Type"] == "text/plain"
      assert ["eq", "$Content-Type", "text/plain"] in policy_conditions(fields)
    end

    test "a :put disk returns a PUT whose signature covers the content type" do
      assert {:ok, upload} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :documents,
                 filename: "notes.txt",
                 content_type: "text/plain",
                 disk: :s3_put
               )

      assert %{method: :put, url: url, fields: fields, headers: headers, key: key} = upload
      assert fields == %{}
      assert headers == %{"content-type" => "text/plain"}
      assert url =~ "/media-bucket/#{key}?"

      signed_headers = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert "content-type" in String.split(signed_headers["X-Amz-SignedHeaders"], ";")
    end

    test "without :content_type, the type comes from the filename" do
      assert {:ok, %{headers: %{"content-type" => "application/pdf"}}} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :documents,
                 filename: "Report.pdf",
                 disk: :s3_put
               )
    end

    test "a declared size over the limit is refused" do
      # :small_files has max_size: 1_000
      for disk <- [:s3, :s3_put] do
        assert {:error, {:file_too_large, 2_000, 1_000}} =
                 PhxMediaLibrary.presigned_upload(create_test_post(), :small_files,
                   filename: "notes.txt",
                   size: 2_000,
                   disk: disk
                 )
      end

      assert {:ok, _upload} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :small_files,
                 filename: "notes.txt",
                 size: 1_000,
                 disk: :s3_put
               )
    end

    test "limits the POST size to the collection's max_size by default" do
      assert {:ok, %{fields: fields}} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :small_files,
                 filename: "notes.txt",
                 disk: :s3
               )

      assert ["content-length-range", 0, 1_000] in policy_conditions(fields)
    end

    test "an explicit :max_size wins" do
      assert {:ok, %{fields: fields}} =
               PhxMediaLibrary.presigned_upload(create_test_post(), :small_files,
                 filename: "notes.txt",
                 disk: :s3,
                 max_size: 500
               )

      assert ["content-length-range", 0, 500] in policy_conditions(fields)
    end
  end
end
