defmodule HermesBeam.Memory.Episodic do
  @moduledoc """
  Episodic (long-term) memory for the agent, stored as high-dimensional
  vector embeddings in Postgres via pgvector.

  Unlike the `Scratchpad` which is explicitly bounded and curated by the LLM,
  episodic memory grows over time and is queried semantically: the system
  embeds the current user prompt and retrieves the top-K most similar past
  interactions, injecting them into the LLM's context window.

  ## Local-first embedding

  The embedding model is resolved from the `HERMES_EMBEDDING_MODEL` environment
  variable (default: `"local/bge-small-en-v1.5"`). This keeps the project
  aligned with its sovereign, air-gapped design — no call is ever made to
  `api.openai.com`. For best quality on Mac Mini Pro / Gaming PC hardware,
  set this to `"nomic-ai/nomic-embed-text-v1.5"` (768-dim, adjust the
  `dimensions` constraint and IVFFlat `lists` accordingly).

  ## IVFFlat performance note

  The IVFFlat approximate nearest-neighbour index becomes effective only after
  approximately `lists * 39 = 3,900` rows exist in `agent_memories`. Below that
  threshold Postgres falls back to a sequential scan — this is correct behaviour
  and will not cause errors, only slightly slower recall in early operation.
  """
  use Ash.Resource,
    domain: HermesBeam.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi.Resource]

  postgres do
    table "agent_memories"
    repo HermesBeam.Repo

    custom_indexes do
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
        # Resolved at runtime from env to keep embedding provider swappable.
        # Default: local BGE-small (384-dim). Change dimensions below if you
        # switch to a larger model such as nomic-embed (768-dim).
        model System.get_env("HERMES_EMBEDDING_MODEL", "local/bge-small-en-v1.5")
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
      Returns the top-5 episodic memories most semantically similar to the
      given query string, using pgvector cosine similarity.
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
