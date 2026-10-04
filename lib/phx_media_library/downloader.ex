defmodule PhxMediaLibrary.Downloader do
  @moduledoc """
  Downloads a remote file to a temporary path for `add_from_url/3`.

  The URL usually comes from a user, so the download is guarded:

    * **Private networks are refused.** The host is resolved first and every
      address must be public — loopback, private (RFC 1918), link-local
      (including cloud metadata at `169.254.169.254`), CGNAT, multicast and
      their IPv6 equivalents are rejected. The connection is then pinned to
      the checked address, so a DNS answer that changes between the check and
      the connect can't redirect it. TLS still verifies the original hostname.
    * **Redirects are followed manually**, re-checking every hop.
    * **The body streams to disk** instead of memory, and is not decompressed,
      so a small gzip response can't expand into gigabytes.
    * **Size and time are capped**: `:max_size` (bytes) and `:total_timeout`
      (milliseconds, default 5 minutes) for the whole download.

  ## Options

    * `:headers`: extra request headers (e.g. authorization)
    * `:timeout`: receive timeout between chunks, in milliseconds
    * `:total_timeout`: limit for the whole download (default `300_000`)
    * `:max_size`: maximum body size in bytes (the collection's `max_size`
      is used when the caller doesn't set one)
    * `:max_redirects`: default `5`
    * `:allow_private_hosts`: set to `true` to allow private and loopback
      addresses, e.g. for an intranet; off by default
    * `:req_options`: extra options merged into the `Req` request
  """

  alias PhxMediaLibrary.FileName

  @default_total_timeout 300_000
  @default_max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  @typedoc "A downloaded file, ready for `MediaAdder`."
  @type file_info :: %{
          path: String.t(),
          filename: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          temp: true,
          source_url: String.t()
        }

  @doc """
  Download `url` to a temporary file.

  The caller owns the returned `path` and must delete it. On error, nothing
  is left behind.

  ## Examples

      {:ok, info} = PhxMediaLibrary.Downloader.download("https://example.com/a.jpg", max_size: 5_000_000)
      info.filename #=> "a.jpg"

      PhxMediaLibrary.Downloader.download("http://169.254.169.254/latest/meta-data")
      #=> {:error, {:invalid_url, :private_address, "169.254.169.254"}}

  """
  @spec download(String.t(), keyword()) :: {:ok, file_info()} | {:error, term()}
  def download(url, opts \\ []) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :total_timeout, @default_total_timeout)

    temp_path =
      Path.join(System.tmp_dir!(), "phx_media_download_#{:erlang.unique_integer([:positive])}")

    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)

    case follow(url, opts, temp_path, deadline, max_redirects) do
      {:ok, final_url, headers, size} ->
        {:ok, finalize(url, final_url, headers, size, temp_path)}

      {:error, _} = error ->
        File.rm(temp_path)
        error
    end
  end

  @doc """
  Check that a URL is an `http(s)` URL whose host resolves only to public
  addresses. Returns the resolved address to connect to.

  ## Examples

      iex> PhxMediaLibrary.Downloader.check_url("ftp://example.com/a.txt", [])
      {:error, {:invalid_url, :unsupported_scheme, "ftp"}}

      iex> PhxMediaLibrary.Downloader.check_url("http://127.0.0.1/admin", [])
      {:error, {:invalid_url, :private_address, "127.0.0.1"}}

      iex> PhxMediaLibrary.Downloader.check_url("http://93.184.215.14/a.jpg", [])
      {:ok, {93, 184, 215, 14}}

  """
  @spec check_url(term(), keyword()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def check_url(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, {:invalid_url, :unsupported_scheme, uri.scheme}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, {:invalid_url, :missing_host}}

      true ->
        resolve_public(uri.host, Keyword.get(opts, :allow_private_hosts, false))
    end
  end

  def check_url(_url, _opts), do: {:error, {:invalid_url, :not_a_string}}

  @doc """
  Whether an IP address is on a private, loopback, link-local or otherwise
  non-public network.

  ## Examples

      iex> PhxMediaLibrary.Downloader.private_address?({10, 0, 0, 1})
      true

      iex> PhxMediaLibrary.Downloader.private_address?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      true

      iex> PhxMediaLibrary.Downloader.private_address?({8, 8, 8, 8})
      false

  """
  @spec private_address?(:inet.ip_address()) :: boolean()
  def private_address?({a, _, _, _}) when a in [0, 10, 127] or a >= 224, do: true
  def private_address?({100, b, _, _}) when b in 64..127, do: true
  def private_address?({169, 254, _, _}), do: true
  def private_address?({172, b, _, _}) when b in 16..31, do: true
  def private_address?({192, 168, _, _}), do: true
  def private_address?({192, 0, c, _}) when c in [0, 2], do: true
  def private_address?({198, b, _, _}) when b in [18, 19], do: true
  def private_address?({_, _, _, _}), do: false

  # IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) embed an IPv4 address.
  def private_address?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private_address?(ipv4(hi, lo))
  def private_address?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: private_address?(ipv4(hi, lo))
  def private_address?({0, 0, 0, 0, 0, 0, 0, n}) when n in [0, 1], do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  def private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00, do: true
  def private_address?({_, _, _, _, _, _, _, _}), do: false

  defp ipv4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  # ---------------------------------------------------------------------------
  # Request loop
  # ---------------------------------------------------------------------------

  defp follow(_url, _opts, _temp_path, _deadline, -1),
    do: {:error, {:download_failed, :too_many_redirects}}

  defp follow(url, opts, temp_path, deadline, redirects_left) do
    with {:ok, address} <- check_url(url, opts),
         {:ok, response, size} <- request(url, address, opts, temp_path, deadline) do
      case response do
        %{status: status} when status in 200..299 ->
          {:ok, url, response.headers, size}

        %{status: status} when status in @redirect_statuses ->
          redirect(response, url, opts, temp_path, deadline, redirects_left)

        %{status: status} ->
          {:error, {:download_failed, status}}
      end
    end
  end

  defp redirect(response, url, opts, temp_path, deadline, redirects_left) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        next = url |> URI.merge(location) |> URI.to_string()
        follow(next, opts, temp_path, deadline, redirects_left - 1)

      [] ->
        {:error, {:download_failed, response.status}}
    end
  end

  defp request(url, address, opts, temp_path, deadline) do
    max_size = Keyword.get(opts, :max_size)
    uri = URI.parse(url)
    file = File.open!(temp_path, [:write, :binary])

    req_opts =
      [
        url: pinned_url(uri, address),
        headers: [{"host", host_header(uri)} | Keyword.get(opts, :headers, [])],
        connect_options: [hostname: uri.host],
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        raw: true,
        into: &write_chunk(&1, &2, file, max_size, deadline)
      ]
      |> maybe_put(:receive_timeout, Keyword.get(opts, :timeout))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    try do
      case Req.request(req_opts) do
        {:ok, %{private: %{phx_media_error: reason}}} -> {:error, reason}
        {:ok, response} -> {:ok, response, Req.Response.get_private(response, :phx_media_size, 0)}
        {:error, reason} -> {:error, {:download_failed, reason}}
      end
    after
      File.close(file)
    end
  end

  defp write_chunk({:data, data}, {req, resp}, file, max_size, deadline) do
    size = Req.Response.get_private(resp, :phx_media_size, 0) + byte_size(data)

    cond do
      # Redirect and error bodies are discarded, not written.
      resp.status not in 200..299 ->
        {:cont, {req, resp}}

      is_integer(max_size) and size > max_size ->
        {:halt,
         {req,
          Req.Response.put_private(resp, :phx_media_error, {:file_too_large, size, max_size})}}

      System.monotonic_time(:millisecond) > deadline ->
        {:halt,
         {req, Req.Response.put_private(resp, :phx_media_error, {:download_failed, :timeout})}}

      true ->
        IO.binwrite(file, data)
        {:cont, {req, Req.Response.put_private(resp, :phx_media_size, size)}}
    end
  end

  # Connect to the checked IP; `connect_options: [hostname: ...]` keeps SNI
  # and certificate verification on the original host.
  defp pinned_url(uri, address) do
    ip =
      case address do
        {_, _, _, _} -> :inet.ntoa(address) |> to_string()
        _ -> "[#{:inet.ntoa(address)}]"
      end

    URI.to_string(%{uri | host: ip})
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"
  end

  defp resolve_public(host, allow_private?) do
    with {:ok, addresses} <- resolve(host) do
      cond do
        allow_private? ->
          {:ok, hd(addresses)}

        Enum.any?(addresses, &private_address?/1) ->
          {:error, {:invalid_url, :private_address, host}}

        true ->
          {:ok, hd(addresses)}
      end
    end
  end

  defp resolve(host) do
    charlist = host |> String.trim_leading("[") |> String.trim_trailing("]") |> to_charlist()

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        addresses =
          for family <- [:inet, :inet6],
              {:ok, list} <- [:inet.getaddrs(charlist, family)],
              address <- list,
              do: address

        if addresses == [],
          do: {:error, {:download_failed, :nxdomain}},
          else: {:ok, addresses}
    end
  end

  # ---------------------------------------------------------------------------
  # Result
  # ---------------------------------------------------------------------------

  defp finalize(url, final_url, headers, size, temp_path) do
    filename =
      (content_disposition_filename(headers) || url_filename(final_url) || url_filename(url))
      |> FileName.safe()

    %{
      path: temp_path,
      filename: filename,
      mime_type: content_type(headers) || MIME.from_path(filename),
      size: size,
      temp: true,
      source_url: url
    }
  end

  defp url_filename(url) do
    case url |> URI.parse() |> Map.get(:path) do
      path when is_binary(path) and path not in ["", "/"] ->
        path |> Path.basename() |> URI.decode()

      _ ->
        nil
    end
  end

  defp content_disposition_filename(headers) do
    with [value | _] <- Map.get(headers, "content-disposition", []),
         [filename] <- Regex.run(~r/filename="?([^";]+)"?/, value, capture: :all_but_first) do
      filename
    else
      _ -> nil
    end
  end

  defp content_type(headers) do
    case Map.get(headers, "content-type", []) do
      [value | _] -> value |> String.split(";") |> List.first() |> String.trim()
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
