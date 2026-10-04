defmodule PhxMediaLibrary.HealthTest do
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.Health

  doctest Health

  describe "orphaned_parents/0" do
    @describetag :db

    test "lists media whose parent record is gone" do
      orphan = create_media(mediable_type: "posts")

      assert %{orphans: %{"posts" => ids}} = Health.orphaned_parents()
      assert orphan.mediable_id in ids
    end

    test "lists types with no known model" do
      create_media(mediable_type: "long_gone_things")
      assert "long_gone_things" in Health.orphaned_parents().unknown_types
    end
  end
end
