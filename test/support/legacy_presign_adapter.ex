defmodule PhxMediaLibrary.LegacyPresignAdapter do
  @moduledoc """
  A storage adapter written before `presigned_upload/3`: it implements only
  the deprecated `presigned_upload_url/3` callback.
  """

  @doc false
  def presigned_upload_url(_path, _presigned_opts, _opts),
    do: {:ok, "https://legacy.example.com", %{"legacy" => "yes"}}
end
