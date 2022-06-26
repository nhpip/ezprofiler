defmodule EZProfiler.CodeProfiler do
  @moduledoc """
  This module handles code profiling. The user hits 'c' or 'c label' and any process whose code calls the function
  'EZCodeProfiler.start_profiling' will be profiled until 'EZCodeProfiler.stop_profiling` is called. Only a single
  process at a time can be profiled. Other profiling functions allow for pipe profiling and function profiling.

  The module is loaded from the escript, replacing the one in the release, the reverse happens when the escript terminates.
  The module in the release has functions like:

    def start_profiling() do

    end

  So they are all no-ops with no run-time cost.

  There is a minimal run-time cost when the module is loaded, as much as a message to an Agent.
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

  ## Example (atom)

      def foo() do
         x = function1()
         y = function2()
         EZProfiler.CodeProfiler.start_code_profiling(:my_label)
         bar(x)
         baz(y)
         EZProfiler.CodeProfiler.stop_code_profiling()
      end

  ## Example (anonymous function)

      EZProfiler.CodeProfiler.start_code_profiling(fn -> if should_i_profile?(foo), do: :my_label, else: :nok end)

      case do_send_email(email, private_key) do
        :ok ->
          EZProfiler.CodeProfiler.stop_code_profiling()


  Then in the `ezprofiler` console:

       waiting..(4)> c my_label
       waiting..(5)>
       Code profiling enabled with a label of :my_label

       waiting..(5)>
       Got a start profiling from source code with label of :my_label

  NOTE: If anonymous function is used it must return an atom (label) to allow profiling ot the atom `:nok` to not profile.

  """
  def start_code_profiling(label_or_fun) when is_atom(label_or_fun) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, label_or_fun}, state) end)
    receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
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
  Profiles a specific function

  ## Example

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&bar/1, [x])
      end

  """
  def function_profiling(fun, args), do:
    function_profiling(fun, args, :no_label)

  @doc """
  Starts profiling a function using label (atom) or an anonymous function to target the results.

  ## Example (atom)

      def foo() do
        x = function1()
        y = function2()
        EZProfiler.CodeProfiler.function_profiling(&bar/1, [x], :my_label)
      end


  ## Example (anonymous function)

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

  NOTE: If anonymous function is used it must return an atom (label) to allow profiling ot the atom `:nok` to not profile.

  """
  def function_profiling(fun, args, label_or_fun) when is_function(fun) and is_atom(label_or_fun) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, label_or_fun}, state) end)
    receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, args)
    stop_code_profiling()
    rsp
  end

  ##
  ## Instead of a label a anonymous function can be used as an extra filter.
  ## The anonymous function should return the atom :nok if profiling is not to be started,
  ## or the atom :any_label or an actual label if profiling is needed
  ##
  def function_profiling(fun, args, fun2) when is_function(fun) and is_function(fun2) do
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
  Starts profiling a function in a pipe.

  ## Example

      def foo(data) do
         x = function1()
         data |> bar() |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, [x]) |> function2()
      end

  NOTE: It is advisable to filter results with `--mf` or the `u` option in the `ezprofiler` console

  """
  def pipe_profiling(arg, fun, args) do
    pipe_profiling(arg, fun, args, :no_label)
  end

  @doc """
  Starts profiling a function in a pipe using label (atom) or an anonymous function to target the results.

  ## Example (atom)

      def foo(data) do
         x = function1()
         data
         |> bar()
         |> EZProfiler.CodeProfiler.pipe_profiling(&baz/1, [x], :my_label)
         |> function2()
      end


  ## Example (anonymous function)

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

  NOTE: If anonymous function is used it must return an atom (label) to allow profiling ot the atom `:nok` to not profile.
  
  NOTE: It is advisable to filter results with `--mf` or the `u` option in the `ezprofiler` console

  """
  def pipe_profiling(arg, fun, args, label_or_fun) when is_atom(label_or_fun) do
    pid = self()
    Agent.get_and_update(__MODULE__, fn state -> do_start_profiling({pid, label_or_fun}, state) end)
    receive do
      :code_profiling_started -> :code_profiling_started
      :code_profiling_not_started_disallowed -> :code_profiling_not_started_disallowed
      :code_profiling_not_started_invalid_label -> :code_profiling_not_started_invalid_label
    end
    rsp = Kernel.apply(fun, [arg | args])
    stop_code_profiling()
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
  def stop_code_profiling() do
    pid = self()
    Agent.update(__MODULE__, fn state -> do_stop_profiling(pid, state) end)
    receive do
      :code_profiling_stopped -> :code_profiling_stopped
      :code_profiling_never_started -> :code_profiling_never_started
    end
  end

  @doc false
  def get() do
    Agent.get(__MODULE__, &(&1))
  end

  defp do_start_profiling({pid, _label}, %{allow_profiling: false} = state) do
    send(pid, :code_profiling_not_started_disallowed)
    {false, state}
  end

  defp do_start_profiling({pid, label}, %{label: my_label} = state)  when label == my_label do
    ProfilerOnTarget.start_code_profiling(pid, label)
    {true, %{state | allow_profiling: false, clear_pid: pid, label: :any_label}}
  end

  defp do_start_profiling({pid, label}, %{label: :any_label} = state) do
    ProfilerOnTarget.start_code_profiling(pid, label)
    {true, %{state | allow_profiling: false, clear_pid: pid, label: :any_label}}
  end

  defp do_start_profiling({pid, _label}, state) do
    send(pid, :code_profiling_not_started_invalid_label)
    {false, state}
  end

  defp do_stop_profiling(pid, %{clear_pid: pid} = state) do
    ProfilerOnTarget.stop_code_profiling()
    %{state | allow_profiling: false, clear_pid: nil, label: :any_label}
  end

  defp do_stop_profiling(pid, state) do
    send(pid, :code_profiling_never_started)
    state
  end

end
