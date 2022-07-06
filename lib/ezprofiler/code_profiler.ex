defmodule EZProfiler.CodeProfiler do
  @moduledoc """
  This module handles code profiling. The user hits `c` or `c label` and any process whose code calls the function
  `EZCodeProfiler.start_profiling` will be profiled until `EZCodeProfiler.stop_profiling` is called. Only a single
  process at a time can be profiled. Other profiling functions allow for pipe profiling and function profiling.

  The module is loaded from the escript, replacing the one in the release, the reverse happens when the escript terminates.
  The module in the release has functions like:

      def start_profiling() do

      end

  So they are all no-ops with no run-time cost.

  There is a minimal run-time cost when the module is loaded, as much as a message to an Agent.
  """

  @on_load :xxx

  use Agent
  alias EZProfiler.ProfilerOnTarget

  def xxx() do
    IO.inspect({:real,:code.module_status(__MODULE__)})
    :ok
  end

  @doc false
  def child_spec(_), do: :ok

  ##
  ## In reality not ever called, the Agent is started before the module is loaded to avoid
  ## calls to the module functions from failing if the Agent is not there
  ##
  @doc false
  def start() do
    Agent.start(fn -> %{allow_profiling: false, clear_pid: nil, label: :any_label} end, name: __MODULE__)
  end

  ##
  ## Invoked from the state machine on a user hitting 'c' to start code profiling
  ##
  @doc false
  def allow_profiling(label) do
    Agent.update(__MODULE__, fn state -> %{state | allow_profiling: true, label: label} end)
  end

  ##
  ## When a user hits reset ('r') or a timeout occurs this is called. A subsequent call to
  ## allow_profiling needs to be called again (user hitting 'c')
  ##
  @doc false
  def disallow_profiling() do
    Agent.update(__MODULE__, fn state -> %{state | allow_profiling: false, clear_pid: nil, label: :any_label} end)
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
  ## Called when we want to match on a label. If the label atom is passed that matches 'c label'
  ## then that process will be traced
  ##
  @doc """
  Starts profiling a block of code using a label (atom) or an anonymous function to target the results.

  ## Options

    - options: Can be either a label (atom) or anonymous function returning a label

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

      waiting..(4)> c my_label
      waiting..(5)>
      Code profiling enabled with a label of :my_label

      waiting..(5)>
      Got a start profiling from source code with label of :my_label

  **NOTE:** If anonymous function is used it must return an atom (label) to allow profiling or the atom `:nok` to not profile.

  """
  def start_code_profiling(options) when is_atom(options) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, nil, options}, state) end)
    action = receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    Process.put(:ezprofiler, action)
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
        EZProfiler.CodeProfiler.function_profiling(&bar/0)
      end

  """
  def function_profiling(fun), do:
    function_profiling(fun, :no_label)

  @doc """
  Profiles a specific function with arguments and control labels/functions.

  ## Options

    - fun: The function (capture) to profile
    - options: Can be either a list of arguments, a label (atom) or anonymous function returning a label

  Starts profiling a function with arguments only:

  ## Example

       def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.function_profiling(&bar/1, [x])
       end


  Starts profiling a function using label:

  ## Example

       def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.function_profiling(&bar/0, :my_label)
       end


  Starts profiling with an anonymous function:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&bar/0, fn -> if should_i_profile?(y), do: :my_label, else: :nok end)
      end


  Then in the `ezprofiler` console:

      waiting..(1)> c
      waiting..(2)>
      Code profiling enabled

  Or with a label:

       waiting..(4)> c my_label
       waiting..(5)>
       Code profiling enabled with a label of :my_label

       waiting..(5)>
       Got a start profiling from source code with label of :my_label

  **NOTE:** If anonymous function is used it must return an atom (label) to allow profiling or the atom `:nok` to not profile.

  """
  def function_profiling(fun, options)

  def function_profiling(fun, args) when is_list(args), do:
    function_profiling(fun, args, :no_label)

  def function_profiling(fun, label) when is_function(fun) and is_atom(label) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, fun, label}, state) end)
    action = receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, [])
    stop_code_profiling(action)
    rsp
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
    - options: Can be either a label (atom) or anonymous function returning a label

  Starts profiling a function using arguments and a label:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&bar/1, [x], :my_label)
      end


  Starts profiling a function using arguments and an anonymous function:

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&bar/1, [x], fn -> if should_i_profile?(y), do: :my_label, else: :nok end)
      end


  Then in the `ezprofiler` console:

       waiting..(4)> c my_label
       waiting..(5)>
       Code profiling enabled with a label of :my_label

       waiting..(5)>
       Got a start profiling from source code with label of :my_label

  **NOTE:** If anonymous function is used it must return an atom (label) to allow profiling or the atom `:nok` to not profile.

  """
  def function_profiling(fun, args, options)

  def function_profiling(fun, args, label) when is_list(args) and is_function(fun) and is_atom(label) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, fun, label}, state) end)
    action = receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, args)
    stop_code_profiling(action)
    rsp
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
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1)
         |> function2()
      end

  """
  def pipe_profiling(arg, fun) when is_function(fun) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, fun, :no_label}, state) end)
    action = receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, [arg])
    stop_code_profiling(action)
    rsp
  end

  @doc """
  Profiles a specific function in a pipe with arguments and/or control labels/functions.

  ## Options

    - arg: The argument passed in from the previous function/term in the sequence
    - fun: The function (capture) to profile
    - options: Can be either extra arguments, a label (atom) or anonymous function returning a label

  Starts profiling a function in a pipe using extra arguments:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, [x])
         |> function2()
      end

  Starts profiling a function in a pipe using a label without extra arguments:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, :my_label)
         |> function2()
      end

  Starts profiling without extra arguments and an anonymous function:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, fn -> if should_i_profile?(x), do: :my_label, else: :nok end)
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
    - options: Either a label (atom) or anonymous function returning a label

  Starts profiling using arguments and a label:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, [x], :my_label)
         |> function2()
      end

  Starts profiling using arguments and an anonymous function:

  ## Example

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, [x], fn -> if should_i_profile?(x), do: :my_label, else: :nok end)
         |> function2()
      end

  Then in the `ezprofiler` console:

      waiting..(4)> c my_label
      waiting..(5)>
      Code profiling enabled with a label of :my_label

      waiting..(5)>
      Got a start profiling from source code with label of :my_label

    **NOTE:** If anonymous function is used it must return an atom (label) to allow profiling or the atom `:nok` to not profile.

  """
  def pipe_profiling(arg, fun, args, options)

  def pipe_profiling(arg, fun, args, options) when is_atom(options) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, fun, options}, state) end)
    action = receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, [arg | args])
    stop_code_profiling(action)
    rsp
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
  def stop_code_profiling(), do:
    stop_code_profiling(Process.get(:ezprofiler, :code_profiling_started))

  @doc false
  def stop_code_profiling(:code_profiling_started) do
    pid = self()
    ## Do this instead of Agent.get_and_update/2 to minimize non-profiling functions in the output
    send(__MODULE__, {:"$gen_call", {pid, :no_ref}, {:get_and_update, fn state -> do_stop_profiling(pid, state) end}})
    receive do
      {:no_ref, _} -> :ok
    end
    receive do
      :code_profiling_stopped -> :code_profiling_stopped
      :code_profiling_never_started -> :code_profiling_never_started
    end
  end

  def stop_code_profiling(_), do:
    :ok

  @doc false
  def get() do
    Agent.get(__MODULE__, &(&1))
  end

  defp do_start_profiling({pid, _fun, _label}, %{allow_profiling: false} = state) do
    send(pid, :code_profiling_not_started_disallowed)
    {false, state}
  end

  defp do_start_profiling({pid, fun, label}, %{label: my_label} = state)  when label == my_label do
    ProfilerOnTarget.start_code_profiling(pid, fun, label)
    {true, %{state | allow_profiling: false, clear_pid: pid, label: :any_label}}
  end

  defp do_start_profiling({pid, fun, label}, %{label: :any_label} = state) do
    ProfilerOnTarget.start_code_profiling(pid, fun, label)
    {true, %{state | allow_profiling: false, clear_pid: pid, label: :any_label}}
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

end
