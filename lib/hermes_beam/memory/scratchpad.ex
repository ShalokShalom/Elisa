defmodule HermesBeam.Memory.Scratchpad do
  @moduledoc """
  Bounded, LLM-managed working memory — the BEAM equivalent of Hermes Agent's
  `MEMORY.md` and `USER.md` text files.

  The LLM is entirely responsible for curating what goes here. Ash validates
  the character limits so the agent is forced to consolidate rather than
  endlessly append. Postgres ACID guarantees eliminate the file-locking races
  that would occur with raw text files across a distributed cluster.

  Limits mirror the Hermes Agent spec:
    memory_text ≤ 2,200 characters
    user_text   ≤ 1,375 characters
  """
  use Ash.Resource,
    domain: HermesBeam.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi.Resource]

  postgres do
    table "agent_scratchpads"
    repo HermesBeam.Repo
  end

  ai do
    # Expose :curate_memory to the LLM as a tool it can call autonomously.
    action :curate_memory
  end

  actions do
    defaults [:read, :destroy]

    create :initialize do
      accept [:agent_id, :memory_text, :user_text]
    end

    update :curate_memory do
      @doc """
      The LLM calls this action to overwrite its working memory and user
      profile. Both fields have hard character limits enforced at the
      database validation layer — the agent must condense before saving.
      """
      ai? true
      accept [:memory_text, :user_text]

      validate string_length(:memory_text, max: 2_200),
        message: "memory_text exceeds 2,200 characters. Condense before saving."

      validate string_length(:user_text, max: 1_375),
        message: "user_text exceeds 1,375 characters. Condense before saving."
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_id, :uuid, allow_nil?: false

    attribute :memory_text, :string,
      default: "System initialized. No memories yet.",
      allow_nil?: false

    attribute :user_text, :string,
      default: "No user preferences recorded.",
      allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One scratchpad per logical agent.
    identity :unique_agent, [:agent_id]
  end
end
