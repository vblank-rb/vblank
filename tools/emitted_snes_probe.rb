# frozen_string_literal: true

# The child half of the Super Nintendo's numbers in `rake emitted:check` (see tools/emitted_baseline.rb):
# build one example's Super Nintendo cartridge and print what it holds, as a line of JSON.
#
#   ruby tools/emitted_snes_probe.rb <lib root> <repo root> <example.rb>
#
# It runs in a process of its own as tools/emitted_probe.rb does, for the same reasons.
#
# Two numbers, both in bytes, as the Genesis's are (tools/emitted_genesis_probe.rb): +code+ is what
# the processor runs (the runtime and the game's routines) and +data+ is what it only reads or sends
# on (the game's tables, pictures, songs and recordings, and the sound unit's program). The 65816's
# instructions are of many sizes, so code is counted in bytes, not instructions. Each is what the
# build's own bookkeeping says its sections come to (SNES::Places#bytes). The cartridge's banks are
# not counted: they are whole banks, and a section that grows inside one would not show.

lib_root, repo_root, example = ARGV
abort "usage: emitted_snes_probe.rb <lib root> <repo root> <example.rb>" unless example

$LOAD_PATH.unshift File.expand_path(lib_root)
require "vblank"
require "json"
require "stringio"

# As in tools/emitted_probe.rb: an example's own require must not load another copy.
working_tree_entry = File.join(repo_root, "lib", "vblank.rb")
$LOADED_FEATURES << File.realpath(working_tree_entry) if File.exist?(working_tree_entry)

report = { name: File.basename(example, ".rb") }

begin
  real_stdout = $stdout
  $stdout = StringIO.new

  known = VBlank.registered_games.size
  load File.expand_path(example)
  game = VBlank.registered_games[known..].last
  raise "no VBlank.game was declared" unless game

  rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
  report[:title] = game.title
  report[:code] = rom.built.bytes.fetch(:code)
  report[:data] = rom.built.bytes.fetch(:data)
rescue StandardError, ScriptError => e
  report[:error] = "#{e.class}: #{e.message.lines.first.to_s.strip}"
ensure
  $stdout = real_stdout
end

puts JSON.generate(report)
