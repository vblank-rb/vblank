# frozen_string_literal: true

require "stringio"

# What asking for a save costs, for each console's own cost test. Asking copies what the record keeps
# into a buffer of the record's own there and then (Builder::SaveJobs, "the save holds the moment it
# was asked for"), so a record keeping a list of a few hundred bytes copies them on the pass the save
# is asked on. Here the game asks once, a little after power-on, and the console is measured over a
# stretch of frames holding the ask and every pass that writes the save after it. The same game with
# the list empty does the same work but for copying the list's items: the stage holds nought either
# way, so the writing passes write the same bytes. What the list costs is the cycles the one was awake
# over the stretch less the other's.
module SaveSnapshotCostGames
  # The list's words: 256 bytes.
  ITEMS = 64

  # The pass the save is asked on, after the frames settled (settle) in which the game starts.
  ASK_PASS = 20
  SETTLE = 15

  # The frames measured: the ask and every pass of the save after it, on the slowest console.
  FRAMES = 150

  # The game for +console+, the record keeping a number and a list of items words, full of nought,
  # or with +full+ false empty.
  def self.game(console, full:)
    VBlank.game("SNAPSHOT COST", consoles: [console]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(18) { "#" * 20 }
      hearts = var :hearts, 3
      flags = list :flags, capacity: SaveSnapshotCostGames::ITEMS, width: :word, full_of: full ? 0 : nil
      files = save_data(:file) { keep hearts, flags }
      pass = var :pass, 0
      game_loop do
        pass.increase! 1
        files[0].save if pass == SaveSnapshotCostGames::ASK_PASS
      end
    end
  end

  # How many cycles +game+ is awake over the frames measured on +console+, whose frame is
  # +frame_cycles+.
  def self.awake(console, game, frame_cycles)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    profile = rom.profile(out: StringIO.new, settle: SETTLE, frames: FRAMES)
    (1 - profile.idle_share) * profile.frames * frame_cycles
  end

  # What the list's items words cost the ask on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_snapshot(console, frame_cycles)
    awake(console, game(console, full: true), frame_cycles) - awake(console, game(console, full: false), frame_cycles)
  end
end
