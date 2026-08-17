defmodule Minesweeper do
  use Breeze.View
  import Breeze.Blocks

  @cell_width 3
  @default_size %{width: 9, height: 9}
  @default_mine_count 10

  def mount(opts, term) do
    maybe_seed_rand(Keyword.get(opts, :seed))

    size = board_size(opts)
    initial_mines = initial_mines(opts, size)
    mine_count = mine_count(opts, size, initial_mines)

    {:ok,
     term
     |> assign(new_game(size, mine_count, initial_mines))
     |> put_local_keybindings([
       {"Arrows", "Move"},
       {"Space", "Reveal"},
       {"f", "Flag"},
       {"r", "Restart"}
     ])}
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        board_width: assigns.size.width * @cell_width,
        cells: build_cells(assigns),
        remaining_mines: assigns.mine_count - MapSet.size(assigns.flagged),
        status_label: status_label(assigns.status)
      )

    ~H"""
    <box class="width-screen height-screen bg">
      <box class="bold text-primary">Minesweeper</box>
      <box class="inline">
        <box class="width-15">Status: {@status_label}</box>
        <box class="width-16">Mines left: {@remaining_mines}</box>
        <box>Revealed: {MapSet.size(@revealed)}</box>
      </box>
      <box class="height-1">
      </box>
      <box
        class="border border-primary"
        style={"width-#{@board_width + 2} height-#{@size.height + 2}"}
      >
        <box :for={cell <- @cells} id={cell.id} class={cell.class}>{cell.label}</box>
      </box>
      <box class="height-1">
      </box>
      <box class={message_class(@status)}>{@message}</box>
      <box class="height-1">
      </box>
      <box class="height-1 bg-panel overflow-hidden">
        <.keybinding_bar keybindings={@breeze.keybindings}/>
      </box>
    </box>
    """
  end

  def handle_event(_, %{"key" => key}, term) when key in ["ArrowUp", "k"],
    do: {:noreply, move_cursor(term, {0, -1})}

  def handle_event(_, %{"key" => key}, term) when key in ["ArrowDown", "j"],
    do: {:noreply, move_cursor(term, {0, 1})}

  def handle_event(_, %{"key" => key}, term) when key in ["ArrowLeft", "h"],
    do: {:noreply, move_cursor(term, {-1, 0})}

  def handle_event(_, %{"key" => key}, term) when key in ["ArrowRight", "l"],
    do: {:noreply, move_cursor(term, {1, 0})}

  def handle_event(_, %{"key" => key}, term) when key in ["Enter", " ", "\r", "\n"],
    do: {:noreply, reveal_cursor(term)}

  def handle_event(_, %{"key" => key}, term) when key in ["f", "F"],
    do: {:noreply, toggle_flag(term)}

  def handle_event(_, %{"key" => key}, term) when key in ["r", "R"],
    do: {:noreply, restart(term)}

  def handle_event(
        _,
        %{"mouse" => %{"button" => "left", "action" => "press"}, "target" => target},
        term
      ) do
    case parse_cell_id(target) do
      {:ok, coord} -> {:noreply, term |> assign(cursor: coord) |> reveal_cursor()}
      :error -> {:noreply, term}
    end
  end

  def handle_event(
        _,
        %{"mouse" => %{"button" => "right", "action" => "press"}, "target" => target},
        term
      ) do
    case parse_cell_id(target) do
      {:ok, coord} -> {:noreply, term |> assign(cursor: coord) |> toggle_flag()}
      :error -> {:noreply, term}
    end
  end

  def handle_event(_, _, term), do: {:noreply, term}

  defp new_game(size, mine_count, initial_mines) do
    %{
      size: size,
      mine_count: mine_count,
      initial_mines: initial_mines,
      mines: initial_mines,
      revealed: MapSet.new(),
      flagged: MapSet.new(),
      cursor: {0, 0},
      status: :playing,
      message: "Reveal with Space or Enter. Flag with f. Restart with r."
    }
  end

  defp restart(%{assigns: assigns} = term) do
    assign(term, new_game(assigns.size, assigns.mine_count, assigns.initial_mines))
  end

  defp move_cursor(%{assigns: %{size: size, cursor: {x, y}}} = term, {dx, dy}) do
    assign(term, cursor: {clamp(x + dx, 0, size.width - 1), clamp(y + dy, 0, size.height - 1)})
  end

  defp reveal_cursor(%{assigns: %{status: status}} = term) when status != :playing, do: term

  defp reveal_cursor(%{assigns: assigns} = term) do
    coord = assigns.cursor

    if MapSet.member?(assigns.flagged, coord) do
      assign(term, message: "That square is flagged. Unflag it before revealing.")
    else
      reveal_unflagged(term, coord)
    end
  end

  defp reveal_unflagged(%{assigns: assigns} = term, coord) do
    mines = assigns.mines || lay_mines(assigns.size, assigns.mine_count, coord)
    mine? = MapSet.member?(mines, coord)

    revealed =
      if mine? do
        MapSet.put(assigns.revealed, coord)
      else
        reveal_cells(coord, mines, assigns.size, assigns.revealed, assigns.flagged)
      end

    cond do
      mine? ->
        assign(term,
          mines: mines,
          revealed: revealed,
          status: :lost,
          message: "Boom. Press r to try again."
        )

      won?(revealed, mines, assigns.size) ->
        assign(term,
          mines: mines,
          revealed: revealed,
          flagged: MapSet.union(assigns.flagged, mines),
          status: :won,
          message: "Cleared. Press r for another board."
        )

      true ->
        assign(term, mines: mines, revealed: revealed, message: "Keep going.")
    end
  end

  defp toggle_flag(%{assigns: %{status: status}} = term) when status != :playing, do: term

  defp toggle_flag(%{assigns: assigns} = term) do
    coord = assigns.cursor

    cond do
      MapSet.member?(assigns.revealed, coord) ->
        assign(term, message: "Revealed squares cannot be flagged.")

      MapSet.member?(assigns.flagged, coord) ->
        assign(term, flagged: MapSet.delete(assigns.flagged, coord), message: "Flag removed.")

      true ->
        assign(term, flagged: MapSet.put(assigns.flagged, coord), message: "Flag placed.")
    end
  end

  defp reveal_cells(start, mines, size, revealed, flagged) do
    do_reveal([start], MapSet.put(revealed, start), mines, size, flagged)
  end

  defp do_reveal([], revealed, _mines, _size, _flagged), do: revealed

  defp do_reveal([coord | queue], revealed, mines, size, flagged) do
    if adjacent_mine_count(coord, mines, size) == 0 do
      next =
        coord
        |> neighbors(size)
        |> Enum.reject(&MapSet.member?(mines, &1))
        |> Enum.reject(&MapSet.member?(flagged, &1))
        |> Enum.reject(&MapSet.member?(revealed, &1))

      revealed = Enum.reduce(next, revealed, &MapSet.put(&2, &1))
      do_reveal(queue ++ next, revealed, mines, size, flagged)
    else
      do_reveal(queue, revealed, mines, size, flagged)
    end
  end

  defp won?(revealed, mines, size) do
    MapSet.size(revealed) >= size.width * size.height - MapSet.size(mines)
  end

  defp lay_mines(size, mine_count, safe_coord) do
    safe_zone = MapSet.new([safe_coord | neighbors(safe_coord, size)])
    all_coords = coords(size)

    candidates =
      case Enum.reject(all_coords, &MapSet.member?(safe_zone, &1)) do
        values when length(values) >= mine_count -> values
        _values -> Enum.reject(all_coords, &(&1 == safe_coord))
      end

    candidates
    |> Enum.shuffle()
    |> Enum.take(mine_count)
    |> MapSet.new()
  end

  defp build_cells(assigns) do
    for y <- 0..(assigns.size.height - 1), x <- 0..(assigns.size.width - 1) do
      coord = {x, y}

      %{
        id: cell_id(coord),
        label: cell_label(coord, assigns),
        class: cell_class(coord, assigns)
      }
    end
  end

  defp cell_label(coord, assigns) do
    mines = assigns.mines || MapSet.new()
    revealed? = MapSet.member?(assigns.revealed, coord)
    flagged? = MapSet.member?(assigns.flagged, coord)
    mine? = MapSet.member?(mines, coord)

    cond do
      assigns.status == :won and mine? -> " F "
      assigns.status == :lost and mine? -> " * "
      assigns.status == :lost and flagged? -> " X "
      flagged? -> " F "
      revealed? -> revealed_label(coord, mines, assigns.size)
      true -> " . "
    end
  end

  defp revealed_label(coord, mines, size) do
    case adjacent_mine_count(coord, mines, size) do
      0 -> "   "
      count -> " #{count} "
    end
  end

  defp cell_class({x, y} = coord, assigns) do
    mines = assigns.mines || MapSet.new()
    base = "width-3 height-1 absolute left-#{x * @cell_width + 1} top-#{y + 1} text-center"
    state = cell_state_class(coord, assigns, mines)

    if coord == assigns.cursor do
      base <> " " <> state <> " bg-6 text-0 bold"
    else
      base <> " " <> state
    end
  end

  defp cell_state_class(coord, assigns, mines) do
    revealed? = MapSet.member?(assigns.revealed, coord)
    flagged? = MapSet.member?(assigns.flagged, coord)
    mine? = MapSet.member?(mines, coord)

    cond do
      assigns.status == :lost and mine? -> "bg-error text-bg bold"
      assigns.status == :lost and flagged? -> "bg-warning text-bg bold"
      assigns.status == :won and mine? -> "bg-success text-bg bold"
      flagged? -> "bg-warning text-bg bold"
      revealed? -> "bg-surface " <> number_class(adjacent_mine_count(coord, mines, assigns.size))
      true -> "bg-panel text-muted"
    end
  end

  defp number_class(0), do: "text-muted"
  defp number_class(1), do: "text-primary bold"
  defp number_class(2), do: "text-#22c55e bold"
  defp number_class(3), do: "text-error bold"
  defp number_class(4), do: "text-#4338ca bold"
  defp number_class(5), do: "text-#a16207 bold"
  defp number_class(6), do: "text-#0891b2 bold"
  defp number_class(7), do: "text-#f9fafb bold"
  defp number_class(_), do: "text-#94a3b8 bold"

  defp adjacent_mine_count(coord, mines, size) do
    coord
    |> neighbors(size)
    |> Enum.count(&MapSet.member?(mines, &1))
  end

  defp neighbors({x, y}, size) do
    for dy <- -1..1,
        dx <- -1..1,
        {dx, dy} != {0, 0},
        valid_coord?({x + dx, y + dy}, size),
        do: {x + dx, y + dy}
  end

  defp coords(size) do
    for y <- 0..(size.height - 1), x <- 0..(size.width - 1), do: {x, y}
  end

  defp valid_coord?({x, y}, size) do
    x >= 0 and x < size.width and y >= 0 and y < size.height
  end

  defp board_size(opts) do
    case Keyword.get(opts, :size) do
      {width, height} ->
        normalize_size(width, height)

      %{width: width, height: height} ->
        normalize_size(width, height)

      _ ->
        normalize_size(
          Keyword.get(opts, :width, @default_size.width),
          Keyword.get(opts, :height, @default_size.height)
        )
    end
  end

  defp normalize_size(width, height) do
    %{
      width: width |> to_int(@default_size.width) |> clamp(2, 30),
      height: height |> to_int(@default_size.height) |> clamp(2, 20)
    }
  end

  defp initial_mines(opts, size) do
    opts
    |> Keyword.get(:mine_coords)
    |> case do
      nil ->
        nil

      coords ->
        coords
        |> Enum.filter(&valid_coord?(&1, size))
        |> MapSet.new()
    end
  end

  defp mine_count(_opts, _size, %MapSet{} = initial_mines), do: MapSet.size(initial_mines)

  defp mine_count(opts, size, nil) do
    opts
    |> Keyword.get(:mine_count, Keyword.get(opts, :mines, @default_mine_count))
    |> to_int(@default_mine_count)
    |> clamp(1, size.width * size.height - 1)
  end

  defp parse_cell_id("cell-" <> rest) do
    case String.split(rest, "-", parts: 2) do
      [x, y] ->
        with {x, ""} <- Integer.parse(x),
             {y, ""} <- Integer.parse(y) do
          {:ok, {x, y}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_cell_id(_), do: :error

  defp cell_id({x, y}), do: "cell-#{x}-#{y}"

  defp status_label(:playing), do: "Playing"
  defp status_label(:won), do: "Won"
  defp status_label(:lost), do: "Lost"

  defp message_class(:won), do: "text-success bold"
  defp message_class(:lost), do: "text-error bold"
  defp message_class(_), do: "text-muted"

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  defp maybe_seed_rand(nil), do: :ok

  defp maybe_seed_rand({a, b, c}) do
    :rand.seed(:exsss, {a, b, c})
  end
end

Breeze.Example.run(
  [
    view: Minesweeper,
    hide_cursor: true,
    mouse: true,
    reload: false,
    inspector: [
      pages: [
        {Breeze.Timeline.Page, every: 1, limit: 60, include: [:frame, :inspector]}
      ]
    ],
    global_keybindings: [{"q", "Quit", fn _event, term -> {:stop, term} end}]
  ],
  keep_alive: :infinity
)
