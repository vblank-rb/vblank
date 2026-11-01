# frozen_string_literal: true

# The child half of the Color's numbers in `rake emitted:check` (see tools/emitted_baseline.rb):
# build ONE example's Game Boy Color cartridge and print what it holds, as a line of JSON.
#
#   ruby tools/emitted_color_probe.rb <lib root> <repo root> <example.rb>
#
# It runs in a process of its own as tools/emitted_probe.rb does, for the same reasons.
#
# TWO NUMBERS, because a Color cartridge has two kinds of room. +code+ is the part always in view,
# 16384 bytes that everything short of the banks must share, and a game that runs out of it does
# not build. +data+ is what the banks hold. Each is read off the finished cartridge: a bank is
# filled from its start and the rest left at 0xFF, so its last byte that is not 0xFF is how far it
# got, which the build's own bookkeeping need not be asked.

lib_root, repo_root, example = ARGV
abort "usage: emitted_color_probe.rb <lib root> <repo root> <example.rb>" unless example

$LOAD_PATH.unshift File.expand_path(lib_root)
require "vblank"
require "json"
require "stringio"

# As in tools/emitted_probe.rb: an example's own require must not load another copy.
working_tree_entry = File.join(repo_root, "lib", "vblank.rb")
$LOADED_FEATURES << File.realpath(working_tree_entry) if File.exist?(working_tree_entry)

BANK_BYTES = 0x4000

# How far +bank+ is filled: past its last byte that is not the fill.
def bytes_used(bank)
  bank.bytesize.downto(1) { |used| return used if bank.getbyte(used - 1) != 0xFF }
  0
end

report = { name: File.basename(example, ".rb") }

begin
  real_stdout = $stdout
  $stdout = StringIO.new

  known = VBlank.registered_games.size
  load File.expand_path(example)
  game = VBlank.registered_games[known..].last
  raise "no VBlank.game was declared" unless game

  rom = game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
  banks = rom.bytes.b.scan(/.{1,#{BANK_BYTES}}/mn)
  report[:title] = game.title
  report[:code] = bytes_used(banks.first)
  report[:data] = banks.drop(1).sum { |bank| bytes_used(bank) }
rescue StandardError, ScriptError => e
  report[:error] = "#{e.class}: #{e.message.lines.first.to_s.strip}"
ensure
  $stdout = real_stdout
end

puts JSON.generate(report)
