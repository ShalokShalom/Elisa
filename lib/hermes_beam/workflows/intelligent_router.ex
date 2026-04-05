defmodule HermesBeam.Workflows.IntelligentRouter do
  @moduledoc """
  Maps agent task types to the appropriate `Nx.Serving` hardware tier.

  This is intentionally a plain module — not a Reactor — because `tier_for/1`
  is a pure function called on the hot path inside `AgentLoop`. Wrapping it in
  a Reactor graph would add unnecessary overhead with no benefit.

  Task → Tier mapping:

  | Task type           | Tier                 | Typical model  |
  |---------------------|----------------------|----------------|
  | :deep_reflection    | :tier_1_reasoning    | Llama 3 70B    |
  | :complex_planning   | :tier_1_reasoning    | Llama 3 70B    |
  | :synthetic_data     | :tier_2_general      | Llama 3 8B     |
  | :tool_calling       | :tier_2_general      | Llama 3 8B     |
  | :write_docs         | :tier_3_docs         | Phi-3 Mini     |
  | :format_json        | :tier_3_docs         | Phi-3 Mini     |
  | _default_           | :tier_2_general      | Llama 3 8B     |
  """

  @spec tier_for(atom()) :: atom()
  def tier_for(task_type) do
    case task_type do
      :deep_reflection  -> :tier_1_reasoning
      :complex_planning -> :tier_1_reasoning
      :synthetic_data   -> :tier_2_general
      :tool_calling     -> :tier_2_general
      :write_docs       -> :tier_3_docs
      :format_json      -> :tier_3_docs
      _                 -> :tier_2_general
    end
  end
end
