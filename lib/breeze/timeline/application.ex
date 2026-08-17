defmodule Breeze.Timeline.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Breeze.Timeline.Recorder
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Breeze.Timeline.Supervisor)
  end
end
