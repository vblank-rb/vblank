# frozen_string_literal: true

# Ruby's warnings turned on as a test run starts, in place of `ruby -w` (TestTask loads this with
# ruby -r ahead of the test files, which Ruby warns about as it reads them). The two warn alike,
# deprecations included, but `-w` is also read as Ruby boots, and a booting Ruby told -w prints
# every RUBY_GC_ setting in its environment, a line each: a block of them at the top of every run
# that is handed RactorSettings' roomy heap (Lowering::Run#roomy_heap). Turned on here, after the boot,
# nothing is printed.
$VERBOSE = true
Warning[:deprecated] = true
