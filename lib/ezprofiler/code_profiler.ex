defmodule EZProfiler.CodeProfiler do
  @moduledoc """
  This module handles code profiling. The user hits `c` or `c label` or `EZProfiler.Manager.enable_profiling/1` and any process whose code calls
  one of the profiling functions is profiled. Only a single process at a time can be profiled, although label transition can assist in that.

  The module is loaded from the escript, replacing the one in the application, the reverse happens when the escript terminates.

  The module in the release has functions like:

      def start_profiling() do

      end

  So they are mostly no-ops, with no run-time cost.

  There is a minimal run-time cost when the module is loaded, as much as a message to an Agent.

  ## Block Profiling
  Profile a block of code. If the function `EZCodeProfiler.start_profiling` is called, any code between that and `EZCodeProfiler.stop_profiling` is profiled.

  ## Function Profiling
  Profiles a specific function using `EZProfiler.CodeProfiler.function_profiling`.

  ## Pipe Profiling
  Profiles a function within an Elixir pipe using `EZProfiler.CodeProfiler.pipe_profiling`.

  **NOTE:** The function we want to profile for function profiling and pipe function is specified as a function capture. It is recommended to include the module name (`&MyModule.foo/1` not `&foo/1`)

  ## Labels
  When using either the CLI `c labels` or `EZProfiler.Manager.enable_profiling/1` either a single label or a list of labels can be specified. In the case
  of a list there are two modes of operation, label transition (`labeltran`) `true` or label transition `false` (the default). The behavior is as follows:

  #### Label Transition `false`
  This effectively a request to profile *one-of* those labels. The first matching label is selected for profiling and the rest of the labels are ignored.

  #### Label Transition `true`
  In this case all specified labels shall be profiled sequentially (order doesn't matter), effectively the profiler automatically re-enables profiling after a label match.
  A label that matches and is profiled, will removed from the list of labels to be profiled next and profiling is re-enabled for the remaining labels.
  This allows profiling to follow the flow of code through your application, even if processes are switched. It is important to note that the rule of only one process
  at a time can be profiled still exists, so ideally they should be sequential.

  However, if there are sections of want to be profiled code that overlap in time `ezprofiler` performs `pseudo profiling` where `ezprofiler` will at least calculate and
  display how long the profiled code took to execute.

  """

  use Agent
  alias EZProfiler.ProfilerOnTarget

  @doc false
  def child_spec(_), do: :ok

  ##
  ## In reality not ever called, the Agent is started before the module is loaded to avoid
  ## calls to the module functions from failing if the Agent is not there
  ##
  @doc false
  def start() do
    Agent.start(fn -> %{allow_profiling: false, clear_pid: nil, labels: [], label_transition?: false} end, name: __MODULE__)
  end

  ##
  ## Invoked from the state machine on a user hitting 'c' to start code profiling
  ##
  @doc false
  def allow_profiling(labels) do
    Agent.update(__MODULE__, fn state -> %{state | allow_profiling: true, labels: labels} end)
  end

  ##
  ## Async version of above
  ##
  @doc false
  def allow_profiling_async(labels) do
    Agent.cast(__MODULE__, fn state -> %{state | allow_profiling: true, labels: labels} end)
  end

  ##
  ## When a user hits reset ('r') or a timeout occurs this is called. A subsequent call to
  ## allow_profiling needs to be called again (user hitting 'c')
  ##
  @doc false
  def disallow_profiling() do
    Agent.update(__MODULE__, fn state -> %{state | allow_profiling: false, clear_pid: nil, labels: []} end)
  end

  ##
  ## If label transition is set or unset
  ##
  @doc false
  def allow_label_transition(transition?) do
    Agent.update(__MODULE__, fn state -> %{state | label_transition?: transition?} end)
  end

  ##
  ## Called from the code base. If no label is set then the first process that hits this function will be profiled
  ##
  @doc """
  Starts profiling a block of code, must call `EZProfiler.CodeProfiler.stop_code_profiling()` to stop and present the results.

  ## Example

      def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.start_code_profiling()
         bar(x)
         baz(y)
         EZProfiler.CodeProfiler.stop_code_profiling()
      end

  """
  def start_code_profiling() do
    start_code_profiling(:no_label)
  end

  ##
  ## Called when we want to match on a label. If the label is passed that matches 'c label'
  ## then that process will be traced
  ##
  @doc """
  Starts profiling a block of code using a label (atom or string) or an anonymous function to target the results.

  ## Options

    - options: Can be either a label (atom or string) or anonymous function returning a label

  Starts profiling a function using label:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.start_code_profiling(:my_label)
        bar(x)
        baz(y)
        EZProfiler.CodeProfiler.stop_code_profiling()
      end

  Starts profiling a function using an anonymous function:

  ## Example

      EZProfiler.CodeProfiler.start_code_profiling(fn -> if should_i_profile?(foo), do: :my_label, else: :nok end)

      case do_send_email(email, private_key) do
        :ok ->
          EZProfiler.CodeProfiler.stop_code_profiling()


  Then in the `ezprofiler` console:

      waiting..(1)> c
      waiting..(2)>
      Code profiling enabled

  Or with a label:

      waiting..(4)> c :my_label
      waiting..(5)>
      Code profiling enabled with a label of :my_label

      waiting..(5)>
      Got a start profiling from source code with label of :my_label

  **NOTE:** If anonymous function is used it must return a label to allow profiling or the atom `:nok` to not profile.

  """
  def start_code_profiling(options) when is_atom(options) or is_binary(options) do
    {action, _} = do_profiling_setup(nil, options, :no_args)
    Process.put(:ezprofiler_data, [action, options, :os.timestamp()])
    action
  end

  ##
  ## Instead of a label a anonymous function can be used as an extra filter.
  ## The anonymous function should return the atom :nok if profiling is not to be started,
  ## or the atom :any_label or an actual label if profiling is needed
  ##
  def start_code_profiling(fun) when is_function(fun) do
    case fun.() do
      :nok ->
        :nok
      label ->
         start_code_profiling(label)
    end
  end

  ##
  ## Can pass a function plus arguments just to trace that function, no need to call stop_code_profiling
  ##
  @doc """
  Profiles a specific function without any arguments or labels.

  ## Options

    - fun: The function (capture) to profile

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/0)
      end

  """
  def function_profiling(fun), do:
    function_profiling(fun, :no_label)

  @doc """
  Profiles a specific function with arguments and control labels/functions.

  ## Options

    - fun: The function (capture) to profile
    - options: Can be either a list of arguments, a label (atom or string) or anonymous function returning a label

  Starts profiling a function with arguments only:

  ## Example

       def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/1, [x])
       end


  Starts profiling a function using label:

  ## Example

       def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/0, :my_label)
       end


  Starts profiling with an anonymous function:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/0, fn -> if should_i_profile?(y), do: :my_label, else: :nok end)
      end


  Then in the `ezprofiler` console:

      waiting..(1)> c
      waiting..(2)>
      Code profiling enabled

  Or with a label:

       waiting..(4)> c :my_label, bob@foo.com
       waiting..(5)>
       Code profiling enabled with a label of :my_label, bob@foo.com

       waiting..(5)>
       Got a start profiling from source code with label of :my_label

  Or using `EZProfiler.Manager`:

       # Will profile :my_label and/or "bob@foo.com", see main help on label transition
       EZProfiler.Manager.enable_profiling([:my_label, "bob@foo.com"])

  **NOTE:** If anonymous function is used it must return a label to allow profiling or the atom `:nok` to not profile.

  """
  def function_profiling(fun, options)

  def function_profiling(fun, args) when is_list(args), do:
    function_profiling(fun, args, :no_label)

  def function_profiling(fun, label) when is_function(fun) and (is_atom(label) or is_binary(label)) do
   {action, profiled_fun} = do_profiling_setup(fun, label, :no_args)
    rsp = profiled_fun.()
    stop_code_profiling(action, fun, label, rsp)
  end

  ##
  ## Instead of a label a anonymous function can be used as an extra filter.
  ## The anonymous function should return the atom :nok if profiling is not to be started,
  ## or the atom :any_label or an actual label if profiling is needed
  ##
  def function_profiling(fun, fun2) when is_function(fun) and is_function(fun2) do
    case fun2.() do
      :nok ->
        Kernel.apply(fun, [])
      label ->
        function_profiling(fun, label)
    end
  end

  @doc """
  Profiles a specific function with arguments and control labels/functions.

  ## Options

    - fun: The function (capture) to profile
    - args: The list of arguments to pass to the function
    - options: Can be either a label (atom or string) or anonymous function returning a label

  Starts profiling a function using arguments and a label:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/1, [x], "Profile 52")
      end


  Starts profiling a function using arguments and an anonymous function:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&MyModule.bar/1, [x], fn -> if should_i_profile?(y), do: "Profile 52", else: :nok end)
      end


  Then in the `ezprofiler` console:

       waiting..(4)> c "Profile 52"
       waiting..(5)>
       Code profiling enabled with a label of :my_label

       waiting..(5)>
       Got a start profiling from source code with label of "Profile 52"

  Or using `EZProfiler.Manager`:

       EZProfiler.Manager.enable_profiling("Profile 52")

  **NOTE:** If anonymous function is used it must return a label to allow profiling or the atom `:nok` to not profile.

  """
  def function_profiling(fun, args, options)

  def function_profiling(fun, args, label) when is_list(args) and is_function(fun) and (is_atom(label) or is_binary(label)) do
    {action, profiled_fun} = do_profiling_setup(fun, label, args)
    rsp = profiled_fun.()
    stop_code_profiling(action, fun, label, rsp)
  end

  def function_profiling(fun, args, fun2) when is_list(args) and is_function(fun) and is_function(fun2) do
    case fun2.() do
      :nok ->
        Kernel.apply(fun, args)
      label ->
        function_profiling(fun, args, label)
    end
  end

  ##
  ## For profiling a function in a set of pipe operations
  ## For example:
  ##
  ##  import EZProfiler.CodeProfiler
  ##
  ##  [1, :xxx, 2, 3, 4] |> Enum.filter(fn e -> is_integer(e) end) |> pipe_profiling(&Enum.sum/1,[]) |> Kernel.+(1000)
  ##
  @doc """
  Profiles a function in a pipe without any extra arguments.

  ## Options

    - arg: The argument passed in from the previous function/term in the sequence
    - fun: The function (capture) to profile

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1)
         |> function2()
      end

  """
  def pipe_profiling(arg, fun) when is_function(fun) do
    {action, profiled_fun} = do_profiling_setup(fun, :no_label, [arg])
    rsp = profiled_fun.()
    stop_code_profiling(action, fun, :no_label, rsp)
  end

  @doc """
  Profiles a specific function in a pipe with arguments and/or control labels/functions.

  ## Options

    - arg: The argument passed in from the previous function/term in the sequence
    - fun: The function (capture) to profile
    - options: Can be either extra arguments, a label (atom or string) or anonymous function returning a label

  Starts profiling a function in a pipe using extra arguments:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1, [x])
         |> function2()
      end

  Starts profiling a function in a pipe using a label without extra arguments:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1, :my_label)
         |> function2()
      end

  Starts profiling without extra arguments and an anonymous function:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1, fn -> if should_i_profile?(x), do: :my_label, else: :nok end)
         |> function2()
      end

  """
  def pipe_profiling(arg, fun, options)

  def pipe_profiling(arg, fun, options) when is_list(options), do:
    pipe_profiling(arg, fun, options, :no_label)

  def pipe_profiling(arg, fun, options), do:
    pipe_profiling(arg, fun, [], options)

  @doc """
  Profiles a specific function in a pipe with extra arguments and control labels/functions.

  ## Options

    - arg: The argument passed in from the previous function/term in the sequence
    - fun: The function (capture) to profile
    - args: The list of extra arguments to pass to the function
    - options: Either a label (atom or string) or anonymous function returning a label

  Starts profiling using arguments and a label:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1, [x], :my_label)
         |> function2()
      end

  Starts profiling using arguments and an anonymous function:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&MyModule.baz/1, [x], fn -> if should_i_profile?(x), do: :my_label, else: :nok end)
         |> function2()
      end

  Then in the `ezprofiler` console:

      waiting..(4)> c :my_label
      waiting..(5)>
      Code profiling enabled with a label of :my_label

      waiting..(5)>
      Got a start profiling from source code with label of :my_label

  Or using `EZProfiler.Manager`:

      EZProfiler.Manager.enable_profiling([:my_label, "bob@foo.com"])

    **NOTE:** If anonymous function is used it must return a label to allow profiling or the atom `:nok` to not profile.

  """
  def pipe_profiling(arg, fun, args, options)

  def pipe_profiling(arg, fun, args, options) when is_atom(options) or is_binary(options) do
    {action, profiled_fun} = do_profiling_setup(fun, options, [arg | args])
    rsp = profiled_fun.()
    stop_code_profiling(action, fun, options, rsp)
  end

  ##
  ## Instead of a label a anonymous function can be used as an extra filter.
  ## The anonymous function should return the atom :nok if profiling is not to be started,
  ## or the atom :any_label or an actual label if profiling is needed
  ##
  def pipe_profiling(arg, fun, args, fun2) when is_function(fun) and is_function(fun2) do
    case fun2.() do
      :nok ->
        Kernel.apply(fun, [arg | args])
      label ->
        pipe_profiling(arg, fun, args, label)
    end
  end

  ##
  ## Called in the code when profiling is to end. Only the process that started profiling
  ## will be successful if this is called. If omitted a timeout will end profiling
  ##
  @doc """
  Stops profiling a block oof code started with `start_code_profiling(..)`

  """
  def stop_code_profiling() do
    [action, label, start_time] = Process.get(:ezprofiler_data, [:code_profiling_not_started, :no_label, :os.timestamp()])

    stop_code_profiling(action, :no_fun, label, {:timer.now_diff(:os.timestamp(), start_time), :ok})
  end

  @doc false
  def stop_code_profiling(:code_profiling_started, _fun, _options, rsp) do
    pid = self()
    ## Do this instead of Agent.get_and_update/2 to minimize non-profiling functions in the output
    send(__MODULE__, {:"$gen_call", {pid, :no_ref}, {:get_and_update, fn state -> do_stop_profiling(pid, state) end}})
    wait_for_stop_events()
    ProfilerOnTarget.ping()
    rsp
  end

  def stop_code_profiling(:pseudo_code_profiling_started, fun, options, {time, rsp}) do
    ProfilerOnTarget.pseudo_stop_code_profiling(options, fun, time)
    rsp
  end

  def stop_code_profiling(_, _, _, rsp), do:
    rsp

  @doc false
  def get() do
    Agent.get(__MODULE__, &(&1))
  end

  defp do_profiling_setup(fun, options, args) do
    try do
      pid = self()
      Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, fun, options}, state) end)
      receive do
        :code_profiling_started -> make_response(:code_profiling_started, fun, args)
        :pseudo_code_profiling_started -> make_response(:pseudo_code_profiling_started, fun, args)
        :code_profiling_not_started_disallowed -> make_response(:code_profiling_not_started_disallowed, fun, args)
        :code_profiling_not_started_invalid_label -> make_response(:code_profiling_not_started_invalid_label, fun, args)
      after
        1000 -> make_response(:code_profiling_not_started_error, fun, args)
      end
    rescue
      _ -> make_response(:code_profiling_not_started_error, fun, args)
    end
  end

  defp wait_for_stop_events() do
    for _ <- 1..2 do
      receive do
        {:no_ref, _} -> :ok
        :code_profiling_stopped -> :code_profiling_stopped
        :code_profiling_never_started -> :code_profiling_never_started
      after
        1000 -> :error
      end
    end
  end

  defp make_response(:pseudo_code_profiling_started = msg, nil, _args) do
    {msg, nil}
  end

  defp make_response(:pseudo_code_profiling_started = msg, fun, :no_args) do
    {msg, fn -> :timer.tc(fun, []) end}
  end

  defp make_response(:pseudo_code_profiling_started = msg, fun, args) do
    {msg, fn -> :timer.tc(fun, args) end}
  end

  defp make_response(msg, fun, :no_args) do
    {msg, fn -> fun.() end}
  end

  defp make_response(msg, fun, args) do
    {msg, fn -> Kernel.apply(fun, args) end}
  end

  defp do_start_profiling({pid, _fun, _label}, %{allow_profiling: false, label_transition?: false} = state) do
    send(pid, :code_profiling_not_started_disallowed)
    {false, %{state | labels: []}}
  end

  defp do_start_profiling({pid, _fun, in_label}, %{labels: my_labels, allow_profiling: false} = state) do
    label = lower_label(in_label)
    if Enum.member?(my_labels, label) do
      ProfilerOnTarget.pseudo_start_code_profiling(label, in_label)
      send(pid, :pseudo_code_profiling_started)
      {true, %{state | labels: List.delete(my_labels, label)}}
    else
      send(pid, :code_profiling_not_started_disallowed)
      {false, state}
    end
  end

  defp do_start_profiling({pid, fun, :no_label = label}, state) do
    ProfilerOnTarget.start_code_profiling(pid, fun, label)
    {true, %{state | allow_profiling: false, clear_pid: pid, label: label}}
  end

  defp do_start_profiling({pid, fun, in_label}, %{labels: my_labels} = state) do
    label = lower_label(in_label)
    if Enum.member?(my_labels, label) do
      ProfilerOnTarget.start_code_profiling(pid, fun, label, in_label)
      {true, %{state | allow_profiling: false, clear_pid: pid, label: label, labels: List.delete(my_labels, label)}}
    else
      send(pid, :code_profiling_not_started_invalid_label)
      {false, state}
    end
  end

  defp do_start_profiling({pid, _fun, _label}, state) do
    send(pid, :code_profiling_not_started_invalid_label)
    {false, state}
  end

  defp do_stop_profiling(pid, %{clear_pid: pid} = state) do
    ProfilerOnTarget.stop_code_profiling()
    {true, %{state | allow_profiling: false, clear_pid: nil, label: :any_label}}
  end

  defp do_stop_profiling(pid, state) do
    send(pid, :code_profiling_never_started)
    state
  end

  defp lower_label(label) when is_binary(label), do:
    String.downcase(label)

  defp lower_label(label), do:
    label

end
