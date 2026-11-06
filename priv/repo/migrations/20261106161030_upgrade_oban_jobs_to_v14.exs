defmodule PhxMediaLibrary.TestRepo.Migrations.UpgradeObanJobsToV14 do
  use Ecto.Migration

  # Oban 2.24 refuses to start below version 14.
  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 13)
end
