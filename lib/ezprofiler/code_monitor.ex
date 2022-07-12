defmodule EZProfiler.CodeMonitor do

   @moduledoc false

  ##
  ##  This module is loaded from the escript on to the target VM  and a process is spawned.
  ##  The sole purpose of this process is to wait for a node_down event indicating that the escript is gone
  ##  and to clean things up. Specifically to swap out the EZCodeProfiler module with the correct one.
  ##
  ##  In a nutshell there are 2 EZCodeProfiler modules. One on the target VM that is basically full of
  ##  stub functions, and one contained in the escript that actually does work. When the escript starts and connects
  ##  we need to load the version contained in the escript onto the target and then load the correct one back when
  ##  the escript terminates
  ##

    alias EZProfiler

    ##
    ## Still in the escript, get the EZCodeProfiler module and spawn a process
    ## on the target
    ##
    @doc false
    def init_code_monitor(target_node) do
      my_node = node()

      ## Grabs the EZCodeProfiler module in the escript
      {local_code_profiler_mod, local_code_profiler_bin, _} = get_code_profiler_module_bin()

      ## Launch a process on the target
      Node.spawn(target_node, fn ->  __MODULE__.do_init_code_monitor(my_node, local_code_profiler_mod, local_code_profiler_bin) end)
    end

    ##
    ## Now on the target VM, grab the EZCodeProfiler module data currently loaded
    ## and replace it with the one from the escript. Then wait for the escript to terminate and do the reverse
    ##
    @doc false
    def do_init_code_monitor(profiler_node, profiler_mod, profiler_bin) do
      Node.monitor(profiler_node, true)

      :persistent_term.erase({EZProfiler.CodeProfiler, :stub_loaded})

      ## Gets the current EZCodeProfiler module data and save it
      {correct_mod, correct_bin, correct_file} = get_code_profiler_module_bin() ## Grabs the stub one shipped with collection server

      ## Start an Agent that EZCodeProfiler will use
      Agent.start(fn -> %{allow_profiling: false, clear_pid: nil, label: :any_label, labels: [], label_transition?: false} end, name: EZProfiler.CodeProfiler)

      ## Load the EZCodeProfiler module from the escript
      :code.load_binary(profiler_mod, '/tmp/ezcodeprofiler.beam', profiler_bin)

      ## Wait for the escript to terminate
      code_monitoring_loop(profiler_node)

      ## When it terminates put the correct EZCodeProfiler back and terminate the Agent
      :code.load_binary(correct_mod, correct_file, correct_bin)
      Process.exit(Process.whereis(EZProfiler.CodeProfiler), :kill)
    end

    ##
    ## Wait for a node down event
    ##
    defp code_monitoring_loop(profiler_node) do
      receive do
        {:nodedown, ^profiler_node} ->
          :done
        _ ->
          code_monitoring_loop(profiler_node)
      end
    end

    defp get_code_profiler_module_bin() do
      {mod, bin, file} = :code.get_object_code(EZProfiler.CodeProfiler)
      {mod, bin, file}
    end

end

