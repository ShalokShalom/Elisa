defmodule HermesBeam.Repo.Migrations.CreateScratchpads do
  use Ecto.Migration

  def change do
    create table(:agent_scratchpads, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :uuid, null: false
      add :memory_text, :text, null: false, default: "System initialized. No memories yet."
      add :user_text, :text, null: false, default: "No user preferences recorded."

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_scratchpads, [:agent_id])
  end
end
