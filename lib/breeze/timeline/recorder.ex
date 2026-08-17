defmodule Breeze.Timeline.Recorder do
  @moduledoc false

  use GenServer

  @default_limit 120

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(server \\ __MODULE__, server_pid, opts) do
    GenServer.cast(server, {:register, server_pid, opts})
  end

  def record(server \\ __MODULE__, server_pid, result, metadata, opts) do
    GenServer.cast(server, {:record, server_pid, result, metadata, opts})
  end

  def timeline(server_pid, opts \\ []) do
    GenServer.call(__MODULE__, {:timeline, server_pid, opts})
  end

  def frame(server_pid, entry_id) do
    GenServer.call(__MODULE__, {:frame, server_pid, entry_id})
  end

  def rewind(server_pid, entry_id, opts \\ []) do
    GenServer.call(__MODULE__, {:rewind, server_pid, entry_id, opts}, :infinity)
  end

  @impl true
  def init(_) do
    {:ok,
     %{
       sources: %{},
       source_monitors: %{},
       subscriptions: %{},
       subscription_monitors: %{}
     }}
  end

  @impl true
  def handle_cast({:register, server_pid, opts}, state) do
    state =
      state
      |> ensure_source(server_pid, opts)
      |> ensure_source_monitor(server_pid)

    {:noreply, state}
  end

  def handle_cast({:record, server_pid, result, metadata, opts}, state) do
    state =
      state
      |> ensure_source(server_pid, opts)
      |> ensure_source_monitor(server_pid)
      |> append_result(server_pid, result, metadata)
      |> notify_subscribers(server_pid)

    {:noreply, state}
  end

  @impl true
  def handle_call({:timeline, server_pid, opts}, _from, state) do
    state = maybe_subscribe(state, server_pid, opts)
    source = Map.get(state.sources, server_pid, new_source([]))

    {:reply,
     %{
       server_pid: server_pid,
       count: length(source.entries),
       limit: source.limit,
       entries: Enum.map(source.entries, &public_entry/1)
     }, state}
  end

  def handle_call({:frame, server_pid, entry_id}, _from, state) do
    reply =
      with {:ok, entry} <- fetch_entry(state, server_pid, entry_id),
           %{lines: lines} = frame when is_list(lines) <- entry.checkpoint.frame do
        {:ok, frame}
      else
        nil -> {:error, :frame_not_captured}
        {:error, reason} -> {:error, reason}
        _frame -> {:error, :frame_not_captured}
      end

    {:reply, reply, state}
  end

  def handle_call({:rewind, server_pid, entry_id, opts}, _from, state) do
    with {:ok, entry} <- fetch_entry(state, server_pid, entry_id),
         :ok <- Breeze.Runtime.replace_state(server_pid, entry.checkpoint.runtime_state),
         :ok <- maybe_pause(server_pid, opts) do
      discard_through = timeline_sequence()

      source = Map.fetch!(state.sources, server_pid)
      entries = Enum.take_while(source.entries, &(&1.id <= entry.id))

      source = %{
        source
        | entries: entries,
          next_id: entry.id + 1,
          discard_through: discard_through
      }

      state =
        state
        |> put_in([:sources, server_pid], source)
        |> notify_subscribers(server_pid)

      {:reply, {:ok, public_entry(entry)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      other -> {:reply, {:error, other}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      server_pid = Map.get(state.source_monitors, ref) ->
        {:noreply, drop_source(state, server_pid, ref)}

      subscription_key = Map.get(state.subscription_monitors, ref) ->
        {:noreply,
         %{
           state
           | subscriptions: Map.delete(state.subscriptions, subscription_key),
             subscription_monitors: Map.delete(state.subscription_monitors, ref)
         }}

      true ->
        {:noreply, state}
    end
  end

  defp ensure_source(state, server_pid, opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))

    update_in(state.sources, fn sources ->
      Map.update(sources, server_pid, new_source(limit: limit), &%{&1 | limit: limit})
    end)
  end

  defp ensure_source_monitor(state, server_pid) do
    if Enum.any?(state.source_monitors, fn {_ref, pid} -> pid == server_pid end) do
      state
    else
      put_in(state, [:source_monitors, Process.monitor(server_pid)], server_pid)
    end
  end

  defp maybe_subscribe(state, server_pid, opts) do
    case Keyword.get(opts, :subscribe) do
      {subscriber, message} when is_pid(subscriber) ->
        key = {server_pid, subscriber, message}

        if Map.has_key?(state.subscriptions, key) do
          state
        else
          ref = Process.monitor(subscriber)

          state
          |> put_in([:subscriptions, key], ref)
          |> put_in([:subscription_monitors, ref], key)
        end

      _subscription ->
        state
    end
  end

  defp notify_subscribers(state, server_pid) do
    Enum.each(state.subscriptions, fn
      {{^server_pid, subscriber, message}, _ref} -> send(subscriber, message)
      {_key, _ref} -> :ok
    end)

    state
  end

  defp append_result(state, server_pid, result, metadata) do
    update_in(state.sources[server_pid], fn source ->
      if stale_record?(source, metadata) do
        source
      else
        append_result(source, result, metadata)
      end
    end)
  end

  defp append_result(source, {:ok, checkpoint}, metadata) do
    entry = %{
      id: source.next_id,
      at: checkpoint.captured_at,
      event: :rendered,
      metadata: metadata,
      checkpoint: checkpoint
    }

    append_entry(source, entry)
  end

  defp append_result(source, {:error, reason}, metadata) do
    entry = %{
      id: source.next_id,
      at: System.system_time(:millisecond),
      event: :capture_error,
      metadata: metadata,
      error: reason,
      checkpoint: nil
    }

    append_entry(source, entry)
  end

  defp append_entry(source, entry) do
    %{
      source
      | next_id: source.next_id + 1,
        entries: Enum.take(source.entries ++ [entry], -source.limit)
    }
  end

  defp stale_record?(%{discard_through: discard_through}, %{timeline_sequence: sequence})
       when is_integer(discard_through) and is_integer(sequence) do
    sequence <= discard_through
  end

  defp stale_record?(_source, _metadata), do: false

  defp fetch_entry(state, server_pid, entry_id) do
    id = normalize_id(entry_id)

    case get_in(state.sources, [server_pid, :entries]) do
      entries when is_list(entries) ->
        case Enum.find(entries, &(&1.id == id and not is_nil(&1.checkpoint))) do
          nil -> {:error, :unknown_checkpoint}
          entry -> {:ok, entry}
        end

      _ ->
        {:error, :unknown_source}
    end
  end

  defp public_entry(entry) do
    checkpoint = Map.get(entry, :checkpoint)

    %{
      id: entry.id,
      at: entry.at,
      event: entry.event,
      metadata: Map.delete(entry.metadata, :timeline_sequence),
      error: Map.get(entry, :error),
      frame: checkpoint && frame_summary(checkpoint.frame),
      inspector: checkpoint && inspector_summary(checkpoint.inspector),
      screen: checkpoint && checkpoint.screen
    }
  end

  defp frame_summary(%{lines: lines, overlays: overlays} = frame) do
    %{
      width: Map.get(frame, :width, 0),
      height: Map.get(frame, :height, 0),
      line_count: length(lines || []),
      overlay_count: length(overlays || [])
    }
  end

  defp frame_summary(_frame), do: nil

  defp inspector_summary(inspector) when is_map(inspector) do
    Map.take(inspector, [
      :enabled?,
      :visible?,
      :selected_id,
      :hovered_id,
      :focused,
      :last_render_at,
      :last_interaction_at,
      :counts
    ])
  end

  defp inspector_summary(_inspector), do: nil

  defp drop_source(state, server_pid, ref) do
    {source_subscriptions, subscriptions} =
      Enum.split_with(state.subscriptions, fn
        {{^server_pid, _subscriber, _message}, _ref} -> true
        {_key, _ref} -> false
      end)

    subscription_refs = Enum.map(source_subscriptions, fn {_key, monitor_ref} -> monitor_ref end)
    Enum.each(subscription_refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | sources: Map.delete(state.sources, server_pid),
        source_monitors: Map.delete(state.source_monitors, ref),
        subscriptions: Map.new(subscriptions),
        subscription_monitors: Map.drop(state.subscription_monitors, subscription_refs)
    }
  end

  defp new_source(opts) do
    %{
      limit: normalize_limit(Keyword.get(opts, :limit, @default_limit)),
      next_id: 1,
      entries: [],
      discard_through: nil
    }
  end

  defp timeline_sequence, do: System.unique_integer([:monotonic, :positive])

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(1_000)
  defp normalize_limit(_value), do: @default_limit

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> value
    end
  end

  defp normalize_id(value), do: value

  defp maybe_pause(server_pid, opts) do
    if Keyword.get(opts, :pause_until_interaction, true) do
      Breeze.Runtime.pause(server_pid)
    else
      :ok
    end
  end
end
