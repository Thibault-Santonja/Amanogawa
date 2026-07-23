defmodule Amanogawa.WikimediaUrlTest do
  use ExUnit.Case, async: true

  doctest Amanogawa.WikimediaUrl

  alias Amanogawa.WikimediaUrl

  describe "valid?/1 happy path" do
    test "accepts language subdomains of wikipedia.org and wikimedia.org hosts" do
      assert WikimediaUrl.valid?("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      assert WikimediaUrl.valid?("https://en.wikipedia.org/wiki/Battle_of_Marathon")
      assert WikimediaUrl.valid?("https://upload.wikimedia.org/wikipedia/commons/a/ab/M.jpg")
      assert WikimediaUrl.valid?("https://commons.wikimedia.org/wiki/File:M.jpg")
    end
  end

  describe "valid?/1 rejections" do
    test "rejects non-https schemes" do
      refute WikimediaUrl.valid?("http://fr.wikipedia.org/wiki/X")
      refute WikimediaUrl.valid?("javascript:alert(1)")
      refute WikimediaUrl.valid?("ftp://fr.wikipedia.org/wiki/X")
    end

    test "rejects non-Wikimedia hosts, including suffix-spoofing attempts" do
      refute WikimediaUrl.valid?("https://evil.example.com/wiki/X")
      refute WikimediaUrl.valid?("https://evilwikipedia.org/wiki/X")
      refute WikimediaUrl.valid?("https://wikipedia.org.evil.com/wiki/X")
    end

    test "rejects URLs longer than the documented bound and non-binary input" do
      refute WikimediaUrl.valid?("https://fr.wikipedia.org/wiki/" <> String.duplicate("a", 3000))

      refute WikimediaUrl.valid?(nil)
      refute WikimediaUrl.valid?(123)
    end

    test "rejects a URL without a host" do
      refute WikimediaUrl.valid?("https:///wiki/X")
      refute WikimediaUrl.valid?("not a url")
    end
  end

  describe "valid_thumbnail?/1 happy path" do
    test "accepts an https upload.wikimedia.org URL" do
      assert WikimediaUrl.valid_thumbnail?(
               "https://upload.wikimedia.org/wikipedia/commons/a/ab/M.jpg"
             )
    end
  end

  describe "valid_thumbnail?/1 rejections" do
    test "rejects any other Wikimedia host, including a wikipedia.org article host" do
      refute WikimediaUrl.valid_thumbnail?("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      refute WikimediaUrl.valid_thumbnail?("https://commons.wikimedia.org/wiki/File:M.jpg")
    end

    test "rejects non-https schemes on the upload host" do
      refute WikimediaUrl.valid_thumbnail?(
               "http://upload.wikimedia.org/wikipedia/commons/a/ab/M.jpg"
             )
    end

    test "rejects non-Wikimedia hosts" do
      refute WikimediaUrl.valid_thumbnail?("https://evil.example.com/thumb.jpg")
    end

    test "rejects URLs longer than the documented bound and non-binary input" do
      refute WikimediaUrl.valid_thumbnail?(
               "https://upload.wikimedia.org/" <> String.duplicate("a", 3000)
             )

      refute WikimediaUrl.valid_thumbnail?(nil)
      refute WikimediaUrl.valid_thumbnail?(123)
    end
  end

  test "max_length/0 exposes the documented bound" do
    assert WikimediaUrl.max_length() == 2048
  end
end
