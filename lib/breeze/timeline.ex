defmodule Breeze.Timeline do
  @moduledoc """
  Public API for an opt-in Breeze runtime timeline.

      Breeze.Server.start_link(
        view: MyApp.View,
        inspector: [
          pages: [
            {Breeze.Timeline.Page,
             every: 5,
             limit: 60,
             include: [:frame, :inspector]}
          ]
        ]
      )

  `Breeze.Timeline.Hook` supports:

    * `:every` - capture every N matching renders. Defaults to `1`.
    * `:limit` - retained checkpoints per server. Defaults to `120`.
    * `:include` - checkpoint attachments. Defaults to
      `[:frame, :inspector]`.
    * `:modes` - render modes to capture, `:full` and/or `:patch`.
    * `:exclude_causes` - render causes to ignore.
    * `:timeout` - timeout for capturing each view process. Defaults to
      `5_000` milliseconds.

  No capture occurs unless the timeline page contributes its hook (or the hook
  is configured directly as standalone runtime tooling).
  """

  alias Breeze.Timeline.Recorder

  @doc """
  Returns lightweight timeline entries for a server.

  Full runtime checkpoints and captured frame contents remain on the source
  node.
  """
  def timeline(server_pid) when is_pid(server_pid) do
    on_source_node(server_pid, :timeline_local, [server_pid])
  end

  @doc false
  def timeline_for_page(server_pid, subscriber, message)
      when is_pid(server_pid) and is_pid(subscriber) do
    on_source_node(server_pid, :timeline_for_page_local, [server_pid, subscriber, message])
  end

  @doc """
  Displays a retained checkpoint frame in the source application.

  Pass `"latest"` or `:live` to restore the application's current frame.
  """
  def display_frame(server_pid, selection, opts \\ [])
      when is_pid(server_pid) and is_list(opts) do
    on_source_node(server_pid, :display_frame_local, [server_pid, selection, opts])
  end

  @doc """
  Replaces the source application's runtime with a retained checkpoint.

  Newer timeline entries are discarded. The restored runtime remains paused
  until the next source-application interaction.
  """
  def rewind(server_pid, entry_id, opts \\ []) when is_pid(server_pid) and is_list(opts) do
    on_source_node(server_pid, :rewind_local, [server_pid, entry_id, opts])
  end

  @doc false
  def timeline_local(server_pid) do
    ensure_started()
    Recorder.timeline(server_pid)
  end

  @doc false
  def timeline_for_page_local(server_pid, subscriber, message) do
    ensure_started()
    Recorder.timeline(server_pid, subscribe: {subscriber, message})
  end

  @doc false
  def display_frame_local(server_pid, selection, opts) do
    ensure_started()

    if selection in [:live, "latest", nil, ""] do
      Breeze.Runtime.display_frame(server_pid, :live, opts)
    else
      with {:ok, frame} <- Recorder.frame(server_pid, selection) do
        Breeze.Runtime.display_frame(server_pid, frame, opts)
      end
    end
  end

  @doc false
  def rewind_local(server_pid, entry_id, opts) do
    ensure_started()
    Recorder.rewind(server_pid, entry_id, Keyword.put_new(opts, :pause_until_interaction, true))
  end

  defp on_source_node(server_pid, function, args) do
    if node(server_pid) == node() do
      apply(__MODULE__, function, args)
    else
      :erpc.call(node(server_pid), __MODULE__, function, args)
    end
  catch
    kind, reason -> {:error, {:remote_call_failed, kind, reason}}
  end

  defp ensure_started do
    case Application.ensure_all_started(:breeze_timeline) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, reason} -> raise "could not start breeze_timeline: #{inspect(reason)}"
    end
  end
end
