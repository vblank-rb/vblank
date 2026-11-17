# frozen_string_literal: true

require "stringio"

# WORK THAT ENDS WHERE A TEST ASKS, on the PlayStation: a game whose every pass calls one routine that
# goes round `repeat(turns) { total += 3 }`, and the turns that make its pass end a given number of the
# picture's lines past the blank its pass began before. A pass that runs over a frame, ends a few lines
# late, or runs into a third frame is what the profile's and the checked run's tests are about.
#
# THE TURNS ARE MEASURED, NOT WRITTEN DOWN. How many cycles a turn takes is the lowering's, and it gets
# quicker (a count held in a register cut a turn from 10.4 cycles to 8.7), so a count written in a test
# stops ending where it meant to and the test fails for a reason of its own. The pass's end is read off
# two calibrating games, a few frames each, played in Beetle PSX through the profile, and the turns are
# worked out from where they ended: the end moves on in proportion to the turns. A pass's work beyond
# the loop (calling the routine, the frame's interrupt) is in both games, so it is counted.
module PS1PassWork
  FRAME_LINES = VBlank::Diagnostics::PS1Profiler::FRAME_LINES

  # The turns of the two calibrating games: each well inside one frame, far enough apart to read a
  # line's worth of turns from.
  CALIBRATING_TURNS = [3_000, 30_000].freeze

  # Frames each game is profiled for, after the profile's own settling.
  FRAMES_PROFILED = 4

  # The game, its routine named +routine+.
  def self.game(turns, routine: :work)
    VBlank.game("WORK #{turns}", consoles: %i[ps1]) do
      total = 0
      func(routine) { repeat(turns) { total += 3 } }
      game_loop { call routine }
    end
  end

  # Where the passes of the game of +turns+ end, the earliest and the latest, in the picture's lines
  # from the blank before each began: below nought while a pass fits its frame (the lines it left to
  # spare), the lines past that blank once it runs into a second frame, and a frame's lines more for
  # each frame after. Passes of the same work end a little apart, since the frame's interrupt does not
  # fall on the same turn of each.
  def self.lines_ended(turns)
    result = game(turns).build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
                        .profile(out: StringIO.new, frames: FRAMES_PROFILED)
    return [-result.fewest_lines_spare_unrounded] * 2 if result.lines_past_blank.empty?

    ended = result.lines_past_blank.flat_map { |frames, lines| lines.map { |past| ((frames - 2) * FRAME_LINES) + past } }
    ended.minmax
  end

  # The most tries #turns_ending_within makes after the calibrating games.
  MOST_TRIES = 8

  # Turns whose every pass ends within +lines+ (a Range) past the blank before it began
  # (#lines_ended). Worked out once a process for each range (each Ractor keeps its own), since
  # several tests ask for the same one and each try is a game played in the emulator.
  def self.turns_ending_within(lines)
    found = (Ractor.current[:ps1_pass_work_turns] ||= {})
    found[lines] ||= turns_found_ending_within(lines)
  end

  # The search, aimed at the range's middle: from the two calibrating games, each next try drawn
  # through the last two played. The end does not move on evenly across a frame's end, where the
  # blank's lines go by and the next frame's interrupt runs inside the pass, so one line through the
  # calibrating games alone misses a pass of more than a frame by tens of lines.
  def self.turns_found_ending_within(lines)
    aim = (lines.begin + lines.end) / 2.0
    tried = CALIBRATING_TURNS.map { |turns| [turns, middle(lines_ended(turns))] }
    MOST_TRIES.times do
      (fewer, at_fewer), (more, at_more) = tried.last(2)
      turns = (fewer + ((aim - at_fewer) * (more - fewer) / (at_more - at_fewer))).round
      earliest, latest = lines_ended(turns)
      return turns if lines.cover?(earliest) && lines.cover?(latest)

      tried << [turns, middle([earliest, latest])]
    end
    raise "no number of turns ended every pass #{lines} lines past the blank: tried #{tried.inspect}"
  end

  def self.middle(ends) = ends.sum / 2.0
  private_class_method :middle, :turns_found_ending_within
end
