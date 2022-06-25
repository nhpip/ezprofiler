# ezprofiler

Provides a simple to use profiling mechanism to inspect the behavior of an application on a target VM. Under the hood it utilizes Erlang's profiler tools, namely `eprof`, the default, `fprof` or `cprof`.

## Overview
The `ezprofiler` utilty presents the user with two types of profiling, both controlled via a simple shell-type interface.

#### Process profiling 
Attach the profiler to specific processes, registered names or pg//pg2 groups. When profiling starts those processes will be traced.

#### Code Profiling
The process identifier can be omitted. Instead the code can be decorated with profiling start/stop functions. In this case, to simplify the analysis, only a single (the first) process to git that code block will be monitored. This is useful in, for example, web-based applications where 100's of processes maybe spawned and invoke the same code at the same time.

### Process Profiling
This is when you know the process that you want to profile, the process is specified as a pid, registered name or PG2 group. The process or processes are specified with the command line option `--processes`. This coupled with the `--sos` (set on spawn) option can profile a process and carry on the profiling on all processes that are spawned by the target process. A useful process is `ranch` this will follow the spawned processes that are created on an inbound request.

For example:
```
$ ./ezprofiler --node myapp@localhost --processes name --sos --mf "_:_"

Options:

     's' to start profiling when 'waiting'
     'a' to get profiling results when 'profiling'
     'r' to abandon (reset) profiling and go back to 'waiting' state with initial value for 'u' set
     'c' to enable code profiling (once)
     'c' "label"to enable code profiling (once) for label (an atom), e.g. "c special_atom"
     'u' "M:F" to update the module and function to trace (only with eprof)
     'v' to view last saved results file
     'g' for debugging, returns the state on the target VM
     'h' this help text
     'q' to exit

waiting..(1)>
```
Profiling has currently not started. The user selects `'s'` to commence profiling:
```
waiting..(1)> s
waiting..(2)>
profiling(2)>
```
The utility is now profiling as seen by the change in prompt, when ready to get the results select `'a'` for analyze. 
```
profiling(2)>
profiling(2)> a

****** Process <9272.3831.0>    -- 62.53 % of profiled time ***
FUNCTION                                                                                             CALLS        %  TIME  [uS / CALLS]
--------                                                                                             -----  -------  ----  [----------]
'Elixir.Ecto.Adapters.Postgres.Connection':query/4                                                       1     0.00     0  [      0.00]
'Elixir.DBConnection':'-transaction/3-fun-2-'/4                                                          1     0.00     0  [      0.00]
'Elixir.DBConnection':'-execute/4-fun-0-'/5                                                              1     0.00     0  [      0.00]
'Elixir.DBConnection':'-commit/3-fun-0-'/3                                                               1     0.00     0  [      0.00]
'Elixir.DBConnection':'-begin/3-fun-0-'/3                                                                1     0.00     0  [      0.00]
'Elixir.Inspect.Atom':color_key/1                                                                        1     0.00     0  [      0.00]
'Elixir.Ecto.Queryable.Ecto.Query':to_query/1                                                            1     0.00     0  [      0.00]
'Elixir.Ecto.Repo.Queryable':postprocessor/4                                                             1     0.00     0  [      0.00]
'Elixir.Proto.Notification.AuthResponse':new/0                                                           1     0.00     0  [      0.00]
cow_http_hd:token_ci_list/2                                                                              1     0.00     0  [      0.00]
'Elixir.Postgrex.DefaultTypes':decode_rows/4                                                             2     0.00     0  [      0.00]
'Elixir.Postgrex.DefaultTypes':'-encode_params/3-anonymous-2-'/2                                         1     0.00     0  [      0.00]
lists:keystore/4                                                                                         2     0.00     0  [      0.00]

...... SNIP ......
 
'Elixir.Enum':'-reduce/3-lists^foldl/2-0-'/3                             445     8.73   235  [      0.53]
erts_internal:port_control/3                                               3    17.69   476  [    158.67]
---------------------------------------------------------------------  -----  -------  ----  [----------]
Total:                                                                  3042  100.00%  2691  [      0.88]

waiting..(3)>
waiting..(3)> 
```

This can produce a lot of output since the `--mf` option was a wildcard. It's possible to focus in on a specific module and function and repeat. For example select the Erlang `lists` module.

```
waiting..(4)> u lists:_

Updated the module and function
waiting..(5)> s
waiting..(6)>
profiling(6)> a
profiling(7)>

****** Process <9272.3882.0>    -- 48.30 % of profiled time ***
FUNCTION           CALLS        %  TIME  [uS / CALLS]
--------           -----  -------  ----  [----------]
lists:prefix/2         7     0.09     2  [      0.29]
lists:keystore/4       2     0.09     2  [      1.00]
lists:foreach/2        6     0.13     3  [      0.50]
lists:keystore2/4      9     0.17     4  [      0.44]
lists:member/2         5     0.17     4  [      0.80]
lists:reverse/2       23     0.73    17  [      0.74]
lists:foldl/3         42     0.90    21  [      0.50]
lists:reverse/1      105     1.28    30  [      0.29]
lists:keymember/3      4     1.62    38  [      9.50]
lists:keyfind/3      133    94.83  2220  [     16.69]
-----------------  -----  -------  ----  [----------]
Total:               336  100.00%  2341  [      6.97]
```
If specified with the `--directory` option the results can be saved and the last set of results can be re-displayed by pressing `'v'` (see below).

**NOTE:** If `fprof` is selected as the profiler the results will not be output to screen unless `'v'` is selected.

### Code Profiling
This permits the profiling of code dynamically. The user can decorate functions or blocks of code, and when ready the user can, from the escript, start profiling that function or block of code. The decorating is quite simple, the file `priv/ezcodeprofiler.ex` should be included in your application. This module contains stub functions that you can place throughout your code that have zero run-time cost. When the profiler connects to your application this code is hot-swapped out for a module with the same name, containing the same fucntion names. These functions contain actual working code. The run-time cost is stil miinimal as only a single process will be monitored at a time.

For example, this will profile anything between `start_code_profiling/0` and `stop_code_profiling/0`
```
def foo() do
   x = function1()
   y = function2()
   EZCodeProfiler.start_code_profiling()
   bar(x)
   baz(y)
   EZCodeProfiler.stop_code_profiling()
end
```
This will just profile a specific function
```
def foo() do
   x = function1()
   y = function2()
   EZCodeProfiler.function_profiling(&bar/1, [x])
end
```
Or in a pipelne:
```
def foo(data) do
   x = function1()
   data |> bar() |> EZCodeProfiler.pipe_profiling(&baz/1, [x]) |> function2()
end

```
### NEED TO COMPLETE ###

## Compiling
Execute `mix escript.build`

## Usage
```
ezprofiler --help

ezprofiler:

 --node [node]: the Erlang VM you want tracing on (e.g. myapp@localhost)

 --cookie [cookie]: the VM cookie (optional)

 --processes [pid or reg_name]: the remote process pid (e.g. "<0.249.0>") or registered name you want to trace (other options ranch or pg/pg2 group)

 --sos: if present will apply tracing to any process spawned by the one defined in --process

 --mf [string]: a specification of module:fun of which module and functions to trace, with underscore _ as a wildcard.
              Example "Foo:bar" will trace calls to Foo:bar "Foo:_" will trace calls to all functions in module Foo (default is "_:_")

 --directory: where to store the results
 
 --maxtime: the maximum time we allow profiling for (default 60 seconds)

 --profiler: one of eprof, cprof or fprof, default eprof

 --sort: for eprof one of time, calls, mfa (default time), for fprof one of acc or own (default acc). Nothing for cprof

 --help: this page
```

