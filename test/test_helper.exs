Application.put_env(:breeze, :example_mode, :load_only)
Code.require_file(Path.expand("../examples/minesweeper.exs", __DIR__))

ExUnit.start()
