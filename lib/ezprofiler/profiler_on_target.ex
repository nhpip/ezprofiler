defmodule EZProfiler.ProfilerOnTarget do

  @moduledoc false

  ##
  ## This module is loaded from the escript onto the target VM and a process is spawned.
  ## This process is a gen_statem, it waits for user events/messages from the escript and does the profiling work.
  ##
  ## This process terminates and the module is unloaded when the escript terminates
  ##

  @behaviour :gen_statem

  @temp_results_file "/tmp/tmp_profile_results"

  @saved_temp_results_file "/tmp/tmp_profile_results.save"

  alias EZProfiler.CodeProfiler

  @doc false
  def callback_mode, do: :handle_event_function

  ##
  ## All these public functions are called in the context of the escript
  ## and dispatches messages to the gen_statem and this module on the target
  ##
  @doc false
  def start_profiling(target_node) do
    :gen_statem.cast({:cstop_profiler, target_node}, :start)
  end

  @doc false
  def update_profiling(target_node, mod_fun) do
    :gen_statem.call({:cstop_profiler, target_node}, {:update, mod_fun})
  end

  @doc false
  def stop_profiling(target_node) do
    :gen_statem.call({:cstop_profiler, target_node}, :stop)
  end

  @doc false
  def reset_profiling(target_node) do
    :gen_statem.call({:cstop_profiler, target_node}, :reset)
  end

  @doc false
  def analyze_profiling(target_node) do
    :gen_statem.cast({:cstop_profiler, target_node}, :analyze)
  end

  @doc false
  def allow_code_profiling(target_node, labels) when is_list(labels) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_code_profiling, labels, nil, false})
  end

  @doc false
  def allow_code_profiling(target_node, label) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_code_profiling, [label], nil, false})
  end

  @doc false
  def allow_code_profiling(target_node, labels, pid) when is_list(labels)  do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_code_profiling, labels, pid, false})
  end

  @doc false
  def allow_code_profiling(target_node, label, pid) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_code_profiling, [label], pid, false})
  end

  @doc false
  def auto_allow_code_profiling(target_node, labels) when is_list(labels) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_code_profiling, labels, nil, true})
  end

  @doc false
  def change_code_manager_pid(target_node, pid) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:change_code_manager_pid, pid})
  end

  @doc false
  def set_mgmt_mode_non_blocking(target_node, pid) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:set_mgmt_mode_non_blocking, pid})
  end

  @doc false
  def set_mgmt_mode_blocking(target_node) do
    :gen_statem.cast({:cstop_profiler, target_node}, :set_mgmt_mode_blocking)
  end

  @doc false
  def set_extra_code_pids(target_node, pids) when is_list(pids) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:set_extra_code_pids, pids})
  end

  @doc false
  def set_extra_code_pids(target_node, pid) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:set_extra_code_pids, [pid]})
  end

  @doc false
  def profiling_time(target_node, time) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:profiling_time, time})
  end

  @doc false
  def profiling_start_wait(target_node, time) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:profiling_start_wait, time})
  end

  @doc false
  def test_pid(target_node, pid) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:test_pid, pid})
  end

  @doc false
  def allow_label_transition(target_node, allow?) do
    :gen_statem.cast({:cstop_profiler, target_node}, {:allow_label_transition, allow?})
  end

  @doc false
  def start_code_profiling(pid, fun, label) do
    :gen_statem.cast(:cstop_profiler, {:code_start, pid, fun, label, label})
  end

  @doc false
  def start_code_profiling(pid, fun, label, display_label) do
    :gen_statem.cast(:cstop_profiler, {:code_start, pid, fun, label, display_label})
  end

  @doc false
  def pseudo_start_code_profiling(label) do
    :gen_statem.cast(:cstop_profiler, {:pseudo_code_start, label, label})
  end

  @doc false
  def pseudo_start_code_profiling(label, display_label) do
    :gen_statem.cast(:cstop_profiler, {:pseudo_code_start, label, display_label})
  end

  @doc false
  def stop_code_profiling() do
    :gen_statem.call(:cstop_profiler, :code_stop)
  end

  @doc false
  def pseudo_stop_code_profiling(label, fun, time) do
    :gen_statem.cast(:cstop_profiler, {:pseudo_code_stop, label, fun, time})
  end

  @doc false
  def get_state(target_node) do
    :gen_statem.call({:cstop_profiler, target_node}, :get_state)
  end

  @doc false
  def get_latest_results(target_node) do
    :gen_statem.call({:cstop_profiler, target_node}, :get_latest_results)
  end

  @doc false
  def ping() do
    :gen_statem.call(:cstop_profiler, :ping)
  end

  ##
  ## On the escript, do some init work and starts the gen_statem process on
  ## the target VM
  ##
  @doc false
  def init_profiling(opts) do
    my_node = node()
    my_pid = self()

    [profile_module, profile_function] = opts.mod_fun

    state = %{profiler_node: my_node,
      target_node: opts.target_node,
      profiler_pid: my_pid,
      pids_to_profile: opts.actual_processes,
      pids_to_profile_cfg: opts.process_configuration,
      profile_module: profile_module,
      profile_function: profile_function,
      code_profile_fun: nil,
      code_profiler_fun_only: opts.code_profiler_fun_only,
      set_on_spawn: opts.set_on_spawn,
      results_directory: opts.directory,
      current_results_filename: "",
      current_labels: [],
      display_labels: [],
      current_label: :any_label,
      display_label: :any_label,
      results_file_index: 0,
      max_profiling_time: opts.max_time,
      current_state: :waiting,          # One of :waiting or :profiling
      profiling_type_state: :normal,     # One of :normal or :code
      code_tracing_pid: nil,
      pending_code_profiling: false,
      sort: opts.sort,
      profiler: opts.profiler,
      monitors: [],
      timer_ref: nil,
      beam_profiler_pid: nil,
      code_manager_pid: nil,
      code_manager_non_blocking: false,
      test_pid: nil,
      extra_code_pids: [],
      label_transition?: opts.label_transition?,
      latest_results: [],
      profiling_start_wait: :infinity,
      profiling_start_wait_ref: nil,
      cp_started: 0,
      temp_pseudo_data: nil
    }

    ## Starts the state machine process on the target VM
    start(state)
  end

  ##
  ## Don't like this, but for some reason :gen_statem can't be spawned
  ## on a remote node, so we first spawn an launcher process and this starts
  ## the gen_statem process. Should revisit
  ##
  @doc false
  def start(state) do
    Node.spawn(state.target_node, fn ->
      {:ok, pid} = :gen_statem.start(__MODULE__, [state], [])
      send(state.profiler_pid, pid)
    end)
    receive do
      pid -> pid
    end
  end

  ##
  ## The gen_statem init/1 callback function
  ##
  @doc false
  def init([%{profiler_node: profiler_node, results_directory: directory} = state]) do
    Node.monitor(profiler_node, true)
    Process.register(self(), :cstop_profiler)

    profiler_pid = start_profiler(state)
    idx = profile_file_idx(directory)

    do_state_change_nb(profiler_node, :waiting)

    {:ok, :waiting, %{state | results_file_index: idx, beam_profiler_pid: profiler_pid}}
  end

  ##
  ## These handle_event are gen_statem call back functions that process events from
  ## either the escript or the CodeProfiler Agent process
  ##
  @doc false
  def handle_event({:call, from}, :get_state, _any_state, state) do
    {:keep_state, state, [{:reply, from, state}]}
  end

  @doc false
  def handle_event({:call, from}, :get_latest_results, _any_state, state) do
    {:keep_state, %{state | latest_results: []}, [{:reply, from, {:profiling_results, Enum.reverse(state.latest_results)}}]}
  end

  @doc false
  def handle_event({:call, from}, :ping, _any_state, state) do
    {:keep_state, state, [{:reply, from, :ok}]}
  end

  @doc false
  def handle_event(:cast, :start, :waiting, %{pending_code_profiling: false, pids_to_profile: processes} = state) when is_list(processes) do
    case do_profiling(nil, state) do
      {:continue, new_state} -> {:next_state, :profiling, %{new_state | current_state: :profiling, profiling_type_state: :normal}}
      {_, new_state} -> {:stop, :normal, new_state}
    end
  end

  @doc false
  def handle_event(:cast, :start, :waiting, %{pending_code_profiling: true, profiler_node: profiler_node} = state)  do
    display_message(profiler_node, :code_profiling_error)
    {:keep_state, state}
  end

  @doc false
  def handle_event(:cast, :start, :waiting, %{profiler_node: profiler_node} = state)  do
    display_message(profiler_node, :no_processes)
    {:keep_state, state}
  end

  @doc false
  def handle_event(:cast, :start, :profiling, %{profiler_node: profiler_node} = state)  do
    display_message(profiler_node, :code_waiting_state)
    {:keep_state, state}
  end

  @doc false
  def handle_event(:cast, :analyze, :profiling, %{profiler_node: profiler_node, profiler: profiler, profiling_type_state: :normal, timer_ref: ref} = state) do
    if profiler != :cprof && is_reference(ref), do: Process.cancel_timer(ref)
    profiling_complete(:any, state)
    display_message(profiler_node, :new_line)
    {:next_state, :waiting, %{state | timer_ref: nil, profiling_type_state: :normal, monitors: []}}
  end

  @doc false
  def handle_event(:cast, :analyze, :profiling, %{profiler_node: profiler_node} = state) do
    display_message(profiler_node, :code_profiling_error)
    {:keep_state, state}
  end

  @doc false
  def handle_event(:cast, :analyze, :waiting, %{profiler_node: profiler_node} = state) do
    display_message(profiler_node, :code_profiling_state)
    {:keep_state, state}
  end

  @doc false
  def handle_event({:call, from}, {:update, new_mod_fun}, _any_state, %{profiler: :eprof} = state) do
    [profile_module, profile_function] = new_mod_fun
    {:keep_state, %{state | profile_module: profile_module, profile_function: profile_function}, [{:reply, from, :ok}]}
  end

  @doc false
  def handle_event({:call, from}, {:update, _new_mod_fun}, _any_state, state) do
    {:keep_state, state, [{:reply, from, :error}]}
  end

  @doc false
  def handle_event({:call, from}, :reset, :profiling, %{profiler_node: profiler_node, profiler: profiler, monitors: monitors, timer_ref: tref, profiling_start_wait_ref: sref} = state) do
    if profiler != :cprof && is_reference(tref), do: Process.cancel_timer(tref)
    if profiler != :cprof && is_reference(sref), do: Process.cancel_timer(sref)
    Enum.each(monitors, &Process.demonitor(&1))
    do_profiling_stop(profiler)
    do_state_change(profiler_node, :waiting)
    CodeProfiler.disallow_profiling()
    display_message(profiler_node, :reset_state)
    {:next_state, :waiting, %{state | pending_code_profiling: false, timer_ref: nil, profiling_start_wait_ref: nil, cp_started: 0, profiling_type_state: :normal, monitors: [], latest_results: []}, [{:reply, from, :ok}]}
  end

  @doc false
  def handle_event({:call, from}, :reset, _other_state, %{profiler_node: profiler_node} = state) do
    CodeProfiler.disallow_profiling()
    display_message(profiler_node, :reset_state)
    {:keep_state, %{state | pending_code_profiling: false, code_profile_fun: nil, latest_results: []}, [{:reply, from, :ok}]}
  end

  @doc false
  def handle_event(:cast, {:allow_code_profiling, [], pid, keep_settings}, :waiting, %{profiling_start_wait: start_time, profiler: profiler, code_manager_non_blocking: non_blocking?, profiler_node: profiler_node} = state) do
    ref = if profiler != :cprof && is_integer(start_time), do: Process.send_after(self(), :start_profiling_timeout, start_time)
    allow_profiling_again([], state)
    display_message(profiler_node, :code_prof)
    if keep_settings && non_blocking?,
       do: {:keep_state, %{state | latest_results: [], profiling_type_state: :code, profiling_start_wait_ref: ref}},
       else: {:keep_state, %{state | pending_code_profiling: true, code_manager_pid: pid, profiling_type_state: :code, profiling_start_wait_ref: ref}}
  end

  @doc false
  def handle_event(:cast, {:allow_code_profiling, in_labels, pid, keep_settings}, :waiting, %{profiling_start_wait: start_time, profiler: profiler, code_manager_non_blocking: non_blocking?, profiler_node: profiler_node} = state) do
    ref = if profiler != :cprof && is_integer(start_time), do: Process.send_after(self(), :start_profiling_timeout, start_time)
    labels = lower_labels(in_labels)
    allow_profiling_again(labels, state)
    display_message(profiler_node, :code_prof_label, [in_labels])
    if not keep_settings,
       do: File.rm(@saved_temp_results_file)
    if keep_settings && non_blocking?,
      do: {:keep_state, %{state | current_labels: labels, display_labels: in_labels, pending_code_profiling: true, latest_results: [], profiling_type_state: :code, profiling_start_wait_ref: ref}},
      else: {:keep_state, %{state | current_labels: labels, display_labels: in_labels, pending_code_profiling: true, profiling_start_wait_ref: ref,
                                    code_manager_pid: pid, profiling_type_state: :code}}

  end

  @doc false
  def handle_event(:cast, {:allow_code_profiling, _label, _pid, _keep_settings}, _other_state, %{profiler_node: profiler_node} = state) do
    display_message(profiler_node, :no_code_prof)
    {:keep_state, state}
  end

  @doc false
  def handle_event(:cast, {:change_code_manager_pid, pid}, _any_state, state) do
    {:keep_state, %{state | code_manager_pid: pid, code_manager_non_blocking: true}}
  end

  @doc false
  def handle_event(:cast, :set_mgmt_mode_blocking, _any_state, state) do
    {:keep_state, %{state | code_manager_non_blocking: false}}
  end

  @doc false
  def handle_event(:cast, {:set_mgmt_mode_non_blocking, pid}, _any_state, state) do
    {:keep_state, %{state | code_manager_pid: pid, code_manager_non_blocking: true}}
  end

  @doc false
  def handle_event(:cast, {:set_extra_code_pids, pids}, _any_state, state) do
    {:keep_state, %{state | extra_code_pids: pids}}
  end

  @doc false
  def handle_event(:cast, {:allow_label_transition, transition?}, _any_state, state) do
    CodeProfiler.allow_label_transition(transition?)
    {:keep_state, %{state | label_transition?: transition?}}
  end

  @doc false
  def handle_event(:cast, {:profiling_time, time}, _any_state, state) do
    {:keep_state, %{state | max_profiling_time: time}}
  end

  @doc false
  def handle_event(:cast, {:profiling_start_wait, time}, _any_state, state) do
    {:keep_state, %{state | profiling_start_wait: time}}
  end

  @doc false
  def handle_event(:cast, {:test_pid, pid}, _any_state, state) do
    {:keep_state, %{state | test_pid: pid}}
  end

  @doc false
  def handle_event(:cast, {:code_start, pid, fun, label, display_label}, :waiting, %{profiler: profiler, profiler_node: profiler_node, profiling_start_wait_ref: sref,
                                                                                     current_labels: current_labels, display_labels: dlabels, cp_started: cp_started} = state) do
    if profiler != :cprof && is_reference(sref), do: Process.cancel_timer(sref)

    display_message(profiler_node, :code_start, [display_label])
    case do_profiling([pid], %{state | profiling_type_state: :code, code_profile_fun: fun, code_tracing_pid: pid}) do
      {:continue, new_state} -> {:next_state, :profiling, %{new_state | display_label: display_label, code_profile_fun: nil, current_label: label, cp_started: cp_started + 1,
                                                                        profiling_start_wait_ref: nil, current_labels: List.delete(current_labels, label), display_labels: List.delete(dlabels, display_label)}}
      {_, new_state} -> {:stop, :normal, %{new_state | code_profile_fun: nil, profiling_start_wait_ref: nil, cp_started: cp_started + 1}}
    end
  end

  @doc false
  def handle_event(:cast, {:pseudo_code_start, label, display_label}, :profiling, %{profiler: profiler, current_labels: current_labels, display_labels: dlabels, profiling_start_wait_ref: sref, cp_started: cp_started} = state) do
      if profiler != :cprof && is_reference(sref), do: Process.cancel_timer(sref)
      {:keep_state, %{state | profiling_start_wait_ref: nil, current_labels: List.delete(current_labels, label), display_labels: List.delete(dlabels, display_label), cp_started: cp_started + 1}}
  end

  @doc false
  def handle_event({:call, from}, :code_stop, :profiling, %{cp_started: cp_started, profiler_node: profiler_node, current_results_filename: filename,
                                                            code_manager_pid: cpid, profiler: profiler, timer_ref: tref} = state) when cp_started > 0 do
    if profiler != :cprof && is_reference(tref), do: Process.cancel_timer(tref)

    profiling_complete(:code_stop, state)
    result_str = make_final_results(:code_stop, state)
                 |> finalize_results_file(state)
    display_message(profiler_node, :new_line)
    respond_to_tester(state.test_pid, state.display_label)

    results_map = %{type: :normal,
                    label: state.display_label,
                    filename: filename,
                    profiler: profiler,
                    results_data: result_str}

    if state.code_manager_non_blocking do
      respond_to_manager({:ezprofiler_results, results_map}, cpid)
      {:next_state, :waiting, set_next_state(%{state | pending_code_profiling: false, profiling_type_state: :normal, cp_started: cp_started - 1,
                                                       timer_ref: nil, current_label: :any_label, monitors: []}), [{:reply, from, :ok}]}
    else
      latest_results = [results_map | state.latest_results]
      respond_to_manager({:results_available, results_map}, cpid)
      {:next_state, :waiting, set_next_state(%{state | pending_code_profiling: false, profiling_type_state: :normal, latest_results: latest_results,
                                                       timer_ref: nil, cp_started: cp_started - 1, current_label: :any_label, monitors: []}), [{:reply, from, :ok}]}
    end
  end

  @doc false
  def handle_event({:call, from}, :code_stop, _any_state, state) do
    {:keep_state, state, [{:reply, from, :ok}]}
  end

  @doc false
  def handle_event(:cast, {:pseudo_code_stop, label, fun, time}, _any_state, %{cp_started: cp_started, code_manager_pid: cpid, profiler_node: profiler_node} = state) when cp_started > 0  do
    profiling_complete(:pseudo_code_stop, %{state | temp_pseudo_data: {fun, label, time}})
    result_str = make_final_results(:pseudo_code_stop, state)
                 |> finalize_results_file(state)

    display_message(profiler_node, :pseudo_code_profiling, [result_str])
    respond_to_tester(state.test_pid, label)

    results_map = %{type: :pseudo,
                    label: label,
                    filename: :no_file,
                    profiler: :no_profiler,
                    results_data: result_str}

    if state.code_manager_non_blocking do
      respond_to_manager({:ezprofiler_results, results_map}, cpid)
      {:keep_state, set_next_state(%{state | cp_started: cp_started - 1})}
    else
      latest_results = [results_map | state.latest_results]
      respond_to_manager({:results_available, results_map}, cpid)
      {:keep_state, set_next_state(%{state | cp_started: cp_started - 1, latest_results: latest_results})}
    end
  end

  @doc false
  def handle_event({:call, from}, :stop, _any_state, _state) do
    {:stop_and_reply, :normal, {:reply, from, :ok}}
  end

  @doc false
  def handle_event(:info, :start_profiling_timeout, _any_state,  %{profiling_start_wait: start_time, code_manager_pid: cpid, profiler_node: profiler_node} = state) do
    respond_to_manager({:ezprofiler, :start_profiling_timeout}, cpid)
    display_message(profiler_node, :start_time_exceeded, [start_time])
    CodeProfiler.allow_profiling_async([])
    {:next_state, :waiting, %{state | profiling_start_wait_ref: nil, current_labels: [], display_labels: [], current_label: :any_label,
                                      pending_code_profiling: false, profiling_type_state: :normal, monitors: []}}
  end

  @doc false
  def handle_event(:info, {:profiling_time_exceeded, ptime, :normal}, :profiling,  %{profiler_node: profiler_node} = state) do
    display_message(profiler_node, :time_exceeded, [ptime])
    profiling_complete(:any, state)
    display_message(profiler_node, :new_line)
    {:next_state, :waiting, %{state | current_labels: [], display_labels: [], current_label: :any_label, pending_code_profiling: false, profiling_type_state: :normal, monitors: []}}
  end

  @doc false
  def handle_event(:info, {:profiling_time_exceeded, ptime, :code}, :profiling,  %{code_tracing_pid: pid, code_manager_pid: cpid, profiler_node: profiler_node} = state) do
    display_message(profiler_node, :time_exceeded, [ptime])
    CodeProfiler.allow_profiling_async([])
    profiling_complete(:any, state)

    result_str = make_final_results(:code_stop, state)
                 |> finalize_results_file(state)

    results_map = %{type: :unknown,
                    label: :unknown,
                    filename: :unknown,
                    profiler: :unknown,
                    results_data: result_str}

    latest_results = [results_map | state.latest_results]

    display_message(profiler_node, :new_line)
    respond_to_manager({:ezprofiler, :profiling_timeout}, cpid)
    respond_to_code(:code, :code_profiling_stopped, [pid])

    {:next_state, :waiting, %{state | latest_results: latest_results, current_labels: [], display_labels: [], current_label: :any_label, pending_code_profiling: false, profiling_type_state: :normal, monitors: []}}
  end

  @doc false
  def handle_event(:info, {:DOWN, _, :process, profiler_pid, _rsn}, :waiting,  %{profiler_node: profiler_node, beam_profiler_pid: profiler_pid} = state) do
    display_message(profiler_node, :eprof_terminated)
    profiler_pid = start_profiler(state)
    {:keep_state, %{state | current_labels: [], display_labels: [], beam_profiler_pid: profiler_pid}}
  end

  @doc false
  def handle_event(:info, {:DOWN, _, :process, profiler_pid, _rsn}, :profiling,  %{profiler_node: profiler_node, monitors: monitors, beam_profiler_pid: profiler_pid} = state) do
    Enum.each(monitors, &Process.demonitor(&1))
    display_message(profiler_node, :eprof_terminated)
    CodeProfiler.disallow_profiling()
    profiler_pid = start_profiler(state)
    do_state_change(profiler_node, :waiting)
    {:next_state, :waiting, %{state | current_labels: [], display_labels: [], pending_code_profiling: false, profiling_type_state: :normal, beam_profiler_pid: profiler_pid, monitors: []}}
  end

  @doc false
  def handle_event(:info, {:DOWN, _, :process, pid, _rsn}, :profiling,  %{profiler_node: profiler_node} = state) do
    display_message(profiler_node, :process_down, [pid])
    profiling_complete(:any, state)
    CodeProfiler.disallow_profiling()
    do_state_change(profiler_node, :waiting)
    {:next_state, :waiting, %{state | current_labels: [], display_labels: [], pending_code_profiling: false, profiling_type_state: :normal, monitors: []}}
  end

  @doc false
  def handle_event(:info, {:nodedown, profiler_node}, _any_state, %{profiler_node: profiler_node} = state) do
    {:stop, :normal, state}
  end

  @doc false
  def handle_event(_any_message, _any_event, _any_state, state) do
    {:keep_state, state}
  end

  @doc false
  def terminate(:normal, _any_state, %{profiler_node: profiler_node, profiler: profiler} = _state) do
    profiler.stop()
    send({:main_event_handler, profiler_node}, :stopped)
    :ok
  end

  @doc false
  def terminate(_other, _any_state, %{profiler: profiler} = _state) do
    profiler.stop()
    :ok
  end

  ##
  ## Invoked when we got a request from a user / the escript to start profiling
  ##
  defp do_profiling(code_tracing_pid, %{profiler_node: profiler_node, profiler: profiler, pids_to_profile: processes,
                                        profiling_type_state: profiling_type_state, max_profiling_time: max_time} = state) do
    tracing_processes = if profiling_type_state == :code do code_tracing_pid else processes end
    new_state = log_to_file(state)

    with {:ok, processes_to_profile, new_state} <- start_profiler_profiling(new_state, tracing_processes)
      do
      respond_to_code(profiling_type_state, :code_profiling_started, code_tracing_pid)
      do_state_change(profiler_node, :profiling)

      new_state = %{new_state | monitors: Enum.map(processes_to_profile, &Process.monitor(&1))}

      if profiling_type_state == :code, do: send({:main_event_handler, profiler_node}, :code_profiling_started)

      ## So we can stop processing after a configurable time so we don't possibly profile forever
      ref = if profiler != :cprof, do: Process.send_after(self(), {:profiling_time_exceeded, max_time, new_state.profiling_type_state}, max_time)

      {:continue, %{new_state | timer_ref: ref}}
    else
      :error ->
        profiler.stop()
        send({:main_event_handler, profiler_node}, {:exit_profiler, :error})
        {:exit, state}

      {:error, :exit} ->
        profiler.stop()
        send({:main_event_handler, profiler_node}, {:exit_profiler, :invalid_pids})
        {:exit, state}

      {:error, :recover} ->
        do_state_change(profiler_node, :waiting)
        {:continue, state}
    end
  end

  defp start_profiler_profiling(state, tracing_processes) do
    with {:ok, processes_to_profile, new_state} <- get_processes_alive(state, tracing_processes),
         :ok <- do_start_profiler_profiling(new_state, processes_to_profile)
      do
      {:ok, processes_to_profile, new_state}
    else
      error -> error
    end
  end

  ##
  ## Start profiling if profiler is cprof
  ##
  defp do_start_profiler_profiling(%{profiler: :cprof} = state, _tracing_processes) do
    {mod, fun} = get_mf(state)
    :cprof.start(mod, fun)
    :ok
  end

  ##
  ## Start profiling if profiler is eprof
  ##
  defp do_start_profiler_profiling(%{profiler: :eprof, set_on_spawn: sos} = state, tracing_processes) do
    {mod, fun} = get_mf(state)
    with :profiling <- :eprof.start_profiling(tracing_processes, {mod, fun, :_}, [{:set_on_spawn, sos}])
      do
      :ok
    else
      _ -> {:error, :exit}
    end
  end

  ##
  ## Start profiling if profiler is fprof
  ##
  defp do_start_profiler_profiling(%{profiler: :fprof} = _state, tracing_processes) do
    with :ok <- :fprof.trace([:start, {:procs, tracing_processes}])
      do
      :ok
    else
      _ -> {:error, :exit}
    end
  end

  defp get_mf(%{code_profile_fun: fun, code_profiler_fun_only: true} = _state) when is_function(fun) do
    fun_info = Function.info(fun)
    {fun_info[:module], fun_info[:name]}
  end

  defp get_mf(%{profile_module: mod, profile_function: fun} = _state) do
    {mod, fun}
  end

  ##
  ## If on launch of the escript one or more processes were specified, we want to ensure they are still alive
  ## and if they are not see if they were named processes that have restarted
  ##
  defp get_processes_alive(%{profiler_node: profiler_node, pids_to_profile_cfg: processes_config, profiling_type_state: profiling_type} = state, tracing_processes) do
    if Enum.filter(tracing_processes, &(Process.alive?(&1))) != []  do
      {:ok, tracing_processes, state}
    else
      case profiling_type == :normal do
        true ->
          if ((new_processes = get_actual_pids(profiler_node, processes_config)) != [[]]) do
            {:ok, new_processes, %{state | pids_to_profile: new_processes}}
          else
            {:error, :exit}
          end
        _ ->
          {:error, :recover}
      end
    end
  end

  ##
  ## On user-request, timeout or code profiling complete we call this to get the profiling results
  ##
  defp profiling_complete(:pseudo_code_stop, %{temp_pseudo_data: {fun, label, time}, current_results_filename: filename} = _state) do
    fun_info = if fun == :no_fun,
                  do: [module: "Code Block", name: "Code Block", arity: :none],
                  else: Function.info(fun)
    module = Keyword.get(fun_info, :module, "Unknown")
    name = Keyword.get(fun_info, :name, "unknown")
    arity = Keyword.get(fun_info, :arity, "?")
    result = "\n***********************\n"
        <> "Pseudo Profiling Result\n"
        <> "-----------------------\n"
        <> "Module: #{inspect(module)}, Function: #{inspect(name)}/#{inspect(arity)}, Took: #{inspect(time)} microseconds\n\n"
        <> "Label: #{inspect(label)}\n"
        <> Enum.reduce(1..80, "", fn(_,a) -> "#{a}=" end)
        <> "\n"
    File.write(filename, result, [:write])
    result
  end

  defp profiling_complete(:pseudo_code_stop, _state), do: ""

  defp profiling_complete(_, %{profiler_node: profiler_node, monitors: monitors, current_label: label} = state) do
    Enum.each(monitors, &Process.demonitor(&1))
    do_state_change(profiler_node, :no_change)
    try do
      do_profiling_complete(state)
      do_state_change(profiler_node, :waiting)
      if label do
        save_filename(profiler_node, get_actual_filename(state))
      else
        save_filename(profiler_node, get_actual_filename(state), label)
      end
    rescue
      _ ->
        display_message(profiler_node, :profiler_problem)
    end
  end

  defp get_actual_filename(%{label_transition?: true,  current_results_filename: @temp_results_file} = _state), do: @saved_temp_results_file

  defp get_actual_filename(%{current_results_filename: filename} = _state), do: filename

  defp do_profiling_complete(%{profiler: :cprof, current_results_filename: filename, display_label: label} = _state) do
    :cprof.pause()
    {_, results} = :cprof.analyse()
    :cprof.stop()
    IO.inspect results, limit: :infinity
    {_, fd} = :file.open(filename, [:write])
    :io.fwrite(fd, "~s~n",["["])
    Enum.each(results,
      fn {mod, calls, data} ->
        :io.fwrite(fd, " {~p, ~p,~n~s  ~n", [mod, calls, "  ["])
        Enum.each(data, fn line -> :io.fwrite(fd,"    ~p,~n", [line]) end)
        :io.fwrite(fd,"~s~n~n",["  ]},"])
      end)
    :io.fwrite(fd,"~s~n",["]"])
    :file.close(fd)
    IO.puts("\nLabel: #{inspect(label)}")
  end

  ## For eprof filename is specified in :eprof.log earlier
  defp do_profiling_complete(%{profiler: :eprof, sort: sort, display_label: label} = _state) do
    try do
      :eprof.stop_profiling()
      :eprof.analyze([sort: sort])
      IO.puts("\nLabel: #{inspect(label)}")
    rescue
      _ -> :exception
    end
  end

  defp do_profiling_complete(%{current_results_filename: filename, sort: sort} = _state) do
    filename = if filename == "" do @temp_results_file else filename end
    :fprof.trace([:stop])
    :fprof.profile()
    :fprof.analyse([:totals, {:dest, to_charlist(filename)}, {:sort, sort}])
  end

  defp do_profiling_stop(:cprof) do
    :cprof.stop()
  end

  defp do_profiling_stop(:eprof) do
    :eprof.stop_profiling()
  end

  defp do_profiling_stop(_) do
    :fprof.profile([:stop])
  end

  defp save_filename(node, filename) do
    save_filename(node, filename, nil)
  end

  defp save_filename(node, "", _label) do
    display_message(node, :new_line)
  end

  defp save_filename(node, filename, label) when label do
    display_message(node, :stopped_profiling_label, [filename, label])
    send({:main_event_handler, node}, {:new_filename, filename})
  end

  defp save_filename(node, filename, _label) do
    display_message(node, :stopped_profiling, [filename])
    send({:main_event_handler, node}, {:new_filename, filename})
  end

  defp display_message(node, message_tag, args \\ nil) do
    send({:main_event_handler, node}, {:display_message, {message_tag, args}})
  end

  defp get_actual_pids(profiler_node, process_cfg) do
    :rpc.call(profiler_node, EZProfiler.TermHelper, :get_actual_pids, [node(), process_cfg])
  end

  ##
  ## Files will be something like /tmp/profiler_eprof.12
  ## This gets the latest index
  ##
  defp profile_file_idx(directory) when is_binary(directory) do
    try do
      current_idx = File.ls!(directory)
                    |> Enum.filter(fn fname -> String.contains?(fname, "profiler") end)
                    |> Enum.map(fn p -> [_,i] = String.split(p,"."); String.to_integer(i) end)
                    |> Enum.sort()
                    |> List.last()
      current_idx + 1
    rescue
      _ -> 0
    end
  end

  defp profile_file_idx(_) do
    0
  end

  defp log_to_file(%{results_directory: directory, results_file_index: count, profiler: profiler} = state) when is_binary(directory) do
    filename = directory <> "/profiler_" <> Atom.to_string(profiler) <> "." <> Integer.to_string(count)
    if profiler == :eprof, do: :eprof.log(filename)
    %{state | current_results_filename: filename, results_file_index: count + 1}
  end

  defp log_to_file(%{profiling_type_state: :code, profiler: profiler} = state) do
    if profiler == :eprof, do: :eprof.log(@temp_results_file)
    %{state | current_results_filename: @temp_results_file}
  end

  defp log_to_file(state) do
    %{state | current_results_filename: ""}
  end

  defp do_state_change(node, new_state) do
    send({:main_event_handler, node}, {:state_change, self(), new_state})
    receive do
      :state_change_ack -> :ok
    after
      2000 -> :ok
    end
  end

  defp do_state_change_nb(node, new_state) do
    send({:main_event_handler, node}, {:state_change, new_state})
  end

  defp respond_to_code(:code, message, [pid]) when is_pid(pid) do
    send(pid, message)
  end

  defp respond_to_code(_, _, _) do
    :ok
  end

  defp respond_to_manager(message, pid) when is_pid(pid), do:
    send(pid, message)

  defp respond_to_manager(_, _), do:
    :ok

  defp start_profiler(%{profiler: :cprof} = _state) do
    :cprof
  end

  defp start_profiler(%{profiler: profiler} = _state) do
    case profiler.start() do
      {:ok, profiler_pid} ->
        Process.monitor(profiler_pid)
        profiler_pid
      {:error, {:already_started, profiler_pid}} ->
        Process.monitor(profiler_pid)
        profiler_pid
    end
  end

  defp set_next_state(%{current_labels: [], code_tracing_pid: pid} = state) do
    respond_to_code(:code, :code_profiling_stopped, [pid])
    state
  end

  defp set_next_state(%{display_labels: current_labels, label_transition?: true, code_manager_pid: cpid, code_tracing_pid: pid} = state) do
    respond_to_code(:code, :code_profiling_stopped, [pid])
    {_, next_state} = handle_event(:cast, {:allow_code_profiling, current_labels, cpid, true}, :waiting, state)
    next_state
  end

  defp set_next_state(%{code_tracing_pid: pid} = state) do
    respond_to_code(:code, :code_profiling_stopped, [pid])
    state
  end

  defp lower_labels(labels), do:
    Enum.map(labels, &(lower_label(&1)))

  defp lower_label(label) when is_binary(label), do:
    String.downcase(label)

  defp lower_label(label), do:
    label

  defp finalize_results_file(file_data, %{current_results_filename: filename} = state) do
    if state.label_transition? do
      File.write(@saved_temp_results_file, file_data, [:append])
      if state.current_labels == [], do:
        File.cp(@saved_temp_results_file, filename)
    end
    file_data
  end

  defp make_final_results(:code_stop, %{current_results_filename: filename} = state) do
    data = "\nLabel: #{inspect(state.display_label)}\n"
           <> Enum.reduce(1..80, "", fn(_,a) -> "#{a}=" end)
           <> "\n"
    File.write(filename, data, [:append])
    File.read!(filename)
  end

  defp make_final_results(_, %{current_results_filename: filename} = _state) do
    File.read!(filename)
  end

  defp respond_to_tester(test_pid, display_label) when is_pid(test_pid) do
    if test_pid, do:
      send(test_pid, {:code_stop, display_label})
  end

  defp respond_to_tester(_, _), do:
    :ok

  defp allow_profiling_again(labels, %{label_transition?: true} = _state), do:
    CodeProfiler.allow_profiling_async(labels)

  defp allow_profiling_again(labels, _state), do:
    CodeProfiler.allow_profiling_async(labels)

end
