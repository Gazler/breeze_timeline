defmodule Breeze.Timeline.Page do
  @moduledoc """
  Remote inspector page for recorded Breeze runtime checkpoints.
  """

  use Breeze.RemoteInspector.Page
  import Breeze.Blocks
  import Breeze.RemoteInspector.Page, only: [source_server_pid: 1]

  def page(opts) do
    [label: "Timeline", runtime_hooks: [{Breeze.Timeline.Hook, opts}]]
  end

  def render(assigns) do
    timeline = fetch_timeline_for_page(source_server_pid(assigns), assigns)
    entries = Map.get(timeline, :entries, [])
    selection = resolve_selection(requested_selection(assigns), entries)
    selected_id = selection_value(selection)
    selected = selected_entry(entries, selection)
    restored_entry = Map.get(assigns, :restored_entry)

    assigns =
      Map.merge(assigns, %{
        timeline: timeline,
        entries: entries,
        items: timeline_items(entries),
        selected_id: selected_id,
        selected: selected,
        can_restore: match?({:checkpoint, _id}, selection),
        restored_entry: restored_entry,
        page_error: Map.get(assigns, :page_error) || Map.get(assigns, :custom_page_error)
      })

    ~H"""
    <box class="width-full height-full padding-top-1 overflow-hidden">
      <box class="width-full text-muted">{timeline_status(@timeline, @selected_id)}</box>
      <.list
        :if={@items != []}
        id="breeze-timeline"
        list-selected={@selected_id}
        selected-indicator=" "
        loop="false"
        virtual
        virtual_window={32}
        br-change="timeline_changed"
        class="width-full height-10 bg"
      >
        <:item :for={item <- @items} value={item.id}>{item.label}</:item>
      </.list>
      <box :if={@items == []} class="width-full text-muted">
        Waiting for configured runtime captures...
      </box>
      <box :if={!is_nil(@selected)} class="width-full bold text-primary">Checkpoint</box>
      <box :if={!is_nil(@selected)} class="width-full">{entry_detail(@selected)}</box>
      <box :if={!is_nil(@selected)} class="width-full text-muted">{inspector_detail(@selected)}</box>
      <box class="width-full text-muted">{source_display_status(@selected_id, @restored_entry)}</box>
      <box :if={@can_restore} class="width-full text-muted">Enter=restore</box>
      <box :if={!is_nil(@page_error)} class="width-full text-error">{@page_error}</box>
    </box>
    """
  end

  def handle_event("timeline_changed", payload, assigns) do
    selected = Map.get(payload, :value) || Map.get(payload, "value")
    selection = parse_selection(selected)

    case display_selection(assigns, selection) do
      :ok ->
        {:noreply,
         page_state(assigns,
           selected_entry: selection_value(selection),
           restored_entry: nil,
           page_error: nil
         )}

      {:error, reason} ->
        {:noreply,
         page_state(assigns,
           selected_entry: selection_value(selection),
           restored_entry: nil,
           page_error: inspect(reason)
         )}
    end
  end

  def handle_event(_, %{"key" => "Enter"}, assigns) do
    {:noreply, restore_selection(assigns, requested_selection(assigns))}
  end

  def handle_event(_event, _payload, assigns), do: {:noreply, page_state(assigns)}

  def handle_info(:timeline_updated, assigns), do: {:noreply, page_state(assigns)}

  defp fetch_timeline(pid) when is_pid(pid) do
    normalize_timeline(Breeze.Timeline.timeline(pid))
  end

  defp fetch_timeline(_pid), do: %{entries: [], count: 0}

  defp fetch_timeline_for_page(pid, %{page_ref: page_ref} = assigns)
       when is_pid(pid) and not is_nil(page_ref) do
    message = Breeze.RemoteInspector.Page.message(assigns, :timeline_updated)
    normalize_timeline(Breeze.Timeline.timeline_for_page(pid, self(), message))
  end

  defp fetch_timeline_for_page(pid, _assigns), do: fetch_timeline(pid)

  defp normalize_timeline(result) do
    case result do
      %{} = timeline -> timeline
      {:error, reason} -> %{entries: [], count: 0, error: reason}
    end
  end

  defp resolve_selection({:checkpoint, id} = selection, entries) do
    if Enum.any?(entries, &(&1.id == id)), do: selection, else: :live
  end

  defp resolve_selection(_selection, _entries), do: :live

  defp timeline_items(entries) do
    latest = [%{id: "latest", label: "live latest"}]

    entries =
      entries
      |> Enum.reverse()
      |> Enum.map(fn entry ->
        %{
          id: Integer.to_string(entry.id),
          label: "##{entry.id} #{entry_label(entry)}"
        }
      end)

    latest ++ entries
  end

  defp entry_label(%{event: :capture_error}), do: "capture error"

  defp entry_label(entry) do
    metadata = Map.get(entry, :metadata, %{})
    "#{Map.get(metadata, :cause, :render)} #{Map.get(metadata, :mode, :unknown)}"
  end

  defp timeline_status(%{error: error}, _selected), do: "timeline error=#{inspect(error)}"

  defp timeline_status(timeline, selected) do
    "entries=#{Map.get(timeline, :count, 0)}/#{Map.get(timeline, :limit, 0)} selected=#{selected}"
  end

  defp entry_detail(entry) do
    metadata = Map.get(entry, :metadata, %{})

    "id=#{entry.id} cause=#{Map.get(metadata, :cause, "-")} mode=#{Map.get(metadata, :mode, "-")} at=#{entry.at}"
  end

  defp inspector_detail(%{inspector: inspector}) when is_map(inspector) do
    "focused=#{Map.get(inspector, :focused) || "-"} selected=#{Map.get(inspector, :selected_id) || "-"}"
  end

  defp inspector_detail(_entry), do: "inspector=-"

  defp source_display_status(selected_id, restored_entry) do
    cond do
      is_integer(restored_entry) ->
        "Checkpoint ##{restored_entry} was restored; the timeline now continues from it."

      selected_id == "latest" ->
        "Source application is rendering live."

      true ->
        "Checkpoint ##{selected_id} is shown in the source application."
    end
  end

  defp selected_entry(entries, :live), do: List.last(entries)

  defp selected_entry(entries, {:checkpoint, id}) do
    Enum.find(entries, &(&1.id == id))
  end

  defp display_selection(_assigns, :invalid), do: {:error, :invalid_selection}

  defp display_selection(assigns, selection) do
    case source_server_pid(assigns) do
      server_pid when is_pid(server_pid) ->
        Breeze.Timeline.display_frame(server_pid, selection_target(selection), owner: self())

      _server_pid ->
        {:error, :missing_source}
    end
  end

  defp requested_selection(assigns) do
    assigns
    |> Map.get(:selected_entry, "latest")
    |> parse_selection()
  end

  defp parse_selection(selected) when selected in [:live, "latest", nil, ""], do: :live

  defp parse_selection(id) when is_integer(id) and id > 0, do: {:checkpoint, id}

  defp parse_selection(selected) when is_binary(selected) do
    case Integer.parse(selected) do
      {id, ""} when id > 0 -> {:checkpoint, id}
      _invalid -> :invalid
    end
  end

  defp parse_selection(_selected), do: :invalid

  defp selection_value(:live), do: "latest"
  defp selection_value({:checkpoint, id}), do: Integer.to_string(id)
  defp selection_value(:invalid), do: "latest"

  defp selection_target(:live), do: :live
  defp selection_target({:checkpoint, id}), do: id

  defp restore_selection(assigns, :live), do: page_state(assigns)

  defp restore_selection(assigns, {:checkpoint, id}) do
    with server_pid when is_pid(server_pid) <- source_server_pid(assigns),
         {:ok, entry} <- Breeze.Timeline.rewind(server_pid, id) do
      page_state(assigns,
        selected_entry: "latest",
        restored_entry: entry.id,
        page_error: nil
      )
    else
      {:error, reason} ->
        page_state(assigns,
          restored_entry: nil,
          page_error: inspect(reason)
        )

      _missing_source ->
        selection_error(assigns)
    end
  end

  defp restore_selection(assigns, :invalid), do: selection_error(assigns)

  defp selection_error(assigns) do
    page_state(assigns,
      restored_entry: nil,
      page_error: "select a checkpoint first"
    )
  end

  defp page_state(assigns, updates \\ []) do
    %{
      selected_entry: Keyword.get(updates, :selected_entry, Map.get(assigns, :selected_entry)),
      restored_entry: Keyword.get(updates, :restored_entry, Map.get(assigns, :restored_entry)),
      page_error: Keyword.get(updates, :page_error, Map.get(assigns, :page_error))
    }
  end
end
