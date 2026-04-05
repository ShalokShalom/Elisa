defmodule HermesBeam.Memory.ScratchpadTest do
  use HermesBeam.DataCase, async: true

  alias HermesBeam.Memory.Scratchpad

  @valid_agent_id Ecto.UUID.generate()

  describe ":initialize" do
    test "creates a scratchpad with defaults" do
      assert {:ok, pad} =
               Scratchpad
               |> Ash.ActionInput.for_create(:initialize, %{agent_id: @valid_agent_id})
               |> Ash.create()

      assert pad.agent_id == @valid_agent_id
      assert pad.memory_text == "System initialized. No memories yet."
      assert pad.user_text == "No user preferences recorded."
    end

    test "rejects duplicate agent_id" do
      attrs = %{agent_id: @valid_agent_id}
      {:ok, _pad} = Scratchpad |> Ash.ActionInput.for_create(:initialize, attrs) |> Ash.create()

      assert {:error, _} =
               Scratchpad |> Ash.ActionInput.for_create(:initialize, attrs) |> Ash.create()
    end
  end

  describe ":curate_memory" do
    setup do
      {:ok, pad} =
        Scratchpad
        |> Ash.ActionInput.for_create(:initialize, %{agent_id: Ecto.UUID.generate()})
        |> Ash.create()

      {:ok, pad: pad}
    end

    test "updates memory_text within limit", %{pad: pad} do
      new_text = String.duplicate("a", 100)

      assert {:ok, updated} =
               pad
               |> Ash.ActionInput.for_update(:curate_memory, %{memory_text: new_text})
               |> Ash.update()

      assert updated.memory_text == new_text
    end

    test "rejects memory_text over 2200 chars", %{pad: pad} do
      over_limit = String.duplicate("a", 2201)

      assert {:error, changeset} =
               pad
               |> Ash.ActionInput.for_update(:curate_memory, %{memory_text: over_limit})
               |> Ash.update()

      assert changeset.errors != []
    end

    test "rejects user_text over 1375 chars", %{pad: pad} do
      over_limit = String.duplicate("u", 1376)

      assert {:error, changeset} =
               pad
               |> Ash.ActionInput.for_update(:curate_memory, %{user_text: over_limit})
               |> Ash.update()

      assert changeset.errors != []
    end
  end
end
