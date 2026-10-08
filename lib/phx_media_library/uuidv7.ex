defmodule PhxMediaLibrary.UUIDv7 do
  @moduledoc """
  Time-ordered UUIDs (version 7, RFC 9562) for media `id`s and `uuid`s, and
  the Ecto type that generates them.

  The first 48 bits are the creation time in milliseconds, then a 12-bit
  counter, so new ids sort by creation time and land at the end of the
  primary key index instead of all over it: bulk loads run faster and the
  indexes stay smaller (`docs/ideas/db-performance.md` measured 26% and
  21% to 23%). Ids from one node are strictly increasing, even within a
  millisecond. They load and dump like `Ecto.UUID`, so existing version 4
  ids keep working.

      iex> uuid = PhxMediaLibrary.UUIDv7.generate()
      iex> String.at(uuid, 14)
      "7"

  """

  use Ecto.Type

  import Bitwise

  @counter_key {__MODULE__, :counter}

  @doc """
  A new UUIDv7 string.

  ## Examples

      iex> a = PhxMediaLibrary.UUIDv7.generate()
      iex> b = PhxMediaLibrary.UUIDv7.generate()
      iex> a < b
      true

  """
  @spec generate() :: Ecto.UUID.t()
  def generate do
    value = next(counter(), System.system_time(:millisecond))
    <<_::2, random::62>> = :crypto.strong_rand_bytes(8)
    raw = <<value >>> 12::48, 7::4, value &&& 0xFFF::12, 2::2, random::62>>
    {:ok, uuid} = Ecto.UUID.load(raw)
    uuid
  end

  # The last value handed out, as milliseconds * 4096 + counter. A new
  # millisecond starts the counter at a random point below 1024 (leaving
  # room to count); within the same millisecond it counts up, and past
  # 4095 it borrows the next millisecond. Compare-and-swap keeps ids
  # strictly increasing across processes.
  defp next(ref, now) do
    last = :atomics.get(ref, 1)

    candidate =
      if now > last >>> 12,
        do: (now <<< 12) + :rand.uniform(1024) - 1,
        else: last + 1

    case :atomics.compare_exchange(ref, 1, last, candidate) do
      :ok -> candidate
      _changed -> next(ref, now)
    end
  end

  # Created by PhxMediaLibrary.Application at start; lazily otherwise.
  defp counter do
    case :persistent_term.get(@counter_key, nil) do
      nil -> init()
      ref -> ref
    end
  end

  @doc false
  @spec init() :: :atomics.atomics_ref()
  def init do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@counter_key, ref)
    ref
  end

  # Ecto.Type: stored and loaded exactly like Ecto.UUID.

  @impl true
  def type, do: :uuid

  @impl true
  def cast(value), do: Ecto.UUID.cast(value)

  @impl true
  def load(value), do: Ecto.UUID.load(value)

  @impl true
  def dump(value), do: Ecto.UUID.dump(value)

  @impl true
  def autogenerate, do: generate()
end
