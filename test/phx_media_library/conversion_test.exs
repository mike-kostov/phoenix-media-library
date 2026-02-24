defmodule PhxMediaLibrary.ConversionTest do
  use ExUnit.Case, async: true

  alias PhxMediaLibrary.Conversion

  describe "new/2" do
    test "creates a conversion with required name and options" do
      conversion = Conversion.new(:thumb, width: 150, height: 150)

      assert conversion.name == :thumb
      assert conversion.width == 150
      assert conversion.height == 150
    end

    test "sets default fit to :contain" do
      conversion = Conversion.new(:thumb, width: 100)

      assert conversion.fit == :contain
    end

    test "sets default queued to true" do
      conversion = Conversion.new(:thumb, width: 100)

      assert conversion.queued == true
    end

    test "sets default collections to empty list" do
      conversion = Conversion.new(:thumb, width: 100)

      assert conversion.collections == []
    end

    test "creates a conversion with custom fit option" do
      conversion = Conversion.new(:banner, width: 1200, height: 400, fit: :cover)

      assert conversion.fit == :cover
    end

    test "creates a conversion with crop fit" do
      conversion = Conversion.new(:square, width: 200, height: 200, fit: :crop)

      assert conversion.fit == :crop
    end

    test "creates a conversion with quality setting" do
      conversion = Conversion.new(:preview, width: 800, quality: 85)

      assert conversion.width == 800
      assert conversion.quality == 85
    end

    test "creates a conversion with format setting" do
      conversion = Conversion.new(:webp_thumb, width: 150, format: :webp)

      assert conversion.format == :webp
    end

    test "creates a conversion limited to specific collections" do
      conversion =
        Conversion.new(:thumb,
          width: 150,
          height: 150,
          collections: [:images, :gallery]
        )

      assert conversion.collections == [:images, :gallery]
    end

    test "creates a synchronous conversion" do
      conversion = Conversion.new(:thumb, width: 100, queued: false)

      assert conversion.queued == false
    end

    test "creates a conversion with all options" do
      conversion =
        Conversion.new(:full,
          width: 1920,
          height: 1080,
          fit: :fill,
          quality: 90,
          format: :jpg,
          collections: [:images],
          queued: true
        )

      assert conversion.name == :full
      assert conversion.width == 1920
      assert conversion.height == 1080
      assert conversion.fit == :fill
      assert conversion.quality == 90
      assert conversion.format == :jpg
      assert conversion.collections == [:images]
      assert conversion.queued == true
    end

    test "allows nil width for height-only resize" do
      conversion = Conversion.new(:tall, height: 500)

      assert conversion.width == nil
      assert conversion.height == 500
    end

    test "allows nil height for width-only resize" do
      conversion = Conversion.new(:wide, width: 800)

      assert conversion.width == 800
      assert conversion.height == nil
    end
  end

  describe "struct" do
    test "has correct struct keys" do
      conversion = %Conversion{}

      assert Map.has_key?(conversion, :name)
      assert Map.has_key?(conversion, :width)
      assert Map.has_key?(conversion, :height)
      assert Map.has_key?(conversion, :fit)
      assert Map.has_key?(conversion, :quality)
      assert Map.has_key?(conversion, :format)
      assert Map.has_key?(conversion, :collections)
      assert Map.has_key?(conversion, :queued)
    end

    test "default struct has nil values for optional fields" do
      conversion = %Conversion{}

      assert conversion.name == nil
      assert conversion.width == nil
      assert conversion.height == nil
      assert conversion.quality == nil
      assert conversion.format == nil
    end
  end

  describe "fit types" do
    test "supports :contain fit" do
      conversion = Conversion.new(:test, width: 100, fit: :contain)
      assert conversion.fit == :contain
    end

    test "supports :cover fit" do
      conversion = Conversion.new(:test, width: 100, fit: :cover)
      assert conversion.fit == :cover
    end

    test "supports :fill fit" do
      conversion = Conversion.new(:test, width: 100, fit: :fill)
      assert conversion.fit == :fill
    end

    test "supports :crop fit" do
      conversion = Conversion.new(:test, width: 100, fit: :crop)
      assert conversion.fit == :crop
    end
  end

  describe "format types" do
    test "supports :jpg format" do
      conversion = Conversion.new(:test, width: 100, format: :jpg)
      assert conversion.format == :jpg
    end

    test "supports :png format" do
      conversion = Conversion.new(:test, width: 100, format: :png)
      assert conversion.format == :png
    end

    test "supports :webp format" do
      conversion = Conversion.new(:test, width: 100, format: :webp)
      assert conversion.format == :webp
    end

    test "supports :original format" do
      conversion = Conversion.new(:test, width: 100, format: :original)
      assert conversion.format == :original
    end
  end
end
