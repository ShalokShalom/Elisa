defmodule HermesBeam.WorkflowLog do
  @moduledoc """
  Ash Resource that persists every Reactor workflow execution.

  Populated via `:telemetry` handlers attached to Reactor step events.
  The `steps` attribute is a free-form map keyed by step name atom:

      %{
        fetch_memories: %{started_at: dt, finished_at: dt, status: :ok},
        execute_inference: %{started_at: dt, status: :running}
      }

  Read by the Livebook dashboard (Section 3) and, in Phase 7-LV,
  by `WorkflowLive`.
  """
  use Ash.Resource,
    domain: HermesBeam.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "workflow_logs"
    repo HermesBeam.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:workflow_name, :input_snapshot]
    end

    update :update_step do
      accept [:steps]
    end

    update :complete do
      accept []

      change fn changeset, _ctx ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :completed)
        |> Ash.Changeset.change_attribute(:finished_at, DateTime.utc_now())
      end
    end

    update :fail do
      accept [:error_reason]

      change fn changeset, _ctx ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :failed)
        |> Ash.Changeset.change_attribute(:finished_at, DateTime.utc_now())
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :workflow_name, :string, allow_nil?: false

    attribute :status, :atom,
      constraints: [one_of: [:running, :completed, :failed]],
      default: :running,
      allow_nil?: false

    # Snapshot of the input map for retry support
    attribute :input_snapshot, :map, default: %{}

    # Step-level timing map: step_name -> %{started_at, finished_at, status}
    attribute :steps, :map, default: %{}

    attribute :error_reason, :string

    create_timestamp :started_at
    update_timestamp :finished_at
  end
end
