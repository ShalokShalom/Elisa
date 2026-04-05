defmodule HermesBeam.Application do
  @moduledoc """
  The OTP Application entry point for Hermes BEAM.

  The supervision tree is shaped by two environment variables:

  - `NODE_TYPE` ("hub" | "worker") — determines whether the observability
    processes and scheduler are started.
  - `NODE_ROLE` ("gaming_gpu" | "mac_mini_pro" | "mac_mini_base") — determines
    which Bumblebee models are loaded into VRAM / Unified Memory.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    topology  = Application.fetch_env!(:hermes_beam, :topology)
    node_type = Keyword.fetch!(topology, :type)
    node_role = Keyword.fetch!(topology, :role)

    Logger.info("[HermesBeam] Booting as #{node_type} / #{node_role}")

    attach_telemetry_once()

    children =
      base_children() ++
        cluster_children() ++
        ml_children() ++
        hub_children(node_type) ++
        dashboard_children(node_type)

    opts = [strategy: :one_for_one, name: HermesBeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ---------------------------------------------------------------------------
  # Child groups
  # ---------------------------------------------------------------------------

  defp base_children do
    [
      HermesBeam.Repo,
      {Phoenix.PubSub, name: HermesBeam.PubSub}
      # NOTE: Ash.Domain does not define a supervised process.
      # Resources are registered via `use Ash.Resource, domain: ...` at
      # compile time. No runtime child spec is needed or valid here.
    ]
  end

  defp cluster_children do
    topologies = Application.get_env(:hermes_beam, :libcluster)[:topologies]
    [{Cluster.Supervisor, [topologies, [name: HermesBeam.ClusterSupervisor]]}]
  end

  defp ml_children do
    [HermesBeam.LLM.TierSupervisor]
  end

  defp hub_children("hub") do
    Logger.info("[HermesBeam] Hub mode: starting IdleScheduler")
    [HermesBeam.IdleScheduler]
  end

  defp hub_children(_), do: []

  defp dashboard_children("hub") do
    Logger.info("[HermesBeam] Hub mode: starting Phoenix dashboard")

    [HermesBeamWeb.Telemetry, HermesBeamWeb.Endpoint]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp dashboard_children(_), do: []

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  # Attaches the WorkflowHandler telemetry on every node so Worker-originated
  # Reactor events are also captured.
  # WorkflowHandler.attach/0 raises ArgumentError if the handler ID is already
  # registered (e.g. on hot code reload). We rescue it here for idempotency.
  defp attach_telemetry_once do
    HermesBeam.Telemetry.WorkflowHandler.attach()
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    if Code.ensure_loaded?(HermesBeamWeb.Endpoint) do
      HermesBeamWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end
end
