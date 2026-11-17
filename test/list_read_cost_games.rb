# frozen_string_literal: true

require "stringio"

# WHAT A LIST READ AT A WORKED-OUT INDEX COSTS, for each console's own cost test: four lists of 32,
# each always full, read once a pass each into a variable (`x = row[i]`), against the same game
# reading none. The index is a variable the game sets (:variable), a number masked to the list's
# length (:mask, `row[(t + 3) & 31]`), or a loop's count (:count, `repeat(8) { |n| x = row[n] }`, so
# 32 reads a pass). A read the index is known to stay inside needs no test that it is, as the
# console's own games read a field of a record they hold the address of with one load; a read at a
# variable keeps the test, since the interpreter stops the game on an index outside the list.
#
# The lists are made first, before the screen, so every console counts them as always full.
module ListReadCostGames
  # The ways the index is written, and how many reads a pass each makes.
  READS_A_PASS = { variable: 4, mask: 4, count: 32 }.freeze

  # The game for +console+, its lists as wide as +width+, reading at +index+ or, with +reads+ false,
  # setting the same indexes and reading nothing.
  def self.game(console, index, width: :byte, reads: true)
    VBlank.game("LIST READ #{index} #{width} #{reads}", consoles: [console]) do
      a = list :a, capacity: 32, width: width, full_of: 1
      b = list :b, capacity: 32, width: width, full_of: 2
      c = list :c, capacity: 32, width: width, full_of: 3
      d = list :d, capacity: 32, width: width, full_of: 4
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      t = 0
      x = 0
      kept = 0
      i = 0
      j = 0
      k = 0
      m = 0
      game_loop do
        t = (t + 1) & 31
        i = t
        j = (t + 3) & 31
        k = (t + 5) & 31
        m = (t + 7) & 31
        if reads && index == :variable
          x = a[i]
          x = b[j]
          x = c[k]
          x = d[m]
        elsif reads && index == :mask
          x = a[(t + 1) & 31]
          x = b[(t + 3) & 31]
          x = c[(t + 5) & 31]
          x = d[(t + 7) & 31]
        elsif index == :count
          repeat(8) do |n|
            if reads
              x = a[n]
              x = b[n]
              x = c[n]
              x = d[n]
            end
            kept += 1
          end
        end
        kept = x
      end
    end
  end

  # The share of a frame +console+ spends awake running +game+.
  def self.awake_share(console, game)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  # What one read at +index+ costs on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_read(console, index, frame_cycles, width: :byte)
    reading = awake_share(console, game(console, index, width: width))
    not_reading = awake_share(console, game(console, index, width: width, reads: false))
    (reading - not_reading) * frame_cycles / READS_A_PASS.fetch(index)
  end
end
