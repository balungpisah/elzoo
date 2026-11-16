ExUnit.start(autorun: false)

test_files = Path.wildcard(Path.join(__DIR__, "test/*_test.exs")) |> Enum.sort()
if test_files == [], do: raise("command-store-fit has no test files")
Enum.each(test_files, &Code.require_file/1)

case ExUnit.run() do
  %{failures: 0} -> :ok
  _ -> System.halt(1)
end
