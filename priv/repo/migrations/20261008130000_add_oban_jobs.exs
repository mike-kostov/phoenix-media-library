defmodule PhxMediaLibrary.TestRepo.Migrations.AddObanJobs do
  use Ecto.Migration

  # For the scheduled doctor's Oban runner tests.
  def up, do: Oban.Migration.up(version: 13)
  def down, do: Oban.Migration.down(version: 1)
end
