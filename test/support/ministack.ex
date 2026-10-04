defmodule PhxMediaLibrary.Ministack do
  @moduledoc """
  The Ministack S3 emulator for the `:s3` tests (ADR-026).

  `ensure_started/0` starts a named container with podman or Docker,
  whichever is installed, and reuses it when it is already there, so only
  the first run pays for the start. Remove it with
  `podman rm -f phx_media_library_ministack` (or `docker rm -f`).

  Ministack doesn't verify request signatures: these tests prove our
  requests and flows, not provider rules.
  """

  @name "phx_media_library_ministack"
  @image "docker.io/ministackorg/ministack:1.3.42"
  @bucket "phx-media-library-test"
  @endpoint_key {__MODULE__, :endpoint}

  @doc "Starts or reuses the container and waits until it answers."
  @spec ensure_started() :: {:ok, String.t()} | {:error, String.t()}
  def ensure_started do
    with {:ok, runtime} <- runtime(),
         {:ok, port} <- port_of_running(runtime),
         endpoint = "http://127.0.0.1:#{port}",
         :ok <- await_ready(endpoint, 50) do
      :persistent_term.put(@endpoint_key, endpoint)
      {:ok, endpoint}
    end
  end

  @doc "Adapter options for an S3 disk backed by the container's test bucket."
  @spec disk_opts() :: keyword()
  def disk_opts do
    [
      bucket: @bucket,
      region: "us-east-1",
      access_key_id: "test",
      secret_access_key: "test",
      endpoint: :persistent_term.get(@endpoint_key)
    ]
  end

  @doc "Creates the test bucket unless it exists."
  @spec create_bucket() :: :ok
  def create_bucket do
    opts = disk_opts()

    case @bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(ex_aws_config(opts)) do
      {:ok, _} -> :ok
      {:error, {:http_error, 409, _}} -> :ok
    end
  end

  @doc "Config for calling ExAws directly against the container."
  @spec ex_aws_config(keyword()) :: keyword()
  def ex_aws_config(opts \\ disk_opts()) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(Keyword.fetch!(opts, :endpoint))

    [
      scheme: scheme <> "://",
      host: host,
      port: port,
      region: "us-east-1",
      access_key_id: "test",
      secret_access_key: "test"
    ]
  end

  defp runtime do
    case System.find_executable("podman") || System.find_executable("docker") do
      nil -> {:error, "neither podman nor docker is installed"}
      runtime -> {:ok, runtime}
    end
  end

  # A running container answers `port`; a stopped one is started; a missing
  # one is created. The host port is chosen by the runtime.
  defp port_of_running(runtime) do
    with :error <- published_port(runtime),
         :ok <- start_or_create(runtime) do
      case published_port(runtime) do
        {:ok, port} -> {:ok, port}
        :error -> {:error, "the container started but publishes no port"}
      end
    end
  end

  defp published_port(runtime) do
    case System.cmd(runtime, ["port", @name, "4566"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/:(\d+)$/m, output) do
          [_, port] -> {:ok, String.to_integer(port)}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  defp start_or_create(runtime) do
    with {_, code} when code != 0 <- System.cmd(runtime, ["start", @name], stderr_to_stdout: true),
         {output, code} when code != 0 <-
           System.cmd(
             runtime,
             ["run", "-d", "--name", @name, "-p", "127.0.0.1::4566", @image],
             stderr_to_stdout: true
           ) do
      {:error, "#{Path.basename(runtime)} run failed: #{String.trim(output)}"}
    else
      {_output, 0} -> :ok
    end
  end

  defp await_ready(_endpoint, 0), do: {:error, "Ministack did not answer"}

  defp await_ready(endpoint, attempts) do
    case Req.get(endpoint, retry: false, receive_timeout: 1_000) do
      {:ok, _response} ->
        :ok

      {:error, _} ->
        Process.sleep(200)
        await_ready(endpoint, attempts - 1)
    end
  end
end
