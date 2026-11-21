# frozen_string_literal: true

require "test_helper"

require "stringio"
require "prism"
require "conformance_fixture"
require "ractor_workers"

# Can a game call this library from a Ractor?
#
# A Ractor is Ruby's way of running two pieces of Ruby at the same time on two cores, which
# threads cannot do. The price is isolation: a worker may not reach anything mutable that
# another worker can also see. So a library is callable from one only if what it hands out is
# frozen all the way down — a frozen Hash of unfrozen Strings is still refused, and
# `Ractor.shareable?` is the only thing that answers the real question. `frozen?` does not.
#
# Why the library cares: a game that builds several cartridges at once — the Wolfenstein port
# does — wants to do it inside one process rather than forking one interpreter per build.
#
# The rule is narrower than it is usually quoted, and the difference decides what these tests
# ask. It is not "a worker cannot touch state kept on a class or module". A worker may read
# one. What it may not do is get an unshareable value out of one, or write one at all. So a
# table built while the file loads and frozen is legal to read from a worker and needs no
# redesign; only a mutable value, or a write that happens after the workers exist, is fatal.
#
# These are censuses, not examples. Each walks everything the library defines and names
# whatever is new, rather than checking the constants somebody once wrote down. That is the
# difference that matters here: the count grew between the day it was first taken and the day
# it was fixed, and a test naming the ones it knew about would have passed through both.
class TestRactorSafety < Minitest::Test
  include RactorWorkers

  # How many builds race each other, and how many times over. Eight is more than the cores
  # most machines have, which is the point — workers waiting to be let on a core interleave
  # differently each round, and a shared thing being written wants that to find it.
  AT_ONCE = 8
  ROUNDS = 3

  # The program the cross-backend tests already run, written to touch every kind of thing a
  # program can hold. In a module, like the small game below, because a Ractor's block runs
  # with a self of its own and cannot see a test's methods.
  module Everything
    module_function

    def cartridge = VBlank::IR::Backends::GBA.new.lower(ConformanceFixture.program)

    # The picture it draws on the fake console — what it shows rather than what it stored,
    # since a fade or the camera changes the picture without touching a drawn pixel.
    def picture
      VBlank::IR::Backends::Reference.new.run(ConformanceFixture.program, frames: 2).screen.shown
    end
  end

  # The program the two builds share. It lives in a module rather than in a test method
  # because a Ractor's block runs with a self of its own — a test's instance methods are
  # not reachable from inside one, but a constant is.
  module OneSmallGame
    module_function

    # A spread rather than a minimal program: a variable, a comparison, a fill, text in a
    # font that ships, and a font the program declares for itself. Each was somewhere the
    # library used to stop, and the declared font was the last of them.
    def cartridge
      VBlank.build("RACTOR", console: :gba, out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        clear_screen :blue
        font(:mine) { glyph "A", "###\n#.#\n###" }
        x = var :x, 0
        game_loop do
          x += 1
          fill_rect 10, 10, 20, 20, :red
          draw_text "HELLO", :center, 100, :white
          draw_text "A", 10, 120, :white, font: :mine
          halt if x >= 3
        end
      end.buffer
    end
  end

  # A Super Nintendo cartridge that plays a song: one recorded instrument and a score of one note.
  # The sound unit's program is written by an assembler of its own (SNES::SPC700), whose tables a
  # worker first met here, so it is the build that proves those tables can be read from one.
  module SuperNintendoSong
    module_function

    def cartridge
      VBlank.build("SONG", console: :snes, out: StringIO.new, err: StringIO.new) do
        enable_sound
        instrument :hum, pcm: [0, 64, 0, -64] * 100, rate: 22_050
        score = VBlank::Audio::Score
        # A second note that glides from the first, then changes loudness, as Wolfenstein's
        # converted songs do: it reaches the voice tables a plain note does not.
        notes = [score::Note.new(at: 0, hz: 440), score::Note.new(at: 24, hz: 494, glides: true, volume: 8)]
        music = songs :music, [score.new(parts: [score::Part.new(plays: :hum, notes: notes)], length: 96)]
        game_loop { music.play 0 }
      end.bytes
    end
  end

  # The one a worker never reaches, and it is not a tidy-up somebody has been putting off.
  # Both censuses skip it; the build at the bottom does not, so if a worker ever did reach it
  # it would raise there rather than pass quietly.
  #
  #   @registered_games   a declared game keeps the author's own block so it can be built
  #                       later, and a block carries the surroundings it was written in —
  #                       which is the one thing a Ractor may never share. Declaring a game
  #                       is a top-level act in a script; what a worker does is build one.
  MAIN_RACTOR_ONLY = %i[@registered_games].freeze

  # The same question asked of the source rather than of the loaded library, which is the only
  # way to see a cache nothing has built yet.
  #
  # What it looks for is `||=` on something kept by a class or module — which is exactly how
  # "work it out the first time somebody asks" is spelled, and is the shape that breaks. A
  # plain assignment in a method whose job is to change the registry is a different thing: a
  # game registering a font or a pack is configuring the library, which happens on the main
  # Ractor, and a worker only ever reads what it left. So this is narrow on purpose.
  #
  # It is parsed rather than searched for, because what decides it is whether the write
  # happens with a class or module as self — inside a `def self.x`, or under `class << self`.
  def test_the_library_never_works_a_cache_out_the_first_time_somebody_asks
    sources = Dir[VBlank.root.join("lib/**/*.rb").to_s].sort
    refute_empty sources, "the library should be where this test looks for it"
    offenders = sources.flat_map { |path| lazy_module_caches(path) }

    assert_empty offenders, <<~WHY
      These lines work something out the first time somebody asks and keep it on a class or
      module:

      #{list(offenders)}

      Whichever Ractor asked first would be the one writing it, and a worker may not write to
      a module at all, whatever the value. Build it while the file loads instead.
    WHY
  end

  # The one that actually proves it. The two censuses above are about what the library
  # holds; this one builds a whole cartridge inside a worker and compares it byte for byte
  # with the same build on the main Ractor. Anything still unreachable raises rather than
  # coming back wrong, so a failure here names the thing that stopped.
  def test_a_whole_cartridge_builds_inside_a_worker_and_comes_out_the_same
    on_main = OneSmallGame.cartridge
    in_worker = without_the_experimental_warning { Ractor.new { OneSmallGame.cartridge }.value }

    assert_equal on_main, in_worker,
                 "the same program built on two Ractors must produce the same cartridge"
  end

  # The same, over a program that uses everything. The cartridge above is six verbs, chosen
  # to cross the places the library used to stop. This one is the fixture the cross-backend
  # tests already run, written to touch every kind of thing a program can hold — so a
  # feature that quietly needs something shared is caught here rather than whenever somebody
  # next happens to use it.
  def test_the_program_that_uses_everything_builds_the_same_in_a_worker
    on_main = Everything.cartridge
    in_worker = without_the_experimental_warning { Ractor.new { Everything.cartridge }.value }

    assert_equal on_main, in_worker
  end

  # Another console's build, which is a body of code of its own: every console's lowering has its
  # own assemblers and tables, and the Advance's cartridge above crosses none of them.
  def test_a_super_nintendo_cartridge_with_a_song_builds_the_same_in_a_worker
    on_main = SuperNintendoSong.cartridge
    in_worker = without_the_experimental_warning { Ractor.new { SuperNintendoSong.cartridge }.value }

    assert_equal on_main, in_worker
  end

  # The other way of running a game. Turning a program into cartridge bytes is one; playing
  # it on the fake console the tests measure against is a different body of code, and until
  # now nothing had asked whether that one works off the main Ractor either.
  def test_the_program_that_uses_everything_plays_the_same_in_a_worker
    on_main = Everything.picture
    in_worker = without_the_experimental_warning { Ractor.new { Everything.picture }.value }

    assert_equal on_main, in_worker, "the same program played on two Ractors must draw the same picture"
  end

  # The one that finds what the others cannot, and it is worth saying why it is separate.
  # Every test above runs one build at a time, so it can only find something a build reads
  # that it should not. Something a build CHANGES — a counter, a scratch buffer, a running
  # total — is invisible while there is nobody to collide with: one build trips over it only
  # when a second is in the same place at the same moment. It also catches a build that is
  # not reproducible, which is the same failure from the reader's side.
  #
  # So: build the same program in eight workers at once, several times over, and hold every
  # one of them against the answer built quietly on its own. Something shared being written
  # shows up as a cartridge that is subtly wrong rather than as anything raising.
  def test_eight_builds_at_once_all_agree_with_one_built_alone
    alone = Everything.cartridge

    without_the_experimental_warning do
      ROUNDS.times do
        together = Array.new(AT_ONCE) { Ractor.new { Everything.cartridge } }.map(&:value)
        disagreed = together.count { |one| one != alone }

        assert_equal 0, disagreed,
                     "#{disagreed} of #{AT_ONCE} builds run together disagreed with the one run alone"
      end
    end
  end

  private def lazy_module_caches(path)
    finder = LazyModuleCaches.new(path.delete_prefix("#{VBlank.root}/"))
    Prism.parse_file(path).value.accept(finder)
    finder.found.reject { |_where, name| MAIN_RACTOR_ONLY.include?(name) }
  end

  private def list(offenders) = offenders.map { |what, kind| "  #{what}  (#{kind})" }.join("\n")

  # Somewhere a class or module works a value out the first time it is asked for and keeps it.
  class LazyModuleCaches < Prism::Visitor
    attr_reader :found

    def initialize(path)
      super()
      @path = path
      @found = []
      @singleton = 0 # how deep inside `def self.x` / `class << self` we are
      @module_function = false
    end

    def visit_def_node(node)
      was = @singleton
      @singleton += 1 if node.receiver || @module_function
      super
      @singleton = was
    end

    def visit_singleton_class_node(node)
      @singleton += 1
      super
      @singleton -= 1
    end

    # `module_function` and `extend self` turn the plain `def`s that follow them into
    # methods on the module, so those count too. Each applies to one module body, so the
    # flag is put back on the way out of a nested one.
    def visit_call_node(node)
      @module_function = true if module_level_from_here?(node)
      super
    end

    def visit_module_node(node) = in_a_fresh_body { super }
    def visit_class_node(node) = in_a_fresh_body { super }

    private def in_a_fresh_body
      was = @module_function
      @module_function = false
      yield
      @module_function = was
      nil
    end

    private def module_level_from_here?(node)
      return true if node.name == :module_function && node.arguments.nil?

      node.name == :extend && node.arguments&.arguments&.first.is_a?(Prism::SelfNode)
    end

    def visit_instance_variable_or_write_node(node) = record(node)
    def visit_instance_variable_operator_write_node(node) = record(node)

    private def record(node)
      @found << ["#{@path}:#{node.location.start_line}", node.name] if @singleton.positive?
      nil
    end
  end
end
