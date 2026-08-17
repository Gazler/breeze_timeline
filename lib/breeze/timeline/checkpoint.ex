defmodule Breeze.Timeline.Checkpoint do
  @moduledoc false

  alias Breeze.Runtime.{Context, State}

  defstruct [
    :captured_at,
    :source,
    :runtime_state,
    :screen,
    :frame,
    :inspector
  ]

  @type t :: %__MODULE__{
          captured_at: integer(),
          source: map() | nil,
          runtime_state: State.t(),
          screen: map() | nil,
          frame: map() | nil,
          inspector: map() | nil
        }

  @spec capture(Context.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def capture(context, opts \\ []) when is_list(opts) do
    include = opts |> Keyword.get(:include, []) |> List.wrap() |> MapSet.new()
    state_opts = Keyword.take(opts, [:timeout])

    with {:ok, runtime_state} <- Context.capture_state(context, state_opts) do
      metadata = Context.metadata(context)

      {:ok,
       new(runtime_state,
         captured_at: Map.fetch!(metadata, :system_time),
         source: %{
           node: node(Context.server_pid(context)),
           server_pid: Context.server_pid(context)
         },
         screen: Context.screen(context),
         frame: maybe_read(include, :frame, fn -> Context.frame(context) end),
         inspector: maybe_read(include, :inspector, fn -> Context.inspector(context) end)
       )}
    end
  rescue
    error ->
      {:error,
       "could not capture timeline checkpoint: " <>
         Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, "could not capture timeline checkpoint: #{inspect({kind, reason})}"}
  end

  @spec new(State.t(), keyword()) :: t()
  def new(runtime_state, opts \\ []) when is_list(opts) do
    %__MODULE__{
      captured_at: Keyword.get(opts, :captured_at, System.system_time(:millisecond)),
      source: Keyword.get(opts, :source),
      runtime_state: runtime_state,
      screen: Keyword.get(opts, :screen),
      frame: Keyword.get(opts, :frame),
      inspector: Keyword.get(opts, :inspector)
    }
  end

  defp maybe_read(include, key, read) do
    if MapSet.member?(include, key), do: read.()
  end
end
