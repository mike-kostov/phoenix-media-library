defmodule PhxMediaLibrary.ResponsiveImages.WidthCalculator do
  @moduledoc """
  Calculates optimal widths for responsive image generation.

  By default, uses configured breakpoints filtered by the original image width.
  Can also calculate widths dynamically based on the original dimensions.
  """

  alias PhxMediaLibrary.Config

  @doc """
  Get the widths to generate for a given original width.

  Returns widths smaller than the original, plus the original width itself.
  """
  @spec widths_for(original_width :: pos_integer()) :: [pos_integer()]
  def widths_for(original_width) do
    Config.responsive_image_widths()
    |> Enum.filter(&(&1 < original_width))
    |> Enum.sort()
    |> then(&(&1 ++ [original_width]))
  end

  @doc """
  Calculate optimal widths dynamically based on original dimensions.

  This generates widths at roughly 50% intervals down to a minimum size,
  which provides good coverage without generating too many files.

  ## Options

  - `:min_width` - Minimum width to generate (default: 320)
  - `:step_factor` - Factor to divide by for each step (default: 1.5)
  - `:max_variants` - Maximum number of variants (default: 6)

  ## Examples

      iex> WidthCalculator.calculate_widths(1920)
      [320, 480, 720, 1080, 1620, 1920]

      iex> WidthCalculator.calculate_widths(800, min_width: 200)
      [200, 300, 450, 675, 800]

  """
  @spec calculate_widths(original_width :: pos_integer(), opts :: keyword()) :: [pos_integer()]
  def calculate_widths(original_width, opts \\ []) do
    min_width = Keyword.get(opts, :min_width, 320)
    step_factor = Keyword.get(opts, :step_factor, 1.5)
    max_variants = Keyword.get(opts, :max_variants, 6)

    do_calculate_widths(original_width, min_width, step_factor, max_variants)
    |> Enum.reverse()
    |> Enum.take(max_variants)
    |> Enum.sort()
  end

  defp do_calculate_widths(current_width, min_width, step_factor, max_variants, acc \\ [])

  defp do_calculate_widths(current_width, min_width, _step_factor, _max_variants, acc)
       when current_width <= min_width do
    [min_width | acc]
  end

  defp do_calculate_widths(current_width, _min_width, _step_factor, max_variants, acc)
       when length(acc) >= max_variants - 1 do
    [current_width | acc]
  end

  defp do_calculate_widths(current_width, min_width, step_factor, max_variants, acc) do
    next_width = round(current_width / step_factor)
    do_calculate_widths(next_width, min_width, step_factor, max_variants, [current_width | acc])
  end

  @doc """
  Get widths optimized for common device breakpoints.

  These match common CSS media query breakpoints:
  - 320px  - Small phones
  - 640px  - Large phones / small tablets
  - 768px  - Tablets
  - 1024px - Small desktops / landscape tablets
  - 1280px - Desktops
  - 1536px - Large desktops
  - 1920px - Full HD displays

  """
  @spec device_breakpoints() :: [pos_integer()]
  def device_breakpoints do
    [320, 640, 768, 1024, 1280, 1536, 1920]
  end

  @doc """
  Filter breakpoints to only those smaller than the original.
  """
  @spec filter_breakpoints(breakpoints :: [pos_integer()], original_width :: pos_integer()) ::
          [pos_integer()]
  def filter_breakpoints(breakpoints, original_width) do
    smaller = Enum.filter(breakpoints, &(&1 < original_width))
    smaller ++ [original_width]
  end
end
