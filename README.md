# Breeze Timeline

`breeze_timeline` is an opt-in runtime timeline for Breeze. It is separate
from the core runtime so applications that do not configure it do not retain
or copy runtime state.

## Installation

Add `breeze_timeline` to your dependencies:

```elixir
def deps do
  [
    {:breeze_timeline, "~> 0.1.0"}
  ]
end
```

Register the timeline page on each Breeze server that should be recorded:

```elixir
Breeze.Server.start_link(
  view: MyApp.View,
  inspector: [
    pages: [
      {Breeze.Timeline.Page,
       every: 1,
       limit: 120,
       include: [:frame, :inspector]}
    ]
  ]
)
```

The page contributes its `Breeze.Timeline.Hook` to the source server through
Breeze's custom-page `:runtime_hooks` integration. No separate hook
configuration is required.

`every` controls sampling and `limit` bounds retained checkpoints. The default
is one capture per rendered state and 120 retained entries, but no capture
occurs unless the timeline page or hook is explicitly configured.

To enable it conditionally, build the options in the application:

```elixir
inspector =
  if Application.get_env(:my_app, :timeline, false) do
    [pages: [{Breeze.Timeline.Page, every: 1, limit: 120}]]
  else
    false
  end

Breeze.Server.start_link(view: MyApp.View, inspector: inspector)
```

Timeline recording adds render latency and memory usage. Checkpoint capture
is synchronous and copies the configured server's view runtime tree. Treat the
timeline as development tooling: keep it disabled in production unless there
is a specific operational reason to enable it and its sampling and retention
have been chosen for the workload. For larger applications, increase `every`,
reduce `limit`, or omit optional `:frame` / `:inspector` attachments from
`include`. Omitting `:frame` disables historical frame preview, but checkpoints
can still be restored.


```bash
mix breeze.inspector
```

## Breeze Inspector Page

The timeline starts on `live latest`. Selecting a checkpoint pauses the source
application's view runtime and renders that captured frame in the inspector
terminal, so stepping through entries shows exactly what the app displayed at
each capture. Select `live latest` to resume the application without changing
its state. Press `Enter` to discard every newer checkpoint and replace the
running app with the selected state. The restored runtime stays paused until
the next source-app interaction, and that interaction is processed normally.
Restoring a checkpoint does not rerun the view's `mount/2` callback.

Restore replaces Breeze-owned runtime state. Process mailboxes and external
side effects are not rewound, and values such as PIDs, ports, references, or
functions inside user assigns remain ordinary in-VM values.

## Example

The package includes a minesweeper example with timeline capture configured.
Run the application and inspector in separate terminals from this package:

```bash
# terminal 1
mix run examples/minesweeper.exs

# terminal 2
mix breeze.inspector
```

The core Breeze examples remain timeline-independent.
