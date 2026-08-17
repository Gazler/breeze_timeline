defmodule Breeze.Timeline.Hook do
  @moduledoc """
  Runtime hook that captures Breeze timeline checkpoints.

  The timeline page installs this hook automatically. It can also be configured
  directly through a Breeze server's `:runtime_hooks` option when checkpoint
  recording is needed without the inspector page.

  ## Options

    * `:every` - captures every N matching renders. Defaults to `1`.
    * `:limit` - retains at most this many checkpoints. Defaults to `120`.
    * `:include` - checkpoint attachments. Defaults to
      `[:frame, :inspector]`.
    * `:modes` - render modes to capture. Defaults to `[:full, :patch]`.
    * `:exclude_causes` - render causes to ignore.
    * `:timeout` - timeout for capturing each view process. Defaults to `5_000`
      milliseconds.
  """

  @behaviour Breeze.Runtime.Hook

  alias Breeze.Runtime.Context
  alias Breeze.Timeline.{Checkpoint, Recorder}

  @default_limit 120
  @default_include [:frame, :inspector]
  @default_excluded_causes [
    :frame_display_owner_down,
    :frame_display_restore,
    :inspector_move,
    :inspector_toggle,
    :remote_inspector_select
  ]

  @impl true
  def init(opts, metadata) do
    state = %{
      server_pid: metadata.server_pid,
      recorder: Keyword.get(opts, :recorder, Recorder),
      every: normalize_every(Keyword.get(opts, :every, 1)),
      limit: normalize_limit(Keyword.get(opts, :limit, @default_limit)),
      include: Keyword.get(opts, :include, @default_include) |> List.wrap(),
      modes: Keyword.get(opts, :modes, [:full, :patch]) |> List.wrap(),
      exclude_causes: Keyword.get(opts, :exclude_causes, @default_excluded_causes) |> List.wrap(),
      timeout: Keyword.get(opts, :timeout, 5_000),
      render_count: 0
    }

    Recorder.register(state.recorder, state.server_pid, limit: state.limit)
    state
  end

  @impl true
  def handle_event(:rendered, context, state) do
    metadata = Context.metadata(context)

    if matching_render?(metadata, state) do
      state = %{state | render_count: state.render_count + 1}

      if rem(state.render_count, state.every) == 0 do
        result =
          Checkpoint.capture(context,
            include: state.include,
            timeout: state.timeout
          )

        metadata =
          Map.put(metadata, :timeline_sequence, System.unique_integer([:monotonic, :positive]))

        Recorder.record(state.recorder, state.server_pid, result, metadata, limit: state.limit)
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp matching_render?(metadata, state) do
    Map.get(metadata, :mode) in state.modes and
      Map.get(metadata, :cause) not in state.exclude_causes
  end

  defp normalize_every(value) when is_integer(value), do: max(value, 1)
  defp normalize_every(_value), do: 1

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(1_000)
  defp normalize_limit(_value), do: @default_limit
end
