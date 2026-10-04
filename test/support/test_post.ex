defmodule PhxMediaLibrary.TestPost do
  @moduledoc """
  A test schema for testing media associations.
  """

  use Ecto.Schema
  use PhxMediaLibrary.HasMedia

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "posts" do
    field(:title, :string)
    field(:body, :string)

    has_media()
    has_media(:images)
    has_media(:documents)
    has_media(:avatar)
    has_media(:gallery)
    has_media(:small_files)
    has_media(:unverified)
    has_media(:webp_photos)
    has_media(:webp_only)
    has_media(:responsive_webp)
    has_media(:responsive_plain)
    has_media(:webp_capped)
    has_media(:avif_photos)
    has_media(:avif_webp)
    has_media(:no_avif)
    has_media(:avif_responsive)
    has_media(:color_placeholder)
    has_media(:big_placeholder)
    has_media(:no_placeholder)

    timestamps(type: :utc_datetime)
  end

  def media_collections do
    [
      collection(:images),
      collection(:documents, accepts: ~w(application/pdf text/plain)),
      collection(:avatar, single_file: true),
      collection(:gallery, max_files: 5),
      collection(:small_files, max_size: 1_000, accepts: ~w(text/plain)),
      collection(:unverified, verify_content_type: false),
      collection(:tiny_images, max_pixels: 100),
      collection(:seo_images, file_naming: :slug),
      collection(:private_docs, file_naming: :random),
      collection(:unlimited_images, max_pixels: :infinity),
      collection(:webp_photos, webp: true, accepts: ~w(image/jpeg image/png image/webp)),
      collection(:webp_only,
        webp: [keep_original: false],
        accepts: ~w(image/jpeg image/png image/webp)
      ),
      # WebP + responsive: variants inherit the .webp encoding.
      collection(:responsive_webp,
        webp: true,
        responsive: [widths: [160, 320]],
        accepts: ~w(image/jpeg image/png image/webp)
      ),
      # Responsive without WebP: variants keep the original extension.
      collection(:responsive_plain,
        responsive: [widths: [160, 320]],
        accepts: ~w(image/jpeg image/png image/webp)
      ),
      collection(:avif_photos, avif: true, accepts: ~w(image/jpeg image/png image/webp)),
      # AVIF + capped WebP: the AVIF matches the served WebP's size.
      collection(:avif_webp,
        avif: true,
        webp: [max_dimension: 20],
        accepts: ~w(image/jpeg image/png image/webp)
      ),
      collection(:no_avif, avif: false, accepts: ~w(image/jpeg image/png image/webp)),
      collection(:color_placeholder, placeholder: :color),
      collection(:big_placeholder, placeholder: [size: 48]),
      collection(:no_placeholder, placeholder: false),
      # AVIF + WebP + responsive: variants in AVIF only (ADR-024).
      collection(:avif_responsive,
        avif: true,
        webp: true,
        responsive: [widths: [160, 320]],
        accepts: ~w(image/jpeg image/png image/webp)
      ),
      # Capped WebP: the served file fits in 100px; variants above it are skipped.
      collection(:webp_capped,
        webp: [max_dimension: 100],
        responsive: [widths: [50, 80, 200]],
        accepts: ~w(image/jpeg image/png image/webp)
      )
    ]
  end

  def media_conversions do
    [
      conversion(:thumb, width: 150, height: 150, fit: :cover),
      conversion(:preview, width: 800, quality: 85),
      conversion(:banner, width: 1200, height: 400, fit: :crop, collections: [:images])
    ]
  end
end
