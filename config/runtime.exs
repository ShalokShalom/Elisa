import Config

# ---------------------------------------------------------------------------
# NODE_TYPE: "hub" | "worker"  (default: "worker")
# NODE_ROLE: "gaming_gpu" | "mac_mini_pro" | "mac_mini_base"  (default: "mac_mini_base")
# HUB_IP:   Tailscale IP of the central Hub machine
# ---------------------------------------------------------------------------
node_type = System.get_env("NODE_TYPE", "worker")
hub_ip    = System.get_env("HUB_IP", "127.0.0.1")
node_role = System.get_env("NODE_ROLE", "mac_mini_base")

# ---------------------------------------------------------------------------
# Model tier map — determines which Bumblebee models are loaded on this node.
# ---------------------------------------------------------------------------
loaded_tiers =
  case node_role do
    "gaming_gpu" ->
      [
        {:tier_1_reasoning, "meta-llama/Meta-Llama-3-70B-Instruct"},
        {:tier_2_general,   "meta-llama/Meta-Llama-3-8B-Instruct"}
      ]

    "mac_mini_pro" ->
      [
        {:tier_2_general, "meta-llama/Meta-Llama-3-8B-Instruct"},
        {:tier_3_docs,    "microsoft/Phi-3-mini-4k-instruct"}
      ]

    _base ->
      [
        {:tier_3_docs, "microsoft/Phi-3-mini-4k-instruct"}
      ]
  end

config :hermes_beam, :topology,
  type: node_type,
  role: node_role,
  hub_ip: hub_ip,
  active_tiers: loaded_tiers

# ---------------------------------------------------------------------------
# Embedding model
# Dimensions must match the `dimensions:` constraint in episodic.ex.
#   "local/bge-small-en-v1.5"          -> 384  (default, any hardware)
#   "nomic-ai/nomic-embed-text-v1.5"   -> 768  (Mac Mini Pro+)
#   (OpenAI text-embedding-3-large)    -> 3072  (cloud only)
# ---------------------------------------------------------------------------
embedding_model = System.get_env("HERMES_EMBEDDING_MODEL", "local/bge-small-en-v1.5")
config :hermes_beam, embedding_model: embedding_model

# ---------------------------------------------------------------------------
# Synthetic data agent identity
# Required by IdleScheduler. Use a fixed UUIDv4 so synthetic memories are
# attributed to a stable agent identity across restarts and renames.
# Generate one with: mix run -e 'IO.puts(Ecto.UUID.generate())'
# ---------------------------------------------------------------------------
config :hermes_beam,
  synthetic_agent_id:
    System.get_env("SYNTHETIC_AGENT_ID") ||
      raise """
      SYNTHETIC_AGENT_ID environment variable is not set.
      Generate a stable UUID for the synthetic memory agent and export it:

          export SYNTHETIC_AGENT_ID=$(mix run -e 'IO.puts(Ecto.UUID.generate())')

      Or set it permanently in your .env / release config.
      """

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
db_host =
  if node_type == "hub", do: "localhost", else: hub_ip

config :hermes_beam, HermesBeam.Repo,
  hostname: db_host,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASS", "postgres"),
  database: System.get_env("DB_NAME", "hermes_beam"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  ssl: node_type != "hub"

# ---------------------------------------------------------------------------
# libcluster_postgres
# ---------------------------------------------------------------------------
config :hermes_beam, :libcluster,
  topologies: [
    postgres_mesh: [
      strategy: Cluster.Strategy.Postgres,
      config: [
        hostname: db_host,
        username: System.get_env("DB_USER", "postgres"),
        password: System.get_env("DB_PASS", "postgres"),
        database: System.get_env("DB_NAME", "hermes_beam"),
        port: 5432,
        channel_name: "hermes_beam_cluster"
      ]
    ]
  ]

# ---------------------------------------------------------------------------
# Phoenix Endpoint (production / runtime)
# ---------------------------------------------------------------------------
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :hermes_beam, HermesBeamWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: secret_key_base
end

# ---------------------------------------------------------------------------
# LLM API Keys (optional — only needed if using cloud LLM providers)
# ---------------------------------------------------------------------------
if key = System.get_env("OPENAI_API_KEY") do
  config :ash_ai, openai_api_key: key
end
