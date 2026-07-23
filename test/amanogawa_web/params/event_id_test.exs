defmodule AmanogawaWeb.Params.EventIdTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest AmanogawaWeb.Params.EventId

  alias AmanogawaWeb.Params.EventId

  describe "valid?/1" do
    test "happy path: a well-formed QID is valid" do
      assert EventId.valid?("Q31900")
      assert EventId.valid?("Q1")
    end

    test "edge case: a non-binary value is rejected without raising" do
      refute EventId.valid?(nil)
      refute EventId.valid?(123)
      refute EventId.valid?(%{})
      refute EventId.valid?(["Q1"])
    end

    test "limit case: hostile strings are rejected before any database access" do
      refute EventId.valid?("Q1' OR 1=1")
      refute EventId.valid?("../../etc/passwd")
      refute EventId.valid?(String.duplicate("Q1", 10_000))
      refute EventId.valid?("Q" <> String.duplicate("1", 10_000))
      refute EventId.valid?("")
      refute EventId.valid?("q31900")
      refute EventId.valid?("Q")
      refute EventId.valid?("Q31900 ")
      refute EventId.valid?(" Q31900")
    end
  end

  describe "property: never raises, accepts only the bounded pattern" do
    property "for any generated binary, valid?/1 never raises and only accepts Q followed by 1-15 digits" do
      check all value <- StreamData.binary(max_length: 200) do
        result = EventId.valid?(value)

        assert is_boolean(result)
        assert result == Regex.match?(~r/\AQ\d{1,15}\z/, value)
      end
    end

    property "every string built from Q plus 1 to 15 digits is valid" do
      check all digits <-
                  StreamData.list_of(StreamData.integer(0..9), min_length: 1, max_length: 15) do
        qid = "Q" <> Enum.join(digits)

        assert EventId.valid?(qid)
      end
    end

    property "a string of 16 or more digits after Q is rejected" do
      check all digits <-
                  StreamData.list_of(StreamData.integer(0..9), min_length: 16, max_length: 40) do
        qid = "Q" <> Enum.join(digits)

        refute EventId.valid?(qid)
      end
    end
  end
end
