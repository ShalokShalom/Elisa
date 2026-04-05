defmodule HermesBeam.Skill do
  @moduledoc """
  Autonomous Skill resource — a dynamically compiled Elixir module generated
  by the agent to handle repetitive tasks.

  Lifecycle:
  1. Agent recognises a repetitive pattern and generates Elixir source code.
  2. `:learn_skill` action triggers `CompileSkillModule`, compiling the code
     directly into the running BEAM VM and persisting it to Postgres.
  3. On subsequent turns, the skill is available as a callable Ash Action.
  4. If a skill fails, Reactor's `undo/3` triggers `:refine_skill`, prompting
     the LLM to rewrite the code given the error context.

  ## Execution tracking

  Call `record_execution/2` with `succeeded?: true | false` after each use.
  The `success_rate` is a rolling exponential moving average (alpha=0.1) so
  recent failures have more weight than ancient ones.
  """
  use Ash.Resource,
    domain: HermesBeam.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi.Resource]

  postgres do
    table "agent_skills"
    repo HermesBeam.Repo
  end

  ai do
    # Both actions are exposed as tools the LLM can call autonomously.
    action :learn_skill
    action :refine_skill
  end

  actions do
    defaults [:read, :destroy]

    create :learn_skill do
      accept [:name, :description, :elixir_code]
      change HermesBeam.Changes.CompileSkillModule
    end

    update :refine_skill do
      accept [:elixir_code]
      change HermesBeam.Changes.CompileSkillModule
    end

    update :record_execution do
      @doc """
      Record one execution result. Updates the execution count and
      computes a rolling EMA of success rate (alpha = 0.1).

      Call as:
          skill |> Ash.Changeset.for_update(:record_execution, %{succeeded?: true}) |> Ash.update()
      """
      accept [:succeeded?]

      change fn changeset, _ctx ->
        succeeded     = Ash.Changeset.get_argument(changeset, :succeeded?) || true
        current_count = Ash.Changeset.get_attribute(changeset, :execution_count) || 0
        current_rate  = Ash.Changeset.get_attribute(changeset, :success_rate) || 1.0

        # Exponential moving average: new_rate = 0.9 * old + 0.1 * outcome
        outcome   = if succeeded, do: 1.0, else: 0.0
        new_rate  = 0.9 * current_rate + 0.1 * outcome

        changeset
        |> Ash.Changeset.change_attribute(:execution_count, current_count + 1)
        |> Ash.Changeset.change_attribute(:success_rate, new_rate)
        |> Ash.Changeset.change_attribute(:last_executed_at, DateTime.utc_now())
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string, allow_nil?: false
    attribute :elixir_code, :string, allow_nil?: false
    attribute :module_name, :string
    attribute :execution_count, :integer, default: 0
    attribute :success_rate, :float, default: 1.0
    create_timestamp :inserted_at
    update_timestamp :updated_at
    attribute :last_executed_at, :utc_datetime
  end

  arguments do
    argument :succeeded?, :boolean, default: true
  end

  identities do
    identity :unique_skill_name, [:name]
  end
end
