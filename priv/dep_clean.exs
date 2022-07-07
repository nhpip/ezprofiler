 
if Path.dirname(File.cwd!()) == Mix.Project.deps_path(), 
    do: File.rm_rf!("#{Mix.Project.build_path()}/lib/ezprofiler/")
