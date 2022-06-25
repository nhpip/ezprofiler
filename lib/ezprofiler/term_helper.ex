defmodule EZProfiler.TermHelper do

  @moduledoc false

  ##
  ##  This module contains helper functions to convert registered process names, pg2/pg names etc
  ##  into actual pids. It also converts modules and functions into something usable
  ##
 
  @pg_otp_version 23   # The OTP release where PG was introduced

  alias EZProfiler

  @doc false
  def get_profiler_mod_fun(mod_fun) do
    format_mod_fun(String.split(mod_fun, ":"))
  end

  @doc false
  def get_actual_pids(_node, []) do
    []
  end

  @doc false
  def get_actual_pids(node, processes) do
    processes = if String.at(processes,0) != "[" do "[" <> processes <> "]" else processes end

    {_,_,process_list} =  processes
                          |> String.replace("{","{,")
                          |> String.replace("}",",}")
                          |> String.split([",","[","]"])
                          |> Enum.filter(fn e -> e != "" end)
                          |> Enum.reduce({false,[],[]},
                               fn("{",{false,_ct,acc}) -> {true,[],acc};
                                 ("}",{true,ct,acc}) -> {false,[],[Enum.reverse(ct)|acc]};
                                 (item,{true,ct,acc}) -> {true,[format_registered_name_or_module(item)|ct],acc};
                                 (item,{false,ct,acc}) -> {false,ct,[item|acc]}
                               end)

    process_list = process_list
                   |> Enum.map(fn p when is_list(p) -> List.to_tuple(p); p ->p end)
                   |> Enum.map(fn p -> get_remote_pid(node, p) end)
    process_list
  end

  defp get_remote_pid(node, pid_or_reg) do
    pid_or_reg = try do
      Kernel.to_charlist(pid_or_reg)
    rescue
      _ -> pid_or_reg
    end
    with {:ok, res} <- get_pid_rpc(node, :erlang, :list_to_pid, [pid_or_reg]) do
      res
    else
      _ ->
        term = format_registered_name_or_module(pid_or_reg)

        with {:ok, res} <- get_pid_rpc(node, Process, :whereis, [term])
          do
          res
        else
          _ ->
            with {:ok,res} <- get_pg_pg2_rpc(node, term)
              do
              res
            else
              _ ->
                IO.puts("\nProcesses may no longer be valid...exiting\n")
                []
            end
        end
    end
  end

  defp get_pid_rpc(node, m, f, a) do
    case :rpc.call(node, m, f, a) do
      {:badrpc, rest} -> {:error, rest}
      {:error, rest} -> {:error, rest}
      res when is_pid(res) -> {:ok, res}
      [res] when is_pid(res) -> {:ok, res}
      _ -> :exception
    end
  end

  defp get_pg_pg2_rpc(node, term) do
    mod = if (:erlang.system_info(:otp_release) |> List.to_integer()) >= @pg_otp_version, do: :pg, else: :pg2
    case :rpc.call(node, mod, :get_local_members, [term]) do
      res when is_list(res) -> {:ok, res}
      _ -> {:error, term}
    end
  end

  defp format_mod_fun([module, function]) do
    [format_registered_name_or_module(module),String.to_atom(function)]
  end

  defp format_registered_name_or_module("_") do
    :_
  end

  defp format_registered_name_or_module(name) when is_tuple(name) do
    name
  end

  defp format_registered_name_or_module(name) when is_list(name) do
    format_registered_name_or_module(to_string(name))
  end

  defp format_registered_name_or_module(name) do
    first = String.at(name,0)
    if String.upcase(first) == first do
      if String.contains?(name,"Elixir") do
        String.to_atom(name)
      else
        String.to_atom("Elixir." <> name)
      end
    else
      String.to_atom(name)
    end
  end

end

