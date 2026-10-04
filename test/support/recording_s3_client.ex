defmodule PhxMediaLibrary.RecordingS3Client do
  @moduledoc """
  ExAws HTTP client for tests: sends every request through
  `ExAws.Request.Req` to the real service, and reports its method, URL and
  headers as `{:s3_request, method, url, headers}` to the process given to
  `record_to/1`.
  """

  @behaviour ExAws.Request.HttpClient

  alias ExAws.Request.Req, as: ReqClient

  @doc "Report requests to `pid` from now on (`nil` stops)."
  @spec record_to(pid() | nil) :: :ok
  def record_to(pid), do: Application.put_env(:phx_media_library, __MODULE__, pid)

  @impl true
  def request(method, url, body, headers, opts) do
    case Application.get_env(:phx_media_library, __MODULE__) do
      nil -> :ok
      pid -> send(pid, {:s3_request, method, url, headers})
    end

    ReqClient.request(method, url, body, headers, opts)
  end
end
