# Coconut🥥

> This lib is still in the early stages of development,
> and the API may undergo significant changes in later versions.

~~A headless SVS Editor~~ An engine-agnostic editor core that treats user intervention as first-class.

## Facade

Host applications can keep one pure session value and use `Coconut` as the
application boundary:

```elixir
{:ok, session} =
  Coconut.new(project,
    channels: %{timing: MyApp.TimingChannel},
    engine: {MyApp.Engine, engine_config}
  )

{:ok, session} = Coconut.edit(session, gesture)

{:ok, session, patch} =
  Coconut.mount(session, "vocal", note_id, :timing, %{deltas: %{preutterance: 24}})

{:ok, session, artifact} = Coconut.render(session)
{:ok, project} = Coconut.project(session)
```

The facade owns edit history, patch mounting and resolution, request creation,
and check/render sequencing. Import formats, voicebank loading, and artifact
I/O remain host concerns. `Coconut.Edit.*` and `Coconut.Render.*` are the
lower-level extension APIs for importers and custom policies.

Run the complete lifecycle example with:

```shell
mix run examples/facade.exs
```
