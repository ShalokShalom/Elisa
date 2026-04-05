defmodule HermesBeam.Changes.CompileSkillModuleTest do
  use HermesBeam.DataCase, async: true

  alias HermesBeam.Skill

  describe ":learn_skill (compilation)" do
    test "compiles valid Elixir code and stores module name" do
      valid_code = """
      def greet(name) do
        "Hello, " <> name <> "!"
      end
      """

      assert {:ok, skill} =
               Skill
               |> Ash.ActionInput.for_create(:learn_skill, %{
                 name: "greeter_#{System.unique_integer()}",
                 description: "Greets the user",
                 elixir_code: valid_code
               })
               |> Ash.create()

      assert skill.module_name =~ "HermesBeam.Skills.Dynamic"
      module = String.to_existing_atom(skill.module_name)
      assert function_exported?(module, :greet, 1)
      assert module.greet("World") == "Hello, World!"
    end

    test "rejects invalid Elixir code and does not persist" do
      bad_code = "def broken syntax !!!"

      assert {:error, _changeset} =
               Skill
               |> Ash.ActionInput.for_create(:learn_skill, %{
                 name: "bad_skill_#{System.unique_integer()}",
                 description: "Should not compile",
                 elixir_code: bad_code
               })
               |> Ash.create()
    end
  end
end
