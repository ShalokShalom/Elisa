defmodule HermesBeam.Memory.Episodic do
  @moduledoc """
  Episodic (long-term) memory for the agent, stored as high-dimensional
  vector embeddings in Postgres via pgvector.

  Unlike the `Scratchpad` which is explicitly bounded and curated by the
  LLM, episodic memory grows over time and is queried semantically:
  the system embeds the current user prompt and retrieves the top-K most
  similar past interactions, injecting them into the LLM's context window.

  Embeddings are generated automatically by Ash AI using the configured
  embedding model (default: OpenAI text-embedding-3-large, 3072 dimensions;
  swap for a local Bumblebee embedding model to stay fully air-gapped).
  """
  use Ash.Resource,
    domain: HermesBeam.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi.Resource]

  postgres do
    table "agent_memories"
    repo HermesBeam.Repo

    custom_indexes do
      # IVFFlat approximate nearest-neighbour index for fast vector recall.
      index [:content_vector],
        name: "agent_memories_vector_idx",
        using: "ivfflat",
        with: [lists: 100]
    end
  end

  ai do
    embeddings do
      embed :content_vector do
        source :content
        model "text-embedding-3-large"
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :store do
      accept [:content, :type, :agent_id]
    end

    read :recall_similar do
      @doc """
      Returns the top-K episodic memories most semantically similar to
      the given query string, using pgvector cosine similarity.
      """
      argument :query, :string, allow_nil?: false

      prepare AshAi.Query.VectorSearch.new(
        vector_attribute: :content_vector,
        query_argument: :query,
        limit: 5
      )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_id, :uuid, allow_nil?: false

    attribute :content, :string, allow_nil?: false

    attribute :type, :atom,
      constraints: [one_of: [:observation, :reflection, :user_fact, :synthetic]],
      default: :observation,
      allow_nil?: false

    attribute :content_vector, Ash.Type.Vector,
      constraints: [dimensions: 3072],
      allow_nil?: true

    create_timestamp :inserted_at
  end
end
