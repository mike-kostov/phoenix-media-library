defmodule PhxMediaLibrary.RefusingRepo do
  @moduledoc """
  A Repo for tests: reads go to `PhxMediaLibrary.TestRepo`; every `update/2`
  returns `{:error, :refused}`, as a constraint or validation failure
  would, so tests can check that callers don't treat it as success.
  """

  alias PhxMediaLibrary.TestRepo

  def update(_changeset, _opts \\ []), do: {:error, :refused}
  def get(queryable, id, opts \\ []), do: TestRepo.get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: TestRepo.get!(queryable, id, opts)
  def reload!(struct, opts \\ []), do: TestRepo.reload!(struct, opts)
  def reload(struct, opts \\ []), do: TestRepo.reload(struct, opts)
  def all(queryable, opts \\ []), do: TestRepo.all(queryable, opts)
  def one(queryable, opts \\ []), do: TestRepo.one(queryable, opts)
  def exists?(queryable, opts \\ []), do: TestRepo.exists?(queryable, opts)
end
