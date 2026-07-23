defmodule Amanogawa.Atlas.BorderTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas.Border

  @square %Geo.MultiPolygon{
    coordinates: [[[{0.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}, {1.0, 0.0}, {0.0, 0.0}]]],
    srid: 4326
  }

  defp valid_attrs(overrides \\ %{}) do
    %{
      polity_id: polity_fixture().id,
      geom: @square,
      from_year: -100,
      to_year: 100,
      source: "cliopatria"
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "changeset/2: happy path" do
    test "a valid attrs map produces a valid changeset" do
      assert Border.changeset(%Border{}, valid_attrs()).valid?
    end

    test "geom_medium and geom_low, when present, are validated the same way as geom" do
      changeset =
        Border.changeset(%Border{}, valid_attrs(%{geom_medium: @square, geom_low: @square}))

      assert changeset.valid?
    end
  end

  describe "changeset/2: edge case" do
    test "from_year == to_year is accepted" do
      changeset = Border.changeset(%Border{}, valid_attrs(%{from_year: 100, to_year: 100}))
      assert changeset.valid?
    end

    test "precision is optional" do
      assert Border.changeset(%Border{}, valid_attrs()).valid?
    end

    test "precision may be set (historical-basemaps' BORDERPRECISION)" do
      changeset = Border.changeset(%Border{}, valid_attrs(%{precision: 2}))
      assert changeset.valid?
    end
  end

  describe "changeset/2: error case" do
    test "polity_id is required" do
      changeset = Border.changeset(%Border{}, Map.delete(valid_attrs(), :polity_id))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).polity_id
    end

    test "geom is required" do
      changeset = Border.changeset(%Border{}, Map.delete(valid_attrs(), :geom))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).geom
    end

    test "from_year is required" do
      changeset = Border.changeset(%Border{}, Map.delete(valid_attrs(), :from_year))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).from_year
    end

    test "to_year is required" do
      changeset = Border.changeset(%Border{}, Map.delete(valid_attrs(), :to_year))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).to_year
    end

    test "source is required" do
      changeset = Border.changeset(%Border{}, Map.delete(valid_attrs(), :source))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "from_year > to_year is rejected" do
      changeset = Border.changeset(%Border{}, valid_attrs(%{from_year: 500, to_year: 100}))
      refute changeset.valid?
      assert "must be greater than or equal to from_year" in errors_on(changeset).to_year
    end

    test "a geom that is not a MultiPolygon is rejected" do
      point = %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326}
      changeset = Border.changeset(%Border{}, valid_attrs(%{geom: point}))
      refute changeset.valid?
      assert "must be a MultiPolygon geometry" in errors_on(changeset).geom
    end

    test "a geom with the wrong SRID is rejected" do
      wrong_srid = %{@square | srid: 3857}
      changeset = Border.changeset(%Border{}, valid_attrs(%{geom: wrong_srid}))
      refute changeset.valid?
      assert "must have SRID 4326" in errors_on(changeset).geom
    end

    test "an unknown polity_id fails the foreign key constraint on insert" do
      changeset = Border.changeset(%Border{}, valid_attrs(%{polity_id: Ecto.UUID.generate()}))
      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).polity_id
    end
  end

  describe "database constraints" do
    test "the from_year_before_or_equal_to_year check constraint backs the changeset validation" do
      polity = polity_fixture()

      # insert_all bypasses the changeset entirely, so only the database's
      # own check constraint can catch this: defense in depth for the
      # constraint the changeset above already enforces at the Elixir level.
      now = DateTime.truncate(DateTime.utc_now(), :second)

      assert_raise Postgrex.Error, ~r/from_year_before_or_equal_to_year/, fn ->
        Repo.insert_all(Border, [
          %{
            id: Ecto.UUID.generate(),
            polity_id: polity.id,
            geom: @square,
            from_year: 500,
            to_year: 100,
            source: "cliopatria",
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "borders.geom has a GiST index" do
      assert index_exists?("atlas", "borders", "gist")
    end
  end

  defp index_exists?(schema, table, using) do
    query = """
    SELECT 1 FROM pg_indexes
    WHERE schemaname = $1 AND tablename = $2 AND indexdef ILIKE $3
    """

    %{rows: rows} = Repo.query!(query, [schema, table, "%USING #{using}%"])
    rows != []
  end
end
