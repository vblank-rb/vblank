# frozen_string_literal: true

# The child half of the PlayStation's numbers in `rake emitted:check` (see tools/emitted_baseline.rb):
# build one example's PlayStation program and print what it holds, as a line of JSON.
#
#   ruby tools/emitted_ps1_probe.rb <lib root> <repo root> <example.rb>
#
# It runs in a process of its own as tools/emitted_probe.rb does, for the same reasons.
#
# Two numbers, both in bytes, as the Genesis's and the Super Nintendo's are: +code+ is what the
# processor runs (the runtime and the game's routines) and +data+ is what it only reads (the game's
# tables, pictures, songs and recordings). The R3000's instructions are all one word, but its data
# sits in the same sections' run of RAM, so both are counted in bytes. Each is what the build's own
# bookkeeping says its sections come to (PS1::ByteCounts). The PS-X EXE's file is not counted: it is
# padded to whole sectors of 2048 bytes, and a section that grows inside one would not show.

lib_root, repo_root, example = ARGV
abort "usage: emitted_ps1_probe.rb <lib root> <repo root> <example.rb>" unless example

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

  rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
  report[:title] = game.title
  report[:code] = rom.built.bytes.code
  report[:data] = rom.built.bytes.data
rescue StandardError, ScriptError => e
  report[:error] = "#{e.class}: #{e.message.lines.first.to_s.strip}"
ensure
  $stdout = real_stdout
end

puts JSON.generate(report)
