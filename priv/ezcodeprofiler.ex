defmodule EZProfiler.CodeProfiler do

  @on_load :cleanup

  def cleanup() do
    spawn(fn ->
      Process.sleep(1000)
      :code.purge(EZProfiler.ProfilerOnTarget)
      :code.delete(EZProfiler.ProfilerOnTarget)
      :code.purge(EZProfiler.CodeMonitor)
      :code.delete(EZProfiler.CodeMonitor)
    end)
    :ok
  end

  def start() do

  end

  def allow_profiling() do

  end

  def disallow_profiling() do

  end

  def start_code_profiling() do

  end

  def start_code_profiling(_label_or_fun) do

  end

  def function_profiling(fun, args) do
    Kernel.apply(fun, args)
  end

  def function_profiling(fun, args, _label_or_fun)  do
    Kernel.apply(fun, args)
  end

  def pipe_profiling(arg, fun, args) do
    Kernel.apply(fun, [arg|args])
  end

  def pipe_profiling(arg, fun, args, _label_or_fun) do
    Kernel.apply(fun, [arg|args])
  end

  def stop_code_profiling() do

  end

  def get() do

  end

end
