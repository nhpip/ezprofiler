defmodule EZProfiler do

  @readme  File.read!("README.md")

  @moduledoc """
  #{@readme}
  """

  ##
  ##  Entry module for the profiler that exclusively runs in the escript.
  ##  It parses the configuration, sets up distributed Erlang and connects to
  ##  the target application/VM.
  ##
  ##  Then it gets the remaining optional configuration, launches two processes on
  ##  the target VM, a proxy process on the escript node and waits for user input
  ##

  @max_profile_time 5000 # 5 seconds
  @waiting_prompt "waiting.."
  @profiling_prompt "profiling"

  alias EZProfiler.ProfilerOnTarget
  alias EZProfiler.TermHelper
  alias EZProfiler.CodeMonitor

  @doc false
  def main(args \\ []) do
    try do
      args
      |> OptionParser.parse(
           strict: [
             node: :string,
             cookie: :string,
             processes: :string,
             mf: :string,
             profiler: :string,
             directory: :string,
             maxtime: :integer,
             sos: :boolean,
             sort: :string,
             cpfo: :boolean,
             inline: :string,
             labeltran: :boolean,
             help: :boolean
           ]
         )
      |> setup_distributed_erlang() |> start_profiling()
    rescue
      e in ArgumentError -> error(e.message)
      e in FunctionClauseError -> IO.puts("error: #{inspect(e)}")
      e -> IO.puts("error #{inspect(e)}")
    end
  end
  
  @doc false
  def error(error) do
    IO.puts("")
    IO.puts(~s(#{inspect error}\n))
    help()
  end

  ##
  ## Sets up the distributed Erlang stuff
  ##
  @doc false
  def setup_distributed_erlang({args, _, _}) do
    if Keyword.get(args, :help) do
      help()
    end

    node = args[:node]
    target_node = String.to_atom(node)
    [_,address] = String.split(node,"@")
    my_node = String.to_atom("ezprofiler@"<>address)
    dist_type = if String.contains?(address,".") do :longnames else :shortnames end

    Application.start(:inets)
    :net_kernel.start([my_node, dist_type])

    case Keyword.get(args, :cookie) do
      nil -> :ok
      cookie -> :erlang.set_cookie(node(), String.to_atom(cookie))
    end

    if :net_adm.ping(target_node) == :pong,
      do: {target_node, args},
      else: error({target_node, :unavailable})
  end

  ##
  ## Get the profiling config, starts profiling services on the target
  ##
  defp start_profiling({target_node, opts}) do
      ## Get the profiler to use and ensure it's a valid type
      profiler = String.to_atom(Keyword.get(opts, :profiler, "eprof"))
      if profiler not in [:cprof, :eprof, :fprof] do
        display_message(:invalid_profiler)
        System.halt()
      end

      ## Get the module:function and convert it into usable atoms
      mod_fun = Keyword.get(opts, :mf, "_:_")
      mod_fun = TermHelper.get_profiler_mod_fun(mod_fun)

      ## Get the processes we want to monitor and convert them to actual pids
      process_cfg = if profiler != :cprof do Keyword.get(opts, :processes, false) else [] end
      actual_processes = if process_cfg do TermHelper.get_actual_pids(target_node, process_cfg) else false end
      if actual_processes == [[]], do: System.halt()

      ## How to sort the results. For eprof it's one of time, calls or mfa (default time). For fprof it's one of acc or own, default acc
      sort = String.to_atom(Keyword.get(opts, :sort, "default"))
      sort = case profiler do
        :eprof ->
          if sort in [:time, :calls, :mfa] do sort else :time end
        :fprof ->
          if sort in [:acc, :own] do sort else :acc end
        _ ->
          :no_sort
      end

      ## Set the configuration
      new_opts = %{
          target_node: target_node,
          actual_processes: actual_processes,
          profiler: profiler,
          sort: sort,
          mod_fun: mod_fun,
          process_configuration: process_cfg,
          set_on_spawn: Keyword.get(opts, :sos, false),
          directory: Keyword.get(opts, :directory, false),
          max_time: Keyword.get(opts, :maxtime, @max_profile_time),
          code_profiler_fun_only: Keyword.get(opts, :cpfo, false),
          label_transition?: Keyword.get(opts, :labeltran, false)
      }

      ## Load the module CodeMonitor on the target and spawn a process on the target that executes that code
      ## See the module CodeMonitor doc, for more info, but this is a simple process that cleans things up when the escript terminates
      remote_module_load(target_node, CodeMonitor)

      monitor_pid = CodeMonitor.init_code_monitor(target_node)

      ## Load the module ProfilerOnTarget on the target and spawn a gen_statem on the target that executes that code
      ## See the module ProfilerOnTarget doc for more info, but this is the process that does the actual profiling
      remote_module_load(target_node, ProfilerOnTarget)

      profiler_pid = ProfilerOnTarget.init_profiling(new_opts)

      print_headers()

      :error_logger.tty(false)

      state = %{target_node: target_node,
                original_mod_fun: mod_fun,
                current_mod_fun: mod_fun,
                command_count: 1,
                prompt: @waiting_prompt,
                current_state: :waiting,
                profiler_pid: profiler_pid,
                monitor_pid: monitor_pid,
                current_labels: [],
                results_file: nil}

      ## Since this "main" process is blocked waiting on user input spawn a process that proxies inbound messages from the target
      wait_for_profiler_events(profiler_pid, monitor_pid)

      if (filename = Keyword.get(opts, :inline, nil)), do: File.touch(filename)

      ## Get user input/commands
      wait_for_user_events(state)
  end

  defp print_headers() do
    IO.puts("\nOptions:\n
     's' to start profiling when 'waiting'
     'a' to get profiling results when 'profiling'
     'r' to abandon (reset) profiling and go back to 'waiting' state with initial value for 'u' set
     'c' to enable code profiling (once)
     'c' \"label\" to enable code profiling (once) for label (an atom, string or list of either), e.g. \"c mylabel\" || \"c label1, label2\"
         Select \"c r\" to use the last label(s)
     'l' \"true | false\" permits transition between labels if multiple labels are specified
     'u' \"M:F\" to update the module and function to trace (only with eprof)
     'v' to view last saved results file
     'g' for debugging, returns the state on the target VM
     'h' this help text
     'q' to exit\n")
  end

  ##
  ## Since the main process is blocked on IO.gets it can not receive messages
  ## from other processes to do things like change state or update the prompt.
  ## This is a special process that acts as a proxy to get these messages
  ##
  @doc false
  def wait_for_profiler_events(profiler_pid, monitor_pid) do
    my_pid = self()
    spawn(fn ->
      ## Monitors so we can terminate cleanly if the target dies
      Process.monitor(profiler_pid)
      Process.monitor(monitor_pid)
      ## Register ourself with a name
      Process.register(self(), :main_event_handler)
      ## Really the group leader is the process waiting for events and we are blocked on that
      ## Get the port the group leader is "listening" to
      [port] = Process.info(Process.group_leader())[:links] |>  Enum.filter(&is_port(&1))
      ## Jump into the message receive loop
      do_wait_for_profiler_events(port, my_pid)
    end)
  end

  ##
  ## Wait for messages, and proxy them to the main process
  ##
  defp do_wait_for_profiler_events(port, pid) do
    receive do
      message ->
        ## Got a message to be proxied to the main (blocked) process.
        ## Don't care what it is, just forward it
        send(pid, message)
        ## Send a unique string to the group leader and it's port.
        ## The main process's IO.gets will then wake up amd receive that string
        ## so it can check its mailbox
        send(Process.group_leader(), {port, {:data, "123profiler_message\n"}})
        do_wait_for_profiler_events(port, pid)
    end
  end

  ##
  ## The "main process" waits for user input
  ##
  defp wait_for_user_events(%{target_node: target_node, command_count: count, original_mod_fun: orig_mod_fun, current_labels: current_labels} = state) do
    prompt = make_prompt(state)
    case IO.gets(prompt) |> String.trim() do
      "s" ->
        ProfilerOnTarget.start_profiling(target_node)
        wait_for_user_events(%{state | command_count: count+1})

      <<"u",new_mod_fun::binary>> ->
        mod_fun =  String.trim(new_mod_fun) |> TermHelper.get_profiler_mod_fun()
        case ProfilerOnTarget.update_profiling(target_node, mod_fun) do
          :ok ->
            display_message(:updated_mf)
            wait_for_user_events(%{state | command_count: count+1, current_mod_fun: mod_fun})
          _ ->
            display_message(:no_updated_mf)
            wait_for_user_events(%{state | command_count: count+1})
        end

      "r" ->
        ProfilerOnTarget.reset_profiling(target_node)
        ProfilerOnTarget.update_profiling(target_node, orig_mod_fun)
        wait_for_user_events(%{state | command_count: count+1})

      "a" ->
        ProfilerOnTarget.analyze_profiling(target_node)
        wait_for_user_events(%{state | command_count: count+1})

      "q" ->
        ProfilerOnTarget.stop_profiling(target_node)
        receive do
          _ -> :ok
        after
          2000 -> :ok
        end
        System.halt()

      "c" ->
       ProfilerOnTarget.allow_code_profiling(target_node, [])
       wait_for_user_events(%{state | command_count: count+1, current_labels: []})

      <<"c", labels::binary>> ->
        with {:ok, labels} <- get_label(labels, current_labels)
        do
          ProfilerOnTarget.allow_code_profiling(target_node, labels)
          wait_for_user_events(%{state | command_count: count+1, current_labels: labels})
        else
          _ ->
            display_message(:bad_label)
            wait_for_user_events(%{state | command_count: count+1})
        end

      <<"l", bool::binary>> ->
        with {:ok, transition?} <- label_transition(bool)
        do
          display_message({:label_transistion, transition?})
          ProfilerOnTarget.allow_label_transition(target_node, transition?)
        else
          _ -> display_message({:label_transistion, :error})
        end
        wait_for_user_events(%{state | command_count: count+1})

      "v" ->
        view_results_file(state)
        wait_for_user_events(%{state | command_count: count+1})

      "h" ->
        print_headers()
        wait_for_user_events(%{state | command_count: count+1})

      "g" ->
        display_message(:new_line1)
        IO.inspect ProfilerOnTarget.get_state(target_node)
        display_message(:new_line1)
        wait_for_user_events(state)

      msg ->
        monitor_pid = state.monitor_pid
        profiler_pid = state.profiler_pid
        ## If msg is "profiler_message" we know its from the message proxy process
        ## so let's go and check the mailbox to get the message
        case handle_erlang_elixir_message(msg) do
          :code_profiling_started ->
            display_message(:new_line1)
            wait_for_user_events(state)

          :code_profiling_ended ->
            display_message(:new_line1)
            wait_for_user_events(state)

          {:get_results_file, pid} ->
            get_results_file(pid, state)
            wait_for_user_events(state)

          {:state_change, pid, :waiting} ->
            display_message(:new_line1)
            send(pid, :state_change_ack)
            wait_for_user_events(%{state | prompt: @waiting_prompt, current_state: :waiting})

          {:state_change, :waiting} ->
            display_message(:new_line1)
            wait_for_user_events(%{state | prompt: @waiting_prompt, current_state: :waiting})

          {:state_change, pid, :profiling} ->
            display_message(:new_line1)
            send(pid, :state_change_ack)
            wait_for_user_events(%{state | prompt: @profiling_prompt, current_state: :profiling})

          {:state_change, pid, :no_change} ->
            display_message(:new_line1)
            send(pid, :state_change_ack)
            wait_for_user_events(%{state | prompt: :no_prompt})

          {:new_filename, filename} ->
            wait_for_user_events(%{state | results_file: filename})

          :view_results_file ->
            view_results_file(state)
            wait_for_user_events(state)

          {:display_message, message_details} ->
            display_message(message_details)
            wait_for_user_events(state)

          {:exit_profiler, :error} ->
            display_message(:profiler_error)
            System.halt()

          {:exit_profiler, :invalid_pids} ->
            display_message(:profiler_error_pids)
            System.halt()

          {:DOWN, _ref, :process, ^profiler_pid, reason} ->
            display_message({:profiler_error_term, [reason]})
            System.halt()

          {:DOWN, _ref, :process, ^monitor_pid, reason} ->
            display_message({:monitor_error_term, [reason]})
            System.halt()

          _ ->
            wait_for_user_events(state)
        end
    end
  end

  defp label_transition(allow?) do
    try do
      {allow?, _} = String.trim(allow?) |> Code.eval_string()
      if is_boolean(allow?),
        do: {:ok, allow?},
        else: :error
    rescue
      _ -> :error
    end
  end

  defp get_label(labels, current_labels) do
    new_labels =
      String.trim(labels)
      |> String.replace("[", "")
      |> String.replace("]", "")
      |> String.split(",")
      |> Enum.map(fn label ->
            label = String.trim(label) |> String.replace("\"", "")
            if String.at(label, 0) == ":",
              do: do_get_label(label),
              else: do_get_label("\"#{label}\"")
      end)
      if Enum.member?(new_labels, :error) do
        :error
      else
        if new_labels == ["r"],
          do: {:ok, current_labels},
          else: {:ok, new_labels}
      end
  end

  defp do_get_label(label) do
    try do
      {new_label, _} = Code.eval_string(label)
      new_label
    rescue
      _ -> :error
    end
  end

  defp make_prompt(%{prompt: :no_prompt} = _state), do: ""

  defp make_prompt(%{prompt: prompt, command_count: count} = _state), do: prompt <> "(#{count})> "

  ##
  ## Get a message forwarded from the proxy
  ##
  defp handle_erlang_elixir_message("123profiler_message") do
    receive do
      msg -> msg
    after
      2000 -> :ok
    end
  end

  defp handle_erlang_elixir_message(_) do
    :ok
  end

  defp view_results_file(%{results_file: filename} = _state) when is_binary(filename) do
    try do
      File.stream!(filename) |> Enum.each(&(String.trim(&1, "\n")) |> IO.puts())
      IO.puts("")
    rescue
      _ ->
        display_message(:no_file)
    end
  end

  defp view_results_file(_state), do:
    display_message(:no_file)

  defp get_results_file(pid, %{results_file: filename} = _state) when is_binary(filename) do
    try do
      send(pid, {:profiling_results, filename, File.read!(filename)})
    rescue
      _ ->
        send(pid, {:no_profiling_results, :processing_exception})
    end
  end

  defp get_results_file(pid, _state), do:
    send(pid, {:profiling_results, :no_results_file})

  ##
  ## Gets the module's binary code and load it on the target.
  ## It will be unloaded when this escript terminates
  ##
  defp remote_module_load(node, module) do
    {mod, bin, _file} = :code.get_object_code(module)
    :rpc.call(node, :code, :load_binary, [mod, '/tmp/ignore.beam', bin])
  end

  defp display_message(message_details) do
    case message_details do
      {:new_line, _} ->
        IO.puts("")

      :new_line1 ->
        IO.puts("")

      :new_line2 ->
        IO.puts("\n")

      :invalid_profiler ->
        IO.puts("\nInvalid profiler\n")

      :bad_label ->
        IO.puts("\nBad label\n")

      {:label_transistion, :error} ->
        IO.puts("\nMust be either true or false\n")

      {:label_transistion, what} ->
        IO.puts("\nLabel transition set to #{what}\n")

      {:message, message}  ->
        IO.puts("\n#{inspect(message)}\n")

      {:stopped_profiling, [filename]} ->
        IO.puts("\nStopped profiling, results are in file #{filename}, press 'v' to view them\n")

      {:stopped_profiling_label, [filename, label]} ->
        IO.puts("\nStopped profiling, results are in file #{filename} with a label of #{inspect label}, press 'v' to view them\n")

      {:invalid_request, _} ->
        IO.puts("\nInvalid request or no processes to profile")

      {:code_start, [label]} ->
        IO.puts("\nGot a start profiling from source code with label of #{inspect label}\n")

      {:eprof_terminated, _} ->
        IO.puts("\neprof has terminated, will attempt recovery")

      {:process_down, [pid]} ->
        IO.puts("\nMonitored process #{inspect pid} terminated, will disable profiling, here are the results so far\n")

      {:time_exceeded, [time]} ->
        IO.puts("\nProfiling time of #{inspect round(time/1000)} seconds has exceeded, will disable profiling\n")

      :updated_mf ->
        IO.puts("\nUpdated the module and function")

      :no_updated_mf ->
        IO.puts("\nCan only update the module and function when using eprof")

      {:code_prof, _} ->
        IO.puts("\nCode profiling enabled\n")

      {:reset_state, _} ->
        IO.puts("\nReset state\n")

      {:no_code_prof, _} ->
        IO.puts("\nCode profiling can onle be enabled in waiting state\n")

      {:code_prof_label, [labels]} ->
        labels = Enum.reduce(labels, "",  fn(l, a) -> "#{a}, #{inspect(l)}" end) |> String.replace("\"", "") |> String.trim_leading(", ")
        IO.puts("\nCode profiling enabled with label(s) of #{labels}\n")

      :no_file ->
        IO.puts("\nNo file found\n")

      :profiler_error ->
        IO.puts("\nProfiler error on the server, exiting...\n")

      {:no_processes, _} ->
        IO.puts("\nNo processes to profile\n")

      {:code_profiling_error, _} ->
        IO.puts("\nCode is currently been profiled, can not start or analyze in this state\n")

      {:code_profiling_state, _} ->
        IO.puts("\nAnalysis only works in profiling state\n")

      {:code_waiting_state, _} ->
        IO.puts("\nStart only works in waiting state\n")

      :profiler_error_pids ->
        IO.puts("\nProcesses may no longer be valid, exiting...\n")

      {:profiler_error_term, [reason]} ->
        IO.puts("\nProfiler on the target has terminated with reason #{inspect reason}\n")

      {:monitor_error_term, [reason]} ->
        IO.puts("\nMonitor on the target has terminated with reason #{inspect reason}\n")

      :profiler_problem ->
        IO.puts("\nPossible problem with eprof or fprof, restart maybe necessary")

      {:pseudo_code_profiling, [result]} ->
        IO.puts("\n#{result}")

      _ ->
        :ok
    end
  end

  defp help() do
    IO.puts("ezprofiler:\n")
    IO.puts(" --node [node]: the Erlang VM you want tracing on (e.g. myapp@localhost)\n")
    IO.puts(" --cookie [cookie]: the VM cookie (optional)\n")

    IO.puts(
      " --processes [pid or reg_name]: the remote process pid (e.g. \"<0.249.0>\") or registered name or pg/pg2 group you want to trace\n"
    )

    IO.puts(
      " --sos: if present will apply tracing to any process spawned by the one defined in --process\n"
    )

    IO.puts(
      " --mf [string]: a specification of module:fun of which module and functions to trace, with underscore _ as a wildcard.
              Example \"Foo:bar\" will trace calls to Foo:bar \"Foo:_\" will trace calls to all functions in module Foo (default is \"_:_\")\n"
    )

    IO.puts(" --directory: where to store the results\n")
    IO.puts(" --maxtime: the maximum time we wait for profiling to complete in milliseconds (default 5000 milliseconds)\n")
    IO.puts(" --profiler: one of eprof, cprof or fprof, default eprof\n")
    IO.puts(" --sort: for eprof one of time, calls, mfa (default time), for fprof one of acc or own (default acc). Nothing for cprof\n")
    IO.puts(" --cpfo: when doing code profiling setting this will only profile the function and not any functions that the function calls\n")
    IO.puts(" --labeltran: permits transition between labels if multiple labels are specified\n")
    IO.puts(" --help: this page\n")

    System.halt()
  end
end
