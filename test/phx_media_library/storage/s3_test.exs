defmodule PhxMediaLibrary.Storage.S3Test do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Ministack, Storage.S3}

  @moduletag :s3

  setup do
    # A fresh prefix per test: the container and its bucket outlive runs.
    %{prefix: "tests/#{Ecto.UUID.generate()}", s3: Ministack.disk_opts()}
  end

  describe "against the container" do
    test "put, exists?, get and delete", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/a.txt"

      assert :ok = S3.put(path, "hello", s3)
      assert S3.exists?(path, s3)
      assert {:ok, "hello"} = S3.get(path, s3)
      assert :ok = S3.delete(path, s3)
      refute S3.exists?(path, s3)
      assert :ok = S3.delete(path, s3)
    end

    test "a streamed upload of several parts arrives whole", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/big.bin"
      chunk = :binary.copy("x", 64 * 1024)
      chunks = List.duplicate(chunk, 90)

      assert :ok = S3.put(path, {:stream, chunks}, s3)
      assert {:ok, %{size: size}} = S3.stat(path, 16, s3)
      assert size == 90 * 64 * 1024
    end

    test "a streamed upload smaller than one part arrives whole", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/small.txt"

      assert :ok = S3.put(path, {:stream, ["hello ", "world"]}, s3)
      assert {:ok, "hello world"} = S3.get(path, s3)
    end

    test "an empty streamed upload stores an empty object", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/empty.bin"

      assert :ok = S3.put(path, {:stream, []}, s3)
      assert {:ok, ""} = S3.get(path, s3)
    end

    test "uploads send no ACL unless the disk sets one", %{prefix: prefix, s3: s3} do
      PhxMediaLibrary.RecordingS3Client.record_to(self())
      on_exit(fn -> PhxMediaLibrary.RecordingS3Client.record_to(nil) end)

      :ok = S3.put("#{prefix}/a.txt", "a", s3)
      :ok = S3.put("#{prefix}/b.txt", {:stream, ["b"]}, s3)
      assert upload_acls() == [nil, nil]

      s3 = Keyword.put(s3, :acl, "public-read")
      :ok = S3.put("#{prefix}/c.txt", "c", s3)
      :ok = S3.put("#{prefix}/d.txt", {:stream, ["d"]}, s3)
      assert upload_acls() == ["public-read", "public-read"]
    end

    test "stat returns the size and the first bytes", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/a.txt"
      :ok = S3.put(path, String.duplicate("a", 1_500), s3)

      assert {:ok, %{size: 1_500, header: header}} = S3.stat(path, 512, s3)
      assert header == String.duplicate("a", 512)
    end

    test "stat of a missing object is :not_found", %{prefix: prefix, s3: s3} do
      assert {:error, :not_found} = S3.stat("#{prefix}/ghost.txt", 512, s3)
    end

    test "stat of an empty object", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/empty.txt"
      :ok = S3.put(path, "", s3)

      assert {:ok, %{size: 0, header: ""}} = S3.stat(path, 512, s3)
    end

    test "a public URL follows the endpoint", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/public.txt"
      :ok = S3.put(path, "public", s3)

      url = S3.url(path, s3)
      assert url == "#{s3[:endpoint]}/#{s3[:bucket]}/#{path}"
      assert %{status: 200, body: "public"} = Req.get!(url, retry: false)
    end

    test "a signed URL downloads a private object", %{prefix: prefix, s3: s3} do
      path = "#{prefix}/a.txt"
      :ok = S3.put(path, "secret", s3)

      url = S3.url(path, Keyword.put(s3, :signed, true))
      assert url =~ Keyword.fetch!(s3, :endpoint)
      assert %{status: 200, body: "secret"} = Req.get!(url, retry: false)
    end

    test "a presigned POST accepts a file within the limit and rejects a bigger one",
         %{prefix: prefix, s3: s3} do
      path = "#{prefix}/upload.txt"

      {:ok, %{method: :post, url: url, fields: fields}} =
        S3.presigned_upload(
          path,
          [content_type: "text/plain", content_length_range: {0, 10}],
          Keyword.put(s3, :direct_upload, :post)
        )

      assert url =~ Keyword.fetch!(s3, :endpoint)
      assert post_upload(url, fields, "a" |> String.duplicate(100)).status == 400
      refute S3.exists?(path, s3)

      assert post_upload(url, fields, "tiny").status in 200..299
      assert {:ok, "tiny"} = S3.get(path, s3)
    end
  end

  describe "media on an S3 disk, end to end" do
    @describetag :db

    setup :use_s3_disk

    test "an added file is stored whole, with its checksum", %{s3: s3} do
      path = create_temp_file("plain notes, stored on S3", "notes.txt")
      on_exit(fn -> File.rm(path) end)

      {:ok, media} =
        create_test_post()
        |> PhxMediaLibrary.add(path)
        |> PhxMediaLibrary.to_collection(:documents, disk: :s3)

      stored = PhxMediaLibrary.PathGenerator.relative_path(media, nil)
      assert {:ok, "plain notes, stored on S3"} = S3.get(stored, s3)

      assert media.checksum ==
               :sha256 |> :crypto.hash("plain notes, stored on S3") |> Base.encode16(case: :lower)
    end
  end

  describe "a direct upload, end to end" do
    @describetag :db

    setup :use_s3_disk

    test "uploads with the presigned POST and completes into media", %{s3: s3} do
      post = create_test_post()
      put_s3_disk(Keyword.put(s3, :direct_upload, :post))

      {:ok, %{method: :post, url: url, fields: fields, key: key}} =
        PhxMediaLibrary.presigned_upload(post, :documents,
          filename: "notes.txt",
          content_type: "text/plain",
          disk: :s3
        )

      assert post_upload(url, fields, "plain notes").status in 200..299
      assert_completes(post, key, s3)
    end

    # :generic disks, like the container's, upload with PUT by default.
    test "uploads with the presigned PUT and completes into media", %{s3: s3} do
      post = create_test_post()

      {:ok, %{method: :put, url: url, headers: headers, key: key}} =
        PhxMediaLibrary.presigned_upload(post, :documents,
          filename: "notes.txt",
          size: byte_size("plain notes"),
          disk: :s3
        )

      assert Req.put!(url, body: "plain notes", headers: headers, retry: false).status == 200
      assert_completes(post, key, s3)
    end
  end

  defp assert_completes(post, key, s3) do
    assert {:ok, media} =
             PhxMediaLibrary.complete_external_upload(post, :documents, key,
               filename: "notes.txt",
               disk: :s3
             )

    assert media.size == byte_size("plain notes")
    assert media.mime_type == "text/plain"
    assert S3.exists?(key, s3)
  end

  # The ACL header of each upload request seen so far: a single PUT, or the
  # request that starts a multipart upload.
  defp upload_acls(acc \\ []) do
    receive do
      {:s3_request, method, url, headers} ->
        if (method == :put and not String.contains?(url, "partNumber=")) or
             (method == :post and String.contains?(url, "?uploads")) do
          acl =
            Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "x-amz-acl", do: v end)

          upload_acls([acl | acc])
        else
          upload_acls(acc)
        end
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp use_s3_disk(%{s3: s3}) do
    disks = Application.get_env(:phx_media_library, :disks)
    on_exit(fn -> Application.put_env(:phx_media_library, :disks, disks) end)
    put_s3_disk(s3)
  end

  defp put_s3_disk(s3) do
    disks = Application.get_env(:phx_media_library, :disks)
    Application.put_env(:phx_media_library, :disks, Keyword.put(disks, :s3, [adapter: S3] ++ s3))
  end

  defp post_upload(url, fields, content) do
    Req.post!(url,
      form_multipart: Enum.to_list(fields) ++ [file: {content, filename: "upload.txt"}],
      retry: false
    )
  end
end
