defmodule Workflow.SchedulerWorkspaceTest do
  use ExUnit.Case, async: false

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.Journal
  alias Workflow.Scheduler
  alias Workflow.Scheduler.Error
  alias Workflow.Script

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "codex_loops_workspace_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "an omitted root derives the project root and journals canonical context", %{base: root} do
    script = write_workflow(root, "derived")
    run_id = run_id("derived")

    assert {:ok, %{run_id: ^run_id}} =
             Scheduler.start_run(%{
               "script_path" => script,
               "run_id" => run_id,
               "provider" => "mock"
             })

    projection = wait_for_projection(run_id)
    canonical_root = canonical_directory(root)
    canonical_script = Path.join(canonical_root, Path.relative_to(script, root))

    assert projection.workspace_root == canonical_root

    assert %Event{
             payload: %Payload.RunStarted{
               script_path: ^canonical_script,
               workspace_root: ^canonical_root
             }
           } = Enum.find(Journal.fold(run_id), &(&1.type == :run_started))
  end

  test "a relative source resolves only against an explicit absolute root", %{base: root} do
    script = write_workflow(root, "relative")
    relative_script = Path.relative_to(script, root)
    run_id = run_id("relative")

    assert {:ok, %{run_id: ^run_id}} =
             Scheduler.start_run(%{
               "script_path" => relative_script,
               "workspace_root" => root,
               "run_id" => run_id,
               "provider" => "mock"
             })

    assert %{workspace_root: canonical_root} = wait_for_projection(run_id)
    assert canonical_root == canonical_directory(root)

    assert {:ok, validation} =
             Scheduler.validate_workflow(%{
               "script_path" => relative_script,
               "workspace_root" => root
             })

    assert validation.script.path == canonical_file(script)
  end

  test "a relative source without a root is rejected instead of using scheduler cwd", %{base: root} do
    script = write_workflow(root, "missing_relative_root")
    relative_script = Path.relative_to(script, root)

    for result <- [
          Scheduler.start_run(%{
            "script_path" => relative_script,
            "run_id" => run_id("missing_relative_root"),
            "provider" => "mock"
          }),
          Scheduler.validate_workflow(%{"script_path" => relative_script})
        ] do
      assert {:error, %Error{} = error} = result
      assert error.code == "scheduler.run.invalid_workspace_root"
      assert error.details.reason =~ "required_for_relative_script"
    end
  end

  test "an explicit symlinked root and source are stored by canonical path", %{base: base} do
    actual_root = Path.join(base, "actual")
    script = write_workflow(actual_root, "canonical")
    linked_root = Path.join(base, "linked")
    :ok = File.ln_s(actual_root, linked_root)

    linked_script = Path.join(linked_root, Path.relative_to(script, actual_root))
    run_id = run_id("canonical")
    canonical_root = canonical_directory(actual_root)
    canonical_script = Path.join(canonical_root, Path.relative_to(script, actual_root))

    assert {:ok, %{run_id: ^run_id}} =
             Scheduler.start_run(%{
               "script_path" => linked_script,
               "workspace_root" => linked_root,
               "run_id" => run_id,
               "provider" => "mock"
             })

    _projection = wait_for_projection(run_id)

    assert %Event{
             payload: %Payload.RunStarted{
               script_path: ^canonical_script,
               workspace_root: ^canonical_root
             }
           } = Enum.find(Journal.fold(run_id), &(&1.type == :run_started))
  end

  test "a source outside the root is rejected before the scheduler starts it", %{base: base} do
    workspace_root = Path.join(base, "work")
    File.mkdir_p!(workspace_root)
    outside_script = write_workflow(Path.join(base, "work-escape"), "outside")
    File.write!(outside_script, "this is deliberately not valid workflow syntax !!!")
    canonical_root = canonical_directory(workspace_root)
    canonical_script = canonical_file(outside_script)

    assert {:error, %Error{} = error} =
             Scheduler.start_run(%{
               "script_path" => outside_script,
               "workspace_root" => workspace_root,
               "run_id" => run_id("outside"),
               "provider" => "mock"
             })

    assert error.status == 400
    assert error.code == "scheduler.run.script_outside_workspace"

    assert error.details == %{
             script_path: canonical_script,
             workspace_root: canonical_root
           }
  end

  test "a source symlink cannot escape the canonical workspace", %{base: base} do
    workspace_root = Path.join(base, "workspace")
    outside_script = write_workflow(Path.join(base, "outside"), "outside_symlink")
    linked_script = Path.join(workspace_root, ".codex/workflows/escape.exs")
    File.mkdir_p!(Path.dirname(linked_script))
    :ok = File.ln_s(outside_script, linked_script)
    canonical_root = canonical_directory(workspace_root)
    canonical_script = canonical_file(outside_script)

    assert {:error, %Error{} = error} =
             Scheduler.start_run(%{
               "script_path" => linked_script,
               "workspace_root" => workspace_root,
               "run_id" => run_id("symlink_escape"),
               "provider" => "mock"
             })

    assert error.code == "scheduler.run.script_outside_workspace"
    assert error.details.script_path == canonical_script
    assert error.details.workspace_root == canonical_root
  end

  test "workspace roots must be absolute existing directories", %{base: base} do
    script = write_workflow(base, "invalid_roots")
    file_root = Path.join(base, "not-a-directory")
    File.write!(file_root, "file")

    invalid_roots = [
      "relative/root",
      Path.join(base, "missing"),
      file_root,
      ""
    ]

    Enum.each(invalid_roots, fn workspace_root ->
      assert {:error, %Error{} = error} =
               Scheduler.start_run(%{
                 "script_path" => script,
                 "workspace_root" => workspace_root,
                 "run_id" => run_id("invalid_root"),
                 "provider" => "mock"
               })

      assert error.status == 400
      assert error.code == "scheduler.run.invalid_workspace_root"
      assert error.details.field == "workspace_root"
      assert error.details.expected == "absolute_existing_directory"
    end)
  end

  test "a workspace symlink cycle fails as typed input instead of looping", %{base: base} do
    script = write_workflow(base, "symlink_cycle")
    first = Path.join(base, "cycle-one")
    second = Path.join(base, "cycle-two")
    :ok = File.ln_s(Path.basename(second), first)
    :ok = File.ln_s(Path.basename(first), second)

    assert {:error, %Error{} = error} =
             Scheduler.start_run(%{
               "script_path" => script,
               "workspace_root" => first,
               "run_id" => run_id("symlink_cycle"),
               "provider" => "mock"
             })

    assert error.status == 400
    assert error.code == "scheduler.run.invalid_workspace_root"
    assert error.details.reason =~ "too_many_symlinks"
  end

  test "resume recovers the journaled root and validates an explicit override", %{base: base} do
    original_root = Path.join(base, "original")
    other_root = Path.join(base, "other")
    script = write_workflow(original_root, "resume")
    other_script = write_workflow(other_root, "resume")
    run_id = run_id("resume")

    assert {:ok, _start} =
             Scheduler.start_run(%{
               "script_path" => script,
               "workspace_root" => original_root,
               "run_id" => run_id,
               "provider" => "mock"
             })

    _projection = wait_for_projection(run_id)
    before_count = run_id |> Journal.fold() |> length()

    assert {:error, %Error{code: "scheduler.run.script_outside_workspace"}} =
             Scheduler.resume_run(run_id, %{
               "workspace_root" => other_root,
               "provider" => "mock"
             })

    assert {:error, %Error{code: "scheduler.run.script_outside_workspace"}} =
             Scheduler.resume_run(run_id, %{
               "script_path" => other_script,
               "provider" => "mock"
             })

    assert {:ok, %{run_id: ^run_id}} =
             Scheduler.resume_run(run_id, %{
               "script_path" => other_script,
               "workspace_root" => other_root,
               "provider" => "mock"
             })

    await_lease_released(run_id)

    assert {:ok, %{run_id: ^run_id}} = Scheduler.resume_run(run_id, %{"provider" => "mock"})
    await_lease_released(run_id)
    assert run_id |> Journal.fold() |> length() == before_count
  end

  test "resume derives a safe root for legacy start events without one", %{base: root} do
    script = write_workflow(root, "legacy")
    run_id = run_id("legacy")
    {:ok, tree} = Script.load_tree(script)

    assert :ok = Journal.register_run(run_id)
    assert {:ok, %{seq: 0}} = Journal.append_next(run_id, Event.run_started(tree, nil, script))

    assert %Event{payload: %Payload.RunStarted{workspace_root: nil}} =
             Enum.find(Journal.fold(run_id), &(&1.type == :run_started))

    assert {:ok, %{run_id: ^run_id}} = Scheduler.resume_run(run_id, %{"provider" => "mock"})
    assert %{state: :completed} = wait_for_projection(run_id)
  end

  defp write_workflow(root, name) do
    path = Path.join(root, ".codex/workflows/#{name}.exs")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    workflow "#{name}" do
      return :ok
    end
    """)

    Path.expand(path)
  end

  defp run_id(prefix), do: "workspace_#{prefix}_#{System.unique_integer([:positive])}"

  defp canonical_directory(path), do: File.cd!(path, &File.cwd!/0)

  defp canonical_file(path) do
    path
    |> Path.dirname()
    |> canonical_directory()
    |> Path.join(Path.basename(path))
  end

  defp wait_for_projection(run_id, attempts \\ 100)

  defp wait_for_projection(run_id, 0), do: flunk("run #{run_id} did not complete: #{inspect(Scheduler.get_run(run_id))}")

  defp wait_for_projection(run_id, attempts) do
    case Scheduler.get_run(run_id) do
      {:ok, %{state: :completed} = projection} ->
        projection

      _other ->
        Process.sleep(5)
        wait_for_projection(run_id, attempts - 1)
    end
  end

  defp await_lease_released(run_id, attempts \\ 100)
  defp await_lease_released(run_id, 0), do: flunk("run #{run_id} kept its writer lease")

  defp await_lease_released(run_id, attempts) do
    case Registry.lookup(Workflow.Run.Registry, run_id) do
      [] ->
        :ok

      _running ->
        Process.sleep(5)
        await_lease_released(run_id, attempts - 1)
    end
  end
end
