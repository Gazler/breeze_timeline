defmodule Breeze.TimelineTest do
  use ExUnit.Case, async: false

  defmodule FakeAdapter do
    @behaviour Termite.Terminal.Adapter

    def start(_opts) do
      {:ok, %{ref: make_ref(), size: %{width: 80, height: 24}}}
    end

    def reader(terminal), do: {:ok, terminal.ref}
    def write(terminal, _content), do: {:ok, terminal}
    def resize(terminal), do: terminal.size
  end

  defmodule Counter do
    use Breeze.View

    def mount(_opts, term), do: {:ok, term |> assign(count: 0) |> focus("counter")}

    def render(assigns) do
      ~H"""
      <box id="counter" focusable>count={@count}</box>
      """
    end

    def handle_event(_, %{"key" => "+"}, term) do
      {:noreply, assign(term, count: term.assigns.count + 1)}
    end

    def handle_event(_, %{"key" => "-"}, term) do
      {:noreply, assign(term, count: term.assigns.count - 1)}
    end

    def handle_event(_, _, term), do: {:noreply, term}
  end

  defmodule TimelinePageHarness do
    use Breeze.View

    def mount(opts, term) do
      {:ok,
       term
       |> assign(
         source_server_pid: Keyword.fetch!(opts, :source_server_pid),
         page_state: %{}
       )
       |> focus("breeze-timeline")}
    end

    def render(assigns) do
      assigns.page_state
      |> Map.put(:source_server_pid, assigns.source_server_pid)
      |> Map.put(:breeze, assigns.breeze)
      |> Breeze.Timeline.Page.render()
    end

    def handle_event(event, payload, term) do
      page_assigns =
        term.assigns.page_state
        |> Map.put(:source_server_pid, term.assigns.source_server_pid)
        |> Map.put(:breeze, term.assigns.breeze)

      {:noreply, page_state} =
        Breeze.Timeline.Page.handle_event(event, payload, page_assigns)

      {:noreply, assign(term, page_state: page_state)}
    end
  end

  test "minesweeper cursor changes both the cell background and dot color" do
    session =
      Breeze.Test.start!(Minesweeper,
        size: {20, 10},
        theme: Breeze.Theme.builtin(:gruvbox),
        start_opts: [size: {2, 2}, mine_coords: [{1, 1}]]
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    assert Breeze.Test.render!(session) =~
             "\e[1;48;5;6;38;5;0m . "
  end

  test "minesweeper keyboard and mouse batches each record one checkpoint" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)

    assert :ready =
             Breeze.Theme.Probe.finish_runtime_palette_probe(terminal, %{
               1 => {170, 34, 51},
               2 => {34, 170, 51},
               3 => {204, 187, 51},
               4 => {51, 85, 170},
               5 => {153, 51, 170},
               6 => {51, 170, 170},
               9 => {221, 102, 68},
               10 => {68, 204, 85},
               11 => {230, 209, 90},
               12 => {95, 123, 224},
               13 => {179, 107, 212},
               14 => {90, 214, 214},
               background: {16, 17, 18},
               foreground: {240, 240, 240}
             })

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Minesweeper,
        terminal: terminal,
        theme: :system,
        start_opts: [size: {2, 2}, mine_coords: [{1, 1}]],
        inspector: [
          remote: false,
          pages: [
            {Breeze.Timeline.Page, every: 1, limit: 60, include: [:frame, :inspector]}
          ]
        ],
        global_keybindings: [{"q", "Quit", fn _event, term -> {:stop, term} end}]
      )

    on_exit(fn -> Process.exit(pid, :normal) end)

    wait_until(fn -> Breeze.Timeline.timeline(pid).count >= 1 end)
    Process.sleep(25)
    assert Breeze.Timeline.timeline(pid).count == 1

    send(pid, {terminal.reader, {:data, "\e[C"}})

    wait_until(fn ->
      state = :sys.get_state(pid)

      state.input.pending_ref == nil and not state.input.flush_scheduled? and
        :queue.is_empty(state.input.queued_input) and Breeze.Timeline.timeline(pid).count >= 2
    end)

    Process.sleep(25)

    assert %{count: 2, entries: [_, latest]} = Breeze.Timeline.timeline(pid)
    assert latest.metadata.cause in [:event_reply, :input_flush]

    state = :sys.get_state(pid)
    bounds = Breeze.ChildServer.layout_snapshot(state.view_pid).mouse_targets["cell-0-0"]
    x = div(bounds.left + bounds.right, 2) + 1
    y = div(bounds.top + bounds.bottom, 2) + 1

    :ok = :sys.suspend(pid)
    send(pid, {terminal.reader, {:data, "\e[<0;#{x};#{y}M"}})
    send(pid, {terminal.reader, {:data, "\e[<0;#{x};#{y}m"}})
    :ok = :sys.resume(pid)

    wait_until(fn ->
      state = :sys.get_state(pid)

      not state.input.flush_scheduled? and :queue.is_empty(state.input.queued_input) and
        Breeze.Timeline.timeline(pid).count >= 3
    end)

    Process.sleep(25)

    assert %{count: 3, entries: [_, _, latest]} = Breeze.Timeline.timeline(pid)
    assert latest.metadata.cause == :input_flush

    state = :sys.get_state(pid)
    assert Breeze.ChildServer.metadata(state.view_pid).assigns.cursor == {0, 0}
  end

  test "capture is sampled, bounded, and replays historical frames" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)
    reader = terminal.reader

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Counter,
        terminal: terminal,
        inspector: [
          pages: [{Breeze.Timeline.Page, every: 2, limit: 2}]
        ]
      )

    Enum.each(1..5, fn _ ->
      send(pid, {reader, {:data, "+"}})
      wait_until(fn -> :queue.is_empty(:sys.get_state(pid).input.queued_input) end)
    end)

    timeline =
      wait_until(fn ->
        case Breeze.Timeline.timeline(pid) do
          %{count: 2} = timeline -> timeline
          _ -> false
        end
      end)

    assert timeline.limit == 2
    assert [earlier, latest] = timeline.entries
    assert latest.id == earlier.id + 1
    refute Map.has_key?(hd(timeline.entries), :checkpoint)
    assert %{line_count: line_count} = latest.frame
    assert line_count > 0
    refute Map.has_key?(latest.frame, :lines)
    refute Map.has_key?(timeline, :selected)

    rendered_page =
      Breeze.Renderer.render_to_string(
        Breeze.Timeline.Page,
        %{source_server_pid: pid, selected_entry: Integer.to_string(latest.id)},
        terminal: terminal,
        theme: true
      )

    assert rendered_page =~ "entries=2/2"
    assert rendered_page =~ "Checkpoint"
    assert rendered_page =~ "Checkpoint ##{latest.id} is shown in the source application."
    refute rendered_page =~ "count=5"

    assert {:noreply, historical_state} =
             Breeze.Timeline.Page.handle_event(
               "timeline_changed",
               %{value: Integer.to_string(earlier.id)},
               %{source_server_pid: pid}
             )

    historical_page =
      Breeze.Renderer.render_to_string(
        Breeze.Timeline.Page,
        Map.put(historical_state, :source_server_pid, pid),
        terminal: terminal,
        theme: true
      )

    assert historical_page =~ "selected=#{earlier.id}"

    assert historical_page =~
             "Checkpoint ##{earlier.id} is shown in the source application."

    source_state = :sys.get_state(pid)
    assert source_state.frame.display_owner == self()
    assert Enum.join(source_state.frame.display.lines, "\n") != ""
    refute Enum.join(source_state.frame.display.lines, "\n") =~ "count=5"

    source_key = {node(), inspect(pid)}
    inspector_snapshot = Breeze.Server.Diagnostics.inspector_snapshot(pid)

    assert [%{id: page_id, module: Breeze.Timeline.Page}] = inspector_snapshot.pages

    rendered_inspector =
      Breeze.Renderer.render_to_string(
        Breeze.RemoteInspector.View,
        %{
          snapshots: %{
            source_key => %{
              source: %{node: node(), pid: pid},
              snapshot: inspector_snapshot,
              updated_at: System.system_time(:millisecond),
              alive?: true
            }
          },
          latest_source: source_key,
          active_source: source_key,
          panel_tab: page_id,
          render_tree_kind: "rendered",
          render_trees: %{},
          render_tree_expanded: %{},
          custom_page_states: %{{source_key, page_id} => historical_state},
          screen: terminal.size
        },
        terminal: terminal,
        theme: true
      )

    assert rendered_inspector =~ "entries=2/2"
    assert rendered_inspector =~ "Checkpoint"
    assert rendered_inspector =~ "Checkpoint ##{earlier.id} is shown in the source"
    assert rendered_inspector =~ "application."
    refute rendered_inspector =~ "count=5"

    assert {:noreply, %{selected_entry: "latest", page_error: nil}} =
             Breeze.Timeline.Page.handle_event(
               "timeline_changed",
               %{value: "latest"},
               %{source_server_pid: pid, selected_entry: Integer.to_string(earlier.id)}
             )

    state = :sys.get_state(pid)
    assert is_nil(state.frame.display)
    assert Breeze.ChildServer.metadata(state.view_pid).assigns.count == 5

    Process.exit(pid, :normal)
  end

  test "recording and restoring notify the subscribed inspector page" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Counter,
        terminal: terminal,
        inspector: [
          remote: false,
          pages: [{Breeze.Timeline.Page, every: 1, limit: 10}]
        ]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    wait_until(fn -> Breeze.Timeline.timeline(pid).count >= 1 end)

    page_ref = {{node(), inspect(pid)}, "page:Elixir.Breeze.Timeline.Page"}
    page_assigns = %{source_server_pid: pid, page_ref: page_ref}

    Breeze.Renderer.render_to_string(Breeze.Timeline.Page, page_assigns,
      terminal: terminal,
      theme: true
    )

    baseline_count = Breeze.Timeline.timeline(pid).count
    send(pid, {terminal.reader, {:data, "+"}})

    assert_receive {:remote_inspector_page, ^page_ref, :timeline_updated}, 1_000

    timeline =
      wait_until(fn ->
        timeline = Breeze.Timeline.timeline(pid)
        if timeline.count > baseline_count, do: timeline, else: false
      end)

    wait_until(fn -> :queue.is_empty(:sys.get_state(pid).input.queued_input) end)
    Process.sleep(25)
    drain_timeline_updates(page_ref)

    assert {:ok, _entry} = Breeze.Timeline.rewind(pid, hd(timeline.entries).id)
    assert_receive {:remote_inspector_page, ^page_ref, :timeline_updated}, 1_000
  end

  test "Enter on live latest does not restore the most recent checkpoint" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Counter,
        terminal: terminal,
        inspector: [
          pages: [{Breeze.Timeline.Page, every: 2, limit: 10}]
        ]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    send(pid, {terminal.reader, {:data, "+"}})

    wait_until(fn ->
      state = :sys.get_state(pid)

      :queue.is_empty(state.input.queued_input) and
        Breeze.ChildServer.metadata(state.view_pid).assigns.count == 1 and
        Breeze.Timeline.timeline(pid).count == 1
    end)

    send(pid, {terminal.reader, {:data, "+"}})

    wait_until(fn ->
      state = :sys.get_state(pid)

      :queue.is_empty(state.input.queued_input) and
        Breeze.ChildServer.metadata(state.view_pid).assigns.count == 2
    end)

    before = :sys.get_state(pid)
    assert Breeze.Timeline.timeline(pid).count == 1

    assert {:noreply, %{selected_entry: "latest", restored_entry: nil, page_error: nil}} =
             Breeze.Timeline.Page.handle_event(
               "keydown",
               %{"key" => "Enter"},
               %{source_server_pid: pid, selected_entry: "latest"}
             )

    after_enter = :sys.get_state(pid)

    assert after_enter.view_pid == before.view_pid
    refute after_enter.frame.resume_on_input?
    assert Breeze.ChildServer.metadata(after_enter.view_pid).assigns.count == 2
    assert Breeze.Timeline.timeline(pid).count == 1
  end

  test "Enter restores the selected checkpoint, truncates newer frames, and resumes on input" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)
    reader = terminal.reader

    {:ok, pid} =
      Breeze.Server.start_app_link(
        view: Counter,
        terminal: terminal,
        inspector: [
          pages: [{Breeze.Timeline.Page, every: 1, limit: 10}]
        ]
      )

    initial_timeline_count =
      wait_until(fn ->
        case Breeze.Timeline.timeline(pid).count do
          count when count >= 1 -> count
          _count -> false
        end
      end)

    Enum.each(1..3, fn expected ->
      send(pid, {reader, {:data, "+"}})

      wait_until(fn ->
        state = :sys.get_state(pid)

        :queue.is_empty(state.input.queued_input) and
          Breeze.ChildServer.metadata(state.view_pid).assigns.count == expected and
          Breeze.Timeline.timeline(pid).count >= initial_timeline_count + expected
      end)
    end)

    timeline =
      wait_until(fn ->
        case Breeze.Timeline.timeline(pid) do
          %{entries: entries} = timeline when length(entries) >= 4 -> timeline
          _timeline -> false
        end
      end)

    selected = Enum.at(timeline.entries, -2)
    newer_ids = timeline.entries |> Enum.filter(&(&1.id > selected.id)) |> Enum.map(& &1.id)
    assert newer_ids != []

    assert {:ok, selected_frame} = Breeze.Timeline.Recorder.frame(pid, selected.id)
    selected_content = Enum.join(selected_frame.lines, "\n")
    [_, selected_count] = Regex.run(~r/count=(-?\d+)/, selected_content)
    selected_count = String.to_integer(selected_count)
    assert {:ok, stale_runtime_state} = Breeze.Runtime.capture_state(pid)

    stale_checkpoint =
      Breeze.Timeline.Checkpoint.new(stale_runtime_state, screen: terminal.size)

    stale_sequence = System.unique_integer([:monotonic, :positive])

    old_view_pid = :sys.get_state(pid).view_pid

    assert {:noreply, page_state} =
             Breeze.Timeline.Page.handle_event(
               "keydown",
               %{"key" => "Enter"},
               %{
                 source_server_pid: pid,
                 selected_entry: Integer.to_string(selected.id)
               }
             )

    assert page_state.selected_entry == "latest"
    assert page_state.restored_entry == selected.id
    assert is_nil(page_state.page_error)

    restored_timeline = Breeze.Timeline.timeline(pid)

    assert Enum.map(restored_timeline.entries, & &1.id) ==
             timeline.entries
             |> Enum.filter(&(&1.id <= selected.id))
             |> Enum.map(& &1.id)

    refute Enum.any?(restored_timeline.entries, &(&1.id in newer_ids))

    Breeze.Timeline.Recorder.record(
      pid,
      {:ok, stale_checkpoint},
      %{cause: :stale, mode: :full, timeline_sequence: stale_sequence},
      limit: 10
    )

    after_stale_record = Breeze.Timeline.timeline(pid)
    assert after_stale_record.entries == restored_timeline.entries

    restored = :sys.get_state(pid)
    refute restored.view_pid == old_view_pid
    assert restored.frame.resume_on_input?
    assert restored.view_pid in restored.frame.display_suspended_pids
    assert Enum.join(restored.frame.display.lines, "\n") =~ "count=#{selected_count}"

    restored_page =
      Breeze.Renderer.render_to_string(
        Breeze.Timeline.Page,
        Map.put(page_state, :source_server_pid, pid),
        terminal: terminal,
        theme: true
      )

    assert restored_page =~ "selected=latest"

    assert restored_page =~
             "Checkpoint ##{selected.id} was restored; the timeline now continues from it."

    send(pid, {reader, {:data, "-"}})

    wait_until(fn ->
      state = :sys.get_state(pid)

      not state.frame.resume_on_input? and is_nil(state.frame.display) and
        Breeze.ChildServer.metadata(state.view_pid).assigns.count == selected_count - 1
    end)

    branched_timeline =
      wait_until(fn ->
        timeline = Breeze.Timeline.timeline(pid)

        if length(timeline.entries) > length(restored_timeline.entries),
          do: timeline,
          else: false
      end)

    branched_entries =
      Enum.drop(branched_timeline.entries, length(restored_timeline.entries))

    assert Enum.map(branched_entries, & &1.id) ==
             Enum.to_list((selected.id + 1)..(selected.id + length(branched_entries)))

    branched_entry = List.last(branched_entries)
    assert {:ok, branched_frame} = Breeze.Timeline.Recorder.frame(pid, branched_entry.id)

    assert Enum.join(branched_frame.lines, "\n") =~ "count=#{selected_count - 1}"

    Process.exit(pid, :normal)
  end

  test "timeline keyboard selection stays inside the tree viewport" do
    terminal = Termite.Terminal.start(adapter: FakeAdapter)
    reader = terminal.reader

    {:ok, source_pid} =
      Breeze.Server.start_app_link(
        view: Counter,
        terminal: terminal,
        inspector: [
          pages: [{Breeze.Timeline.Page, every: 1, limit: 60}]
        ]
      )

    initial_timeline_count =
      wait_until(fn ->
        case Breeze.Timeline.timeline(source_pid).count do
          count when count >= 1 -> count
          _count -> false
        end
      end)

    Enum.each(1..10, fn expected ->
      send(source_pid, {reader, {:data, "+"}})

      wait_until(fn ->
        :queue.is_empty(:sys.get_state(source_pid).input.queued_input) and
          Breeze.Timeline.timeline(source_pid).count >= initial_timeline_count + expected
      end)
    end)

    wait_until(fn ->
      Breeze.Timeline.timeline(source_pid).count >= 11
    end)

    {:ok, page_pid} =
      Breeze.ChildServer.start(
        view: TimelinePageHarness,
        start_opts: [source_server_pid: source_pid],
        terminal: terminal
      )

    on_exit(fn ->
      if Process.alive?(page_pid), do: GenServer.stop(page_pid)
      if Process.alive?(source_pid), do: Process.exit(source_pid, :normal)
    end)

    {:ok, _acc, _box} =
      Breeze.ChildServer.render(page_pid,
        focused: "breeze-timeline",
        implicit_state: %{}
      )

    Enum.each(1..10, fn _ ->
      assert {:noreply, "breeze-timeline", true} =
               Breeze.ChildServer.dispatch_input(page_pid, "ArrowDown")
    end)

    metadata = Breeze.ChildServer.metadata(page_pid)
    selected = metadata.assigns.page_state.selected_entry

    selected_entry =
      source_pid
      |> Breeze.Timeline.timeline()
      |> Map.fetch!(:entries)
      |> Enum.find(&(Integer.to_string(&1.id) == selected))

    {:ok, _acc, box} =
      Breeze.ChildServer.render(page_pid,
        focused: "breeze-timeline",
        implicit_state: %{}
      )

    content = BackBreeze.Utils.strip_escape_chars(box.content)

    assert content =~ "selected=#{selected}"

    assert content =~
             "##{selected} #{selected_entry.metadata.cause} #{selected_entry.metadata.mode}"

    assert {:noreply, "breeze-timeline", true} =
             Breeze.ChildServer.dispatch_input(page_pid, "Enter")

    assert {:ok, _acc, _box} =
             Breeze.ChildServer.render(page_pid,
               focused: "breeze-timeline",
               implicit_state: %{}
             )

    metadata = Breeze.ChildServer.metadata(page_pid)
    assert metadata.assigns.page_state.selected_entry == "latest"

    assert {Breeze.Implicit.List, %{selected: "latest", offset: 0}} =
             metadata.implicit_state["breeze-timeline"]
  end

  test "hook ignores renders caused by leaving historical frame display" do
    state =
      Breeze.Timeline.Hook.init(
        [recorder: self(), include: []],
        %{server_pid: self()}
      )

    assert_receive {:"$gen_cast", {:register, server_pid, limit: 120}}
    assert server_pid == self()

    state =
      Enum.reduce([:frame_display_restore, :frame_display_owner_down], state, fn cause, state ->
        assert {:noreply, state} =
                 Breeze.Timeline.Hook.handle_event(
                   :rendered,
                   hook_context(%{mode: :full, cause: cause}),
                   state
                 )

        state
      end)

    assert state.render_count == 0
    refute_receive {:"$gen_cast", {:record, _, _, _, _}}
  end

  test "hook sampling counts only matching render events" do
    state =
      Breeze.Timeline.Hook.init(
        [
          recorder: self(),
          every: 2,
          include: [],
          modes: [:full],
          exclude_causes: [:ignored]
        ],
        %{server_pid: self()}
      )

    assert_receive {:"$gen_cast", {:register, server_pid, limit: 120}}
    assert server_pid == self()

    assert {:noreply, state} =
             Breeze.Timeline.Hook.handle_event(
               :rendered,
               hook_context(%{mode: :patch, cause: :input}),
               state
             )

    assert state.render_count == 0

    assert {:noreply, state} =
             Breeze.Timeline.Hook.handle_event(
               :rendered,
               hook_context(%{mode: :full, cause: :ignored}),
               state
             )

    assert state.render_count == 0

    assert {:noreply, state} =
             Breeze.Timeline.Hook.handle_event(
               :rendered,
               hook_context(%{mode: :full, cause: :input}),
               state
             )

    assert state.render_count == 1

    assert {:noreply, state} =
             Breeze.Timeline.Hook.handle_event(
               :rendered,
               hook_context(%{mode: :full, cause: :input}),
               state
             )

    assert state.render_count == 2

    assert_receive {:"$gen_cast",
                    {:record, ^server_pid, {:ok, %Breeze.Timeline.Checkpoint{}}, metadata,
                     limit: 120}}

    assert metadata.mode == :full
    assert metadata.cause == :input
    assert is_integer(metadata.timeline_sequence)
  end

  defp hook_context(metadata) do
    metadata =
      Map.merge(
        %{
          server_pid: self(),
          view: Counter,
          screen: %{width: 80, height: 24},
          system_time: System.system_time(:millisecond),
          monotonic_time: System.monotonic_time(:millisecond)
        },
        metadata
      )

    %Breeze.Runtime.Context{
      metadata: metadata,
      capture_state: fn _opts -> {:ok, %Breeze.Runtime.State{view: Counter}} end,
      frame: fn -> %{width: 80, height: 24, lines: [], overlays: []} end,
      inspector: fn -> %{} end
    }
  end

  defp drain_timeline_updates(page_ref) do
    receive do
      {:remote_inspector_page, ^page_ref, :timeline_updated} ->
        drain_timeline_updates(page_ref)
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met")
end
