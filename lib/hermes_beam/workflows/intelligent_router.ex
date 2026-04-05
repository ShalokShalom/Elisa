defmodule HermesBeam.Workflows.IntelligentRouter do
  @moduledoc """
  Maps agent task types to the appropriate `Nx.Serving` hardware tier, then
  dispatches the prompt for inference.

  The tier resolution is purely a function call (`tier_for/1`) so it can also
  be called directly by `AgentLoop` without going through the full Reactor
  graph on every simple inference.

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
  use Reactor
  require Logger

  input :agent_prompt
  input :task_type

  step :route_and_infer do
    argument :prompt, input(:agent_prompt)
    argument :task_type, input(:task_type)

    run fn %{prompt: prompt, task_type: task_type}, _ctx ->
      tier = tier_for(task_type)
      Logger.debug("[Router] #{task_type} → #{tier}")
      HermesBeam.LLM.ModelWorker.generate(tier, prompt)
    end
  end

  # ---------------------------------------------------------------------------
  # Public helper — can be called without running the full Reactor graph
  # ---------------------------------------------------------------------------

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
