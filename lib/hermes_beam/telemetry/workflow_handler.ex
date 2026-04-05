defmodule HermesBeam.Telemetry.WorkflowHandler do
  @moduledoc """
  Telemetry handler that attaches to Reactor step events and writes
  structured entries to `WorkflowLog`.

  Attach this handler once at application startup via
  `HermesBeam.Telemetry.WorkflowHandler.attach/0`.

  Reactor emits these events (as of reactor ~> 0.9):
    [:reactor, :run, :start]
    [:reactor, :run, :stop]
    [:reactor, :step, :run, :start]
    [:reactor, :step, :run, :stop]

  The `metadata` map for step events includes:
    %{reactor_id: id, step_name: atom, input: map}
  """
  require Logger

  # In-memory ETS table to map reactor_id -> WorkflowLog.id
  # so step events can update the correct log row without a DB lookup.
  @table :workflow_log_index

  def attach do
    :ets.new(@table, [:named_table, :public, :set])

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
    input_snapshot = metadata[:inputs] || %{}

    case HermesBeam.WorkflowLog
         |> Ash.ActionInput.for_create(:create, %{
           workflow_name: workflow_name,
           input_snapshot: input_snapshot
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
        action = if measurements[:error], do: :fail, else: :complete
        error_reason = if measurements[:error], do: inspect(measurements[:error]), else: nil

        case Ash.get(HermesBeam.WorkflowLog, log_id) do
          {:ok, log} ->
            attrs = if error_reason, do: %{error_reason: error_reason}, else: %{}

            log
            |> Ash.ActionInput.for_update(action, attrs)
            |> Ash.update()

          _ -> :ok
        end

        :ets.delete(@table, metadata[:id])

      [] -> :ok
    end
  end

  def handle_event([:reactor, :step, :run, :start], _measurements, metadata, _config) do
    update_step(metadata[:id], metadata[:step_name], %{
      started_at: DateTime.utc_now(),
      status: :running
    })
  end

  def handle_event([:reactor, :step, :run, :stop], measurements, metadata, _config) do
    status = if measurements[:error], do: :failed, else: :ok

    update_step(metadata[:id], metadata[:step_name], %{
      finished_at: DateTime.utc_now(),
      status: status
    })
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp update_step(reactor_id, step_name, attrs) do
    case :ets.lookup(@table, reactor_id) do
      [{_reactor_id, log_id}] ->
        case Ash.get(HermesBeam.WorkflowLog, log_id) do
          {:ok, log} ->
            updated_steps = Map.put(log.steps || %{}, to_string(step_name), attrs)

            log
            |> Ash.ActionInput.for_update(:update_step, %{steps: updated_steps})
            |> Ash.update()

          _ -> :ok
        end

      [] -> :ok
    end
  end
end
