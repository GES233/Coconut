defmodule Coconut.Score.Record do
  @moduledoc """
  General record abstraction based on tick/bar.

  Record event model:

  - Every record is an event on the timeline at a specific location (tick or bar)
  - Records are compiled by `RecordMap` into interval tuples for binary search
  """

  alias Coconut.Score.Tick

  @typedoc """
  A record's position, a non-negative integer starting from 0.

  For Tempo this is a tick; for TimeSig this is a bar number.
  """
  @type position :: non_neg_integer()

  @typedoc """
  Marks the end boundary of the score.

  Either a known position or `:open_end` for an unbound end.
  """
  @type end_position :: position() | :open_end

  def open_end, do: :open_end

  @typedoc "Payload contained within a record."
  @type value :: term()

  @typedoc "An event at a position."
  @type t :: {position(), value()}

  @typedoc """
  A list of records.

  May be a plain list or a pair `{records, last}` with a dynamic end.
  Use `Tick.get_dynamic_tick/0` for `last` when the final segment has no fixed end position.
  """
  @type records :: [t()] | {[t()], last :: Tick.t()}
end
