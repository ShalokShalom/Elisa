defmodule HermesBeam.Repo.Migrations.CreateWorkflowLogs do
  use Ecto.Migration

  def change do
    create table(:workflow_logs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :workflow_name, :string, null: false
      add :status, :string, null: false, default: "running"
      add :input_snapshot, :map, default: %{}
      add :steps, :map, default: %{}
      add :error_reason, :text

      add :started_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")

      add :finished_at, :utc_datetime_usec
    end

    create index(:workflow_logs, [:workflow_name])
    create index(:workflow_logs, [:status])
    create index(:workflow_logs, [:started_at])
  end
end
