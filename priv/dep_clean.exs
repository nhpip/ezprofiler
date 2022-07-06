defmodule DepClean do

  def clean() do

  end

end
 
IO.puts("#{Path.relative_to_cwd(Mix.Project.deps_path())}")
IO.puts("#{Path.dirname(File.cwd!())}")
IO.puts("#{Mix.Project.deps_path()}")
