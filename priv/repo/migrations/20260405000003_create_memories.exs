defmodule HermesBeam.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:agent_memories, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :uuid, null: false
      add :content, :text, null: false
      add :type, :string, null: false, default: "observation"
      # pgvector column: 3072 dimensions (text-embedding-3-large)
      add :content_vector, :vector, size: 3072

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:agent_memories, [:agent_id])
    create index(:agent_memories, [:type])
    # IVFFlat index added via Ash custom_index after data is loaded
  end
end
