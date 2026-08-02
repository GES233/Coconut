defmodule Coconut.Channel do
  @moduledoc """
  Channel contract for `Coconut.Resolve`.

  A channel is one data facet the engine consumes (lyric, phoneme, phoneme
  duration, pitch, ...). Channels are deliberately *not* hardcoded: any
  module implementing this behaviour can be registered in the channel map
  passed to `Coconut.Resolve.run_check/3`, next to plain ad-hoc spec maps.

  Each channel supplies:

  - `projection/2` — produces the fresh base slice for a patch's anchor
    region: a canonical term (see `Tamale.Digest`). `Tamale.Patch.resolve/2`
    digests it and compares against the patch's `base_digest` with zero
    tolerance.
  - `target/0` — where a resolved payload lands: a single `port_ref`, or a
    function fanning the payload out to `[{port_ref, value}]` pairs.
  """

  alias Coconut.{Patch, Resolve, Workspace}

  @callback projection(Workspace.t(), Patch.t()) :: {:ok, term()} | {:error, term()}

  @callback target() :: Resolve.port_ref() | (term() -> [{Resolve.port_ref(), term()}])
end
