defmodule PhxMediaLibrary.DocumentRenderer.Pdftoppm do
  @moduledoc """
  Renders a PDF's first page with `pdftoppm` (poppler), when it is on
  `$PATH`.

  The page is scaled to `opts[:size]` pixels on its longest side, whatever
  size the PDF declares, and a run that takes longer than
  `opts[:timeout]` (default 30 seconds) is stopped: uploads are untrusted.
  """

  @behaviour PhxMediaLibrary.DocumentRenderer

  @default_timeout :timer.seconds(30)

  @doc "Whether `pdftoppm` is on `$PATH`."
  @spec available?() :: boolean()
  @impl true
  def available?, do: System.find_executable("pdftoppm") != nil

  @doc """
  Render the first page of `source` to the PNG `destination`.

  ## Examples

      :ok = PhxMediaLibrary.DocumentRenderer.Pdftoppm.render_first_page("a.pdf", "/tmp/a.png", size: 2048)

  """
  @spec render_first_page(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  @impl true
  def render_first_page(source, destination, opts) do
    size = Keyword.get(opts, :size, 2048)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    prefix = Path.rootname(destination, ".png")

    args =
      ~w(-f 1 -l 1 -singlefile -png -scale-to) ++
        [to_string(size), source, prefix]

    with {:ok, executable} <- executable(),
         :ok <- run(executable, args, timeout) do
      if prefix <> ".png" == destination,
        do: :ok,
        else: File.rename(prefix <> ".png", destination)
    end
  end

  defp executable do
    case System.find_executable("pdftoppm") do
      nil -> {:error, :pdftoppm_not_found}
      path -> {:ok, path}
    end
  end

  defp run(executable, args, timeout) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    os_pid = Port.info(port, :os_pid)
    await(port, os_pid, timeout, "")
  end

  defp await(port, os_pid, timeout, output) do
    receive do
      {^port, {:data, data}} ->
        await(port, os_pid, timeout, output <> data)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:pdftoppm_failed, status, String.slice(output, 0, 500)}}
    after
      timeout ->
        stop(port, os_pid)
        {:error, :pdftoppm_timeout}
    end
  end

  defp stop(port, {:os_pid, os_pid}) do
    Port.close(port)
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
  end

  defp stop(port, _closed), do: Port.close(port)
end
