defmodule Amanogawa.Ingestion.WikipediaClientTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.WikipediaClient

  alias Amanogawa.Ingestion.WikipediaClient
  alias Amanogawa.Ingestion.WikipediaClient.Summary
  alias Amanogawa.WikipediaFixtures

  describe "title_from_wiki_url/1 happy path" do
    test "decodes a plain fr title" do
      assert WikipediaClient.title_from_wiki_url(
               "https://fr.wikipedia.org/wiki/Bataille_de_Marathon"
             ) ==
               "Bataille_de_Marathon"
    end

    test "decodes an en title" do
      assert WikipediaClient.title_from_wiki_url(
               "https://en.wikipedia.org/wiki/Battle_of_Agincourt"
             ) ==
               "Battle_of_Agincourt"
    end
  end

  describe "title_from_wiki_url/1 edge cases" do
    test "decodes accented characters" do
      assert WikipediaClient.title_from_wiki_url(
               "https://fr.wikipedia.org/wiki/D%C3%A9fenestration_de_Prague"
             ) == "Défenestration_de_Prague"
    end

    test "decodes an apostrophe and parentheses" do
      assert WikipediaClient.title_from_wiki_url(
               "https://en.wikipedia.org/wiki/Diet_of_Augsburg_%281530%29"
             ) == "Diet_of_Augsburg_(1530)"
    end
  end

  describe "title_from_wiki_url/1 limit case" do
    test "a malformed percent-encoded segment (invalid escape) decodes unchanged, never raising" do
      assert WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/100%_Certain") ==
               "100%_Certain"
    end

    test "a percent-encoded byte sequence that is not valid UTF-8 falls back to the raw segment" do
      # %FF alone is not a valid UTF-8 byte sequence: URI.decode/1 would
      # otherwise silently hand back a corrupt (non-UTF-8) title.
      assert WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/Bad_%FF_Title") ==
               "Bad_%FF_Title"
    end
  end

  describe "title_from_wiki_url/1 (property-based)" do
    property "never raises on an arbitrary segment and always yields a re-encodable title" do
      check all(segment <- string(:printable, min_length: 1, max_length: 30)) do
        title = WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/" <> segment)

        assert is_binary(title)
        assert String.valid?(title)
        assert is_binary(URI.encode(title, &URI.char_unreserved?/1))
      end
    end
  end

  describe "Summary.decode/2 happy path" do
    test "decodes the fr fixture into a complete Summary" do
      assert {:ok, %Summary{} = summary} =
               Summary.decode(WikipediaFixtures.raw_wikipedia_fixture("summary_fr.json"), :fr)

      assert summary.title == "Bataille de Marathon"
      assert summary.lang == :fr
      assert summary.thumbnail_url =~ "upload.wikimedia.org"
      assert summary.article_url == "https://fr.wikipedia.org/wiki/Bataille_de_Marathon"
      assert summary.extract =~ "bataille de Marathon"
    end
  end

  describe "Summary.decode/2 edge case" do
    test "no thumbnail decodes with thumbnail_url nil" do
      assert {:ok, %Summary{thumbnail_url: nil}} =
               Summary.decode(
                 WikipediaFixtures.raw_wikipedia_fixture("summary_en_no_thumbnail.json"),
                 :en
               )
    end
  end

  describe "Summary.decode/2 error cases" do
    test "malformed (truncated) JSON returns {:error, %Jason.DecodeError{}}" do
      assert {:error, %Jason.DecodeError{}} =
               Summary.decode(WikipediaFixtures.raw_wikipedia_fixture("malformed.json"), :fr)
    end

    test "well-formed JSON missing extract returns {:error, :invalid_summary_shape}" do
      assert {:error, :invalid_summary_shape} = Summary.decode(%{"title" => "Only a title"}, :fr)
    end

    test "well-formed JSON missing the desktop article URL returns {:error, :missing_article_url}" do
      assert {:error, :missing_article_url} =
               Summary.decode(%{"title" => "T", "extract" => "E"}, :fr)
    end
  end
end
