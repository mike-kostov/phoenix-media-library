defmodule PhxMediaLibrary.Storage.S3ProvidersTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Storage.S3

  doctest S3

  @keys [access_key_id: "key", secret_access_key: "secret"]

  describe "options/1 presets" do
    test ":aws is the default: POST uploads, path-style, no ACL" do
      opts = S3.options([bucket: "media"] ++ @keys)

      assert opts[:provider] == :aws
      assert opts[:direct_upload] == :post
      assert opts[:addressing] == :path
      refute Keyword.has_key?(opts, :acl)
      refute Keyword.has_key?(opts, :endpoint)
    end

    test ":r2 builds its endpoint from account_id and uses the auto region" do
      opts = S3.options([provider: :r2, account_id: "abc123", bucket: "media"] ++ @keys)

      assert opts[:endpoint] == "https://abc123.r2.cloudflarestorage.com"
      assert opts[:region] == "auto"
      assert opts[:direct_upload] == :put
      assert opts[:addressing] == :path
      refute Keyword.has_key?(opts, :acl)
    end

    test ":generic uses PUT uploads" do
      opts = S3.options(provider: :generic, endpoint: "http://localhost:9000", bucket: "m")

      assert opts[:direct_upload] == :put
      assert opts[:addressing] == :path
    end

    test "disk options override the preset" do
      opts =
        S3.options(
          provider: :r2,
          account_id: "abc123",
          endpoint: "https://abc123.eu.r2.cloudflarestorage.com",
          region: "us-east-1",
          addressing: :virtual_host,
          direct_upload: :post,
          acl: "public-read",
          bucket: "media"
        )

      assert opts[:endpoint] == "https://abc123.eu.r2.cloudflarestorage.com"
      assert opts[:region] == "us-east-1"
      assert opts[:addressing] == :virtual_host
      assert opts[:direct_upload] == :post
      assert opts[:acl] == "public-read"
    end

    test "an option set to nil keeps the preset value" do
      assert S3.options(provider: :r2, account_id: "a", region: nil, bucket: "m")[:region] ==
               "auto"
    end

    test ":r2 without account_id or endpoint is a configuration error" do
      assert_raise ArgumentError, ~r/account_id/, fn ->
        S3.options(provider: :r2, bucket: "media")
      end
    end

    test "an unknown provider is a configuration error" do
      assert_raise ArgumentError, ~r/:generic/, fn ->
        S3.options(provider: :wasabi, bucket: "media")
      end
    end
  end

  describe "public URLs" do
    test "AWS without an endpoint keeps the amazonaws.com URL" do
      assert S3.url("a/b.jpg", bucket: "media", region: "eu-west-1") ==
               "https://media.s3.eu-west-1.amazonaws.com/a/b.jpg"
    end

    test "with an endpoint they follow it, path-style" do
      assert S3.url("a/b.jpg",
               provider: :generic,
               endpoint: "https://s3.example.com:8443/",
               bucket: "media"
             ) == "https://s3.example.com:8443/media/a/b.jpg"
    end

    test "virtual-host addressing puts the bucket in the host" do
      assert S3.url("a/b.jpg",
               provider: :generic,
               endpoint: "https://s3.example.com",
               addressing: :virtual_host,
               bucket: "media"
             ) == "https://media.s3.example.com/a/b.jpg"
    end

    test "base_url wins over the endpoint" do
      assert S3.url("a/b.jpg",
               provider: :r2,
               account_id: "abc123",
               base_url: "https://media.example.com",
               bucket: "media"
             ) == "https://media.example.com/a/b.jpg"
    end

    test ":r2 needs base_url, as R2 serves public files only from a domain" do
      assert_raise ArgumentError, ~r/base_url/, fn ->
        S3.url("a/b.jpg", provider: :r2, account_id: "abc123", bucket: "media")
      end
    end
  end

  describe "signed URLs" do
    test ":r2 signs for its account endpoint, without base_url" do
      url =
        S3.url(
          "a/b.jpg",
          [provider: :r2, account_id: "abc123", bucket: "media", signed: true] ++ @keys
        )

      assert url =~ "https://abc123.r2.cloudflarestorage.com/media/a/b.jpg?"
      assert url =~ "X-Amz-Signature="
    end

    test "virtual-host addressing signs for the bucket host" do
      url =
        S3.url(
          "a/b.jpg",
          [
            provider: :generic,
            endpoint: "https://s3.example.com",
            addressing: :virtual_host,
            bucket: "media",
            signed: true
          ] ++ @keys
        )

      assert url =~ "https://media.s3.example.com/a/b.jpg?"
    end
  end
end
