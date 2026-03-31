defmodule PhxMediaLibrary.Blurhash do
  import Bitwise

  @moduledoc """
  BlurHash generation for images.

  [BlurHash](https://blurha.sh) is a compact representation of a placeholder
  for an image. A 20–30 character ASCII string encodes a low-fidelity blurred
  version of the image that can be rendered on the client before the real
  image loads, without any additional HTTP round-trips.

  ## Comparison with Tiny JPEG Placeholders

  PhxMediaLibrary already generates tiny JPEG placeholders (≈ 500–2 KB).
  BlurHash strings are typically 20–40 bytes and are stored directly in the
  database field, making them easier to embed in JSON APIs and server-rendered
  HTML without base64 overhead.

  ## Requirements

  Blurhash generation requires the `:image` library (libvips wrapper). The
  feature is silently disabled when the library is not available.

  ## Configuration

      config :phx_media_library,
        responsive_images: [
          enabled: true,
          blurhash: true          # opt-in
        ]

  ## Usage

  When enabled, a blurhash string is automatically generated for every image
  upload and stored in `media.responsive_images["blurhash"]`.

  Render it in a template with the `<PhxMediaLibrary.Components.blurhash>`
  component, which decodes the hash client-side via a colocated JS hook and
  paints it onto a `<canvas>` element.

      <PhxMediaLibrary.Components.blurhash media={@media} class="w-full rounded-lg" />

  You can also call the generator directly:

      {:ok, hash} = PhxMediaLibrary.Blurhash.generate("/path/to/image.jpg")
      #=> {:ok, "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"}

  ## Component X/Y Components

  The number of DCT components controls the detail vs. string-length trade-off.
  The default is 4×3 (12 components, ~28 chars). You can adjust per-call:

      {:ok, hash} = PhxMediaLibrary.Blurhash.generate(path, components_x: 5, components_y: 4)

  Values above 8×8 are uncommon; the official recommendation is 4×3 or 3×4.
  """

  # ---------------------------------------------------------------------------
  # Base-83 alphabet (must match the JavaScript decoder exactly)
  # ---------------------------------------------------------------------------

  @base83 "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"

  # ---------------------------------------------------------------------------
  # Public API — conditionally compiled when :image is available
  # ---------------------------------------------------------------------------

  if Code.ensure_loaded?(Image) do
    @doc """
    Returns `true` when the `:image` library is available and blurhash
    generation is possible.
    """
    @spec available?() :: boolean()
    def available?, do: true

    @doc """
    Generate a BlurHash string from an image file path or an in-memory
    `%Vix.Vips.Image{}`.

    The image is automatically resized to a small working size (64 px wide)
    before the DCT components are computed, so performance is consistent
    regardless of the input resolution.

    ## Arguments

    - `source` — file path (`String.t()`) **or** an already-opened
      `%Vix.Vips.Image{}` struct.
    - `opts` — keyword options.

    ## Options

    - `:components_x` — number of DCT components in the horizontal direction
      (`1`–`9`, default: `4`).
    - `:components_y` — number of DCT components in the vertical direction
      (`1`–`9`, default: `3`).

    ## Return value

    `{:ok, hash_string}` on success, or `{:error, reason}` on failure.

    ## Examples

        iex> PhxMediaLibrary.Blurhash.generate("priv/static/uploads/photo.jpg")
        {:ok, "LKO2?V%2Tw=w]~RBVZRi};RPxuwH"}

        iex> PhxMediaLibrary.Blurhash.generate("photo.jpg", components_x: 5, components_y: 4)
        {:ok, "..."}

    """
    @spec generate(String.t() | term(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def generate(source, opts \\ []) do
      num_x = Keyword.get(opts, :components_x, 4) |> clamp_components()
      num_y = Keyword.get(opts, :components_y, 3) |> clamp_components()

      with {:ok, image} <- open_image(source),
           {:ok, small} <- Image.thumbnail(image, 64, resize: :force),
           {:ok, rgb} <- ensure_rgb(small),
           width = Image.width(rgb),
           height = Image.height(rgb),
           {:ok, pixels} <- extract_pixels(rgb) do
        hash = encode(pixels, width, height, num_x, num_y)
        {:ok, hash}
      end
    end

    # Open a file path or pass through an already-open Vix image.
    defp open_image(path) when is_binary(path), do: Image.open(path)
    defp open_image(image), do: {:ok, image}

    # Ensure the image has exactly 3 bands (RGB).  RGBA and other multi-band
    # images have the extra bands stripped.  Grayscale (1 band) is expanded
    # to 3 bands so the encoder always receives consistent input.
    defp ensure_rgb(image) do
      bands = Vix.Vips.Image.bands(image)

      cond do
        bands == 3 ->
          {:ok, image}

        bands >= 4 ->
          # Drop alpha and any extra bands, keep R/G/B
          Vix.Vips.Operation.extract_band(image, 0, n: 3)

        bands == 1 ->
          # Grayscale → replicate to 3-band by stacking three copies
          with {:ok, b1} <- Vix.Vips.Operation.extract_band(image, 0),
               {:ok, b2} <- Vix.Vips.Operation.extract_band(image, 0),
               {:ok, b3} <- Vix.Vips.Operation.extract_band(image, 0) do
            Vix.Vips.Operation.bandjoin([b1, b2, b3])
          end

        true ->
          {:error, "Unsupported number of image bands: #{bands}"}
      end
    end

    # Write the image as raw interleaved bytes and return a list of
    # {r, g, b} tuples in the range 0.0–1.0 (sRGB).
    #
    # Vix.Vips.Image.write_to_binary/1 dumps pixels row-major, interleaved:
    #   <<R1, G1, B1, R2, G2, B2, ...>> for a 3-band UCHAR image.
    defp extract_pixels(image) do
      case Vix.Vips.Image.write_to_binary(image) do
        {:ok, binary} ->
          pixels = decode_binary_pixels(binary, 3)
          {:ok, pixels}

        {:error, _} = err ->
          err
      end
    end

    defp decode_binary_pixels(binary, bands) do
      total = div(byte_size(binary), bands)

      for i <- 0..(total - 1) do
        offset = i * bands
        r = :binary.at(binary, offset) / 255.0
        g = :binary.at(binary, offset + 1) / 255.0
        b = :binary.at(binary, offset + 2) / 255.0
        {r, g, b}
      end
    end
  else
    @doc """
    Returns `false` — the `:image` library is not available.
    """
    @spec available?() :: boolean()
    def available?, do: false

    @doc """
    Always returns `{:error, :image_not_available}` when the `:image` library
    is not installed.
    """
    @spec generate(term(), keyword()) :: {:error, :image_not_available}
    def generate(_source, _opts \\ []) do
      {:error, :image_not_available}
    end
  end

  # ---------------------------------------------------------------------------
  # Pure-Elixir BlurHash encoder
  # ---------------------------------------------------------------------------
  #
  # Reference implementation:
  #   https://github.com/woltapp/blurhash/tree/master/TypeScript
  #
  # The algorithm:
  #   1. For each of the numX * numY DCT components, accumulate the
  #      pixel contributions via the cosine basis function.
  #   2. Normalize by (width * height).
  #   3. The first component (0,0) is the DC value (average colour).
  #      All others are AC values.
  #   4. Quantise the maximum AC magnitude to a 7-bit integer and encode
  #      that as a single base-83 digit.
  #   5. Encode DC (4 digits), each AC (2 digits) in base-83.
  #   6. Prepend a 1-digit size flag: (numX - 1) + (numY - 1) * 9.

  @doc false
  @spec encode([{float(), float(), float()}], pos_integer(), pos_integer(), 1..9, 1..9) ::
          String.t()
  def encode(pixels, width, height, num_x \\ 4, num_y \\ 3) do
    components =
      for cy <- 0..(num_y - 1), cx <- 0..(num_x - 1) do
        compute_component(pixels, width, height, cx, cy)
      end

    [dc | acs] = components

    # Maximum AC magnitude, used for quantisation.
    max_ac_value =
      if acs == [] do
        1.0
      else
        acs
        |> Enum.flat_map(fn {r, g, b} -> [abs(r), abs(g), abs(b)] end)
        |> Enum.max()
        |> max(1.0e-6)
      end

    # Quantise max AC to a 0–82 integer; recover the real scale factor.
    quantised_max_ac = clamp(trunc(max_ac_value * 166.0 - 0.5), 0, 82)
    real_max_ac = (quantised_max_ac + 1) / 166.0

    size_flag = num_x - 1 + (num_y - 1) * 9

    ac_parts = Enum.map(acs, &encode83(encode_ac(&1, real_max_ac), 2))

    IO.iodata_to_binary([
      encode83(size_flag, 1),
      encode83(quantised_max_ac, 1),
      encode83(encode_dc(dc), 4)
      | ac_parts
    ])
  end

  # ---------------------------------------------------------------------------
  # DCT component computation
  # ---------------------------------------------------------------------------

  # Computes one DCT component for the given (cx, cy) frequency pair.
  # Pixels are expected as {sRGB_r, sRGB_g, sRGB_b} tuples in 0.0–1.0.
  # The cosine transform operates in *linear* light, so sRGB values are
  # converted before accumulation and normalised by (width * height).
  defp compute_component(pixels, width, height, cx, cy) do
    # DC component is normalised differently from AC components.
    normalisation = if cx == 0 and cy == 0, do: 1.0, else: 2.0

    {r_sum, g_sum, b_sum} =
      pixels
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {{sr, sg, sb}, idx}, {ar, ag, ab} ->
        x = rem(idx, width)
        y = div(idx, width)

        basis =
          normalisation *
            :math.cos(:math.pi() * cx * x / width) *
            :math.cos(:math.pi() * cy * y / height)

        {ar + basis * srgb_to_linear(sr), ag + basis * srgb_to_linear(sg),
         ab + basis * srgb_to_linear(sb)}
      end)

    scale = 1.0 / (width * height)
    {r_sum * scale, g_sum * scale, b_sum * scale}
  end

  # ---------------------------------------------------------------------------
  # Colour space helpers
  # ---------------------------------------------------------------------------

  # sRGB 0.0–1.0  →  linear light 0.0–1.0  (IEC 61966-2-1)
  defp srgb_to_linear(c) when c <= 0.04045, do: c / 12.92
  defp srgb_to_linear(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  # Linear light 0.0–1.0  →  sRGB 0–255 integer (clamped + rounded)
  defp linear_to_srgb(c) do
    clamped = max(0.0, min(1.0, c))

    if clamped <= 0.0031308 do
      round(clamped * 12.92 * 255 + 0.5)
    else
      round((1.055 * :math.pow(clamped, 1.0 / 2.4) - 0.055) * 255 + 0.5)
    end
  end

  # ---------------------------------------------------------------------------
  # Component encoding
  # ---------------------------------------------------------------------------

  # DC component: linear {r, g, b}  →  24-bit sRGB integer
  defp encode_dc({r, g, b}) do
    linear_to_srgb(r) <<< 16 ||| linear_to_srgb(g) <<< 8 ||| linear_to_srgb(b)
  end

  # AC component: linear {r, g, b}  →  integer 0–(19*19*19 - 1)
  # sign_pow compresses the range into ±9 quanta.
  defp encode_ac({r, g, b}, max_ac) do
    r_q = clamp(trunc(sign_pow(r / max_ac, 0.5) * 9.0 + 9.5), 0, 18)
    g_q = clamp(trunc(sign_pow(g / max_ac, 0.5) * 9.0 + 9.5), 0, 18)
    b_q = clamp(trunc(sign_pow(b / max_ac, 0.5) * 9.0 + 9.5), 0, 18)

    r_q * 19 * 19 + g_q * 19 + b_q
  end

  # sign(x) * |x|^p  — preserves sign while applying a power curve
  defp sign_pow(x, p) when x >= 0.0, do: :math.pow(x, p)
  defp sign_pow(x, p), do: -:math.pow(-x, p)

  # ---------------------------------------------------------------------------
  # Base-83 encoding
  # ---------------------------------------------------------------------------

  # Encodes a non-negative integer `value` into exactly `length` base-83
  # digits using the standard BlurHash alphabet.
  defp encode83(value, length) do
    Enum.map_join((length - 1)..0//-1, fn i ->
      divisor = Integer.pow(83, i)
      digit = rem(div(value, divisor), 83)
      String.at(@base83, digit)
    end)
  end

  # ---------------------------------------------------------------------------
  # Misc helpers
  # ---------------------------------------------------------------------------

  defp clamp(v, min_v, max_v), do: max(min_v, min(max_v, v))

  # Components must be in 1–9; values outside that range are clamped.
  defp clamp_components(n), do: clamp(n, 1, 9)
end
