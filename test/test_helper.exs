defmodule EZProfiler.Test do

   def block_test1() do

   end

   def start_code_profiling(), do:
      start_code_profiling(:any_label)

   def start_code_profiling(label), do:
      EZProfiler.ProfilerOnTarget.allow_code_profiling(node(), label)

   defp display_messsage(message), do:
    send({:main_event_handler, :ezprofiler@localhost}, {:display_message, {:message, message}})

end
