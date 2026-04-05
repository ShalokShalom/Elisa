defmodule HermesBeam.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:agent_skills, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :description, :text, null: false
      add :elixir_code, :text, null: false
      add :module_name, :string
      add :execution_count, :integer, default: 0, null: false
      add :success_rate, :float, default: 1.0, null: false
      add :last_executed_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_skills, [:name])
  end
end
