defmodule HermesBeam.Telemetry.WorkflowHandler do
  @moduledoc """
  Telemetry handler that attaches to Reactor step events and writes
  structured entries to `WorkflowLog`.

  Attached on every node (Hub and Workers) via `HermesBeam.Application`
  so that Worker-originated Reactor events are also captured.

  The ETS table `@table` is local to each node and maps
  `reactor_id -> WorkflowLog.id`. Since all Reactor events for a given run
  fire on the same node that called `Reactor.run/3`, this is safe: an event
  emitted on a Worker will look up the ETS entry that was inserted on the
  same Worker, then write to the shared Hub Postgres via Ecto over Tailscale.

  Reactor emits these events (reactor ~> 0.9):
    [:reactor, :run, :start]
    [:reactor, :run, :stop]
    [:reactor, :step, :run, :start]
    [:reactor, :step, :run, :stop]
  """
  require Logger

  @table :workflow_log_index

  def attach do
    unless :ets.whereis(@table) != :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :telemetry.attach_many(
      "hermes-beam-workflow-handler",
      [
        [:reactor, :run, :start],
        [:reactor, :run, :stop],
        [:reactor, :step, :run, :start],
        [:reactor, :step, :run, :stop]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:reactor, :run, :start], _measurements, metadata, _config) do
    workflow_name = inspect(metadata[:reactor])

    case HermesBeam.WorkflowLog
         |> Ash.ActionInput.for_create(:create, %{
           workflow_name: workflow_name,
           input_snapshot: metadata[:inputs] || %{}
         })
         |> Ash.create() do
      {:ok, log} ->
        :ets.insert(@table, {metadata[:id], log.id})

      {:error, reason} ->
        Logger.warning("[WorkflowHandler] Failed to create log: #{inspect(reason)}")
    end
  end

  def handle_event([:reactor, :run, :stop], measurements, metadata, _config) do
    case :ets.lookup(@table, metadata[:id]) do
      [{_reactor_id, log_id}] ->
        with {:ok, log} <- Ash.get(HermesBeam.WorkflowLog, log_id) do
          action = if measurements[:error], do: :fail, else: :complete
          attrs  = if measurements[:error], do: %{error_reason: inspect(measurements[:error])}, else: %{}

          log
          |> Ash.ActionInput.for_update(action, attrs)
          |> Ash.update()
        end

        :ets.delete(@table, metadata[:id])

      [] ->
        :ok
    end
  end

  def handle_event([:reactor, :step, :run, :start], _measurements, metadata, _config) do
    update_step(metadata[:id], metadata[:step_name], %{
      started_at: DateTime.utc_now(),
      status: :running
    })
  end

  def handle_event([:reactor, :step, :run, :stop], measurements, metadata, _config) do
    update_step(metadata[:id], metadata[:step_name], %{
      finished_at: DateTime.utc_now(),
      status: if(measurements[:error], do: :failed, else: :ok)
    })
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp update_step(reactor_id, step_name, attrs) do
    case :ets.lookup(@table, reactor_id) do
      [{_reactor_id, log_id}] ->
        with {:ok, log} <- Ash.get(HermesBeam.WorkflowLog, log_id) do
          updated_steps = Map.put(log.steps || %{}, to_string(step_name), attrs)

          log
          |> Ash.ActionInput.for_update(:update_step, %{steps: updated_steps})
          |> Ash.update()
        end

      [] ->
        :ok
    end
  end
end
