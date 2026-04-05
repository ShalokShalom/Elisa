defmodule HermesBeam.Memory.Episodic do
  @moduledoc """
  Episodic (long-term) memory for the agent, stored as high-dimensional
  vector embeddings in Postgres via pgvector.

  Unlike the `Scratchpad` which is explicitly bounded and curated by the LLM,
  episodic memory grows over time and is queried semantically: the system
  embeds the current user prompt and retrieves the top-K most similar past
  interactions, injecting them into the LLM's context window.

  ## Local-first embedding

  Default model: `"local/bge-small-en-v1.5"` — 384 dimensions, runs on any node.
  For higher recall quality set `HERMES_EMBEDDING_MODEL` to one of:

    | Model                              | Dims | Hardware         |
    |------------------------------------|------|------------------|
    | local/bge-small-en-v1.5 (default)  |  384 | any              |
    | nomic-ai/nomic-embed-text-v1.5     |  768 | Mac Mini Pro +   |
    | text-embedding-3-large (OpenAI)    | 3072 | cloud only       |

  If you change model, also update `dimensions:` below and run a migration to
  rebuild the `content_vector` column and IVFFlat index.

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
        # Model is resolved from the environment at application boot.
        # The default (bge-small, 384-dim) matches the `dimensions:` constraint
        # below. If you change model, change dimensions too.
        model Application.get_env(:hermes_beam, :embedding_model, "local/bge-small-en-v1.5")
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

    # dimensions: 384 = bge-small-en-v1.5 (default)
    # Change to 768 for nomic-embed, 3072 for text-embedding-3-large.
    # Any change requires a migration to rebuild this column and its index.
    attribute :content_vector, Ash.Type.Vector,
      constraints: [dimensions: 384],
      allow_nil?: true

    create_timestamp :inserted_at
  end
end
