defmodule Coconut.Render.Channel do
  @moduledoc """
  Channel contract for `Coconut.Render.Resolve`.

  A channel is one data facet the engine consumes (lyric, phoneme, phoneme
  duration, pitch, ...). Channels are deliberately *not* hardcoded: any
  module implementing this behaviour can be registered in the channel map
  passed to `Coconut.Render.Resolve.run_check/3`, next to plain ad-hoc spec maps.

  Each channel supplies:

  - `projection/2` — produces the fresh base slice for a patch's anchor
    region: a canonical term (see `Tamale.Digest`). `Tamale.Patch.resolve/2`
    digests it and compares against the patch's `base_digest` with zero
    tolerance.
  - `target/0` or `target/1` — where a resolved payload lands: a single
    `port_ref`, or a function fanning the payload out to
    `[{port_ref, value}]` pairs. `target/1` additionally receives the
    patch, for ports derived from the anchor (e.g. per-note ports like
    `{:port, note_id, :pitch}`). At least one of the two must be exported.
  """

  alias Coconut.Edit.{Patch, Workspace}
  alias Coconut.Render.Resolve

  @callback projection(Workspace.t(), Patch.t()) :: {:ok, term()} | {:error, term()}

  @callback target() :: Resolve.port_ref() | (term() -> [{Resolve.port_ref(), term()}])

  @callback target(Patch.t()) ::
              Resolve.port_ref() | (term() -> [{Resolve.port_ref(), term()}])

  @optional_callbacks target: 0, target: 1
end
