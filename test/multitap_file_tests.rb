# frozen_string_literal: true

require "stringio"
require "tmpdir"
ShareableConstants.require_file(VBlank.root.join("examples/wanderers").to_s)

# A cartridge opened as a file has no program to say whether it reads an adapter for more
# controllers in the second port, so a test says so: `multitap: true` plugs one in, and a tape's
# third and fourth players reach its plugs. Without it, the second port has a plain controller, and
# the third and fourth players hold nothing.
#
# The cartridge is examples/wanderers.rb built for the console a class names (+cartridge_console+)
# and written to a file. Each of its four players walks a different way for a few frames, and
# stands still after.
module MultitapFileTests
  # Frames for the game to start, frames with the four walking, and frames standing still, so the
  # sprites are drawn where the last step put them.
  START_FRAMES = 30
  WALK_FRAMES = 8
  STILL_FRAMES = 6

  # Each player's way, and the step it makes from where that player starts.
  WAYS = Ractor.make_shareable({ 1 => [:right, [1, 0]], 2 => [:p2_left, [-1, 0]],
                                 3 => [:p3_up, [0, -1]], 4 => [:p4_down, [0, 1]] })

  TAPE = Ractor.make_shareable(<<~TAPE)
    vblank tape 1
    recorded on: WANDERERS 0x00000000
    starts from: power-on

    #{START_FRAMES} -
    #{WALK_FRAMES} #{WAYS.values.map(&:first).join(' ')}
    #{STILL_FRAMES} -
  TAPE

  private def with_cartridge_file
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "wanderers#{VBlank::Console.described(cartridge_console).extension}")
      Wanderers.build_rom(console: cartridge_console, out: StringIO.new, err: StringIO.new, profile: false).write(path)
      yield path
    end
  end

  private def layout
    width, height = VBlank::Console.described(cartridge_console).screen_size
    Wanderers::Layout.new(width: width, height: height)
  end

  # Where +player+ starts, and where they stand after walking.
  private def start_of(player) = layout.starts.fetch(player - 1)

  private def walked_to(player)
    x, y = start_of(player)
    dx, dy = WAYS.fetch(player).last
    [x + (dx * WALK_FRAMES), y + (dy * WALK_FRAMES)]
  end

  # Whether the middle of a walker's head, at +place+ its top left, is in one of the walkers' colours.
  private def walker_at?(reader, place)
    x, y = place
    Wanderers::COLORS.any? { |color| reader.pixel_is?(x + 3, y + 3, color) }
  end

  private def walk(probe)
    probe.step(START_FRAMES)
    probe.step(WALK_FRAMES, holding: WAYS.values.map(&:first))
    probe.step(STILL_FRAMES)
  end

  def test_with_a_multitap_all_four_players_walk_on_a_cartridge_file
    with_cartridge_file do |path|
      VBlank::Playthroughs::Probe.open(path, multitap: true) do |probe|
        walk(probe)
        (1..4).each do |player|
          assert walker_at?(probe.reader, walked_to(player)), "player #{player} walked to #{walked_to(player).inspect}"
          refute walker_at?(probe.reader, start_of(player)), "player #{player} left #{start_of(player).inspect}"
        end
      end
    end
  end

  def test_without_a_multitap_the_third_and_fourth_players_do_not_walk
    with_cartridge_file do |path|
      VBlank::Playthroughs::Probe.open(path) do |probe|
        walk(probe)
        assert walker_at?(probe.reader, walked_to(2)), "the second port's own controller is the second player"
        [3, 4].each { |player| refute walker_at?(probe.reader, walked_to(player)), "player #{player} is not there" }
      end
    end
  end
end

# The same file, compared with itself on a tape, for a console whose cartridges a comparison plays
# (Console::Kit#compared_side_by_side?).
module MultitapFileComparisonTests
  include MultitapFileTests

  # A tape played on the file with an adapter in, compared with itself, and with the file with
  # none: the third and fourth players' presses are the only difference the second finds.
  def test_a_tape_compares_the_file_with_a_multitap_against_itself
    tape = VBlank::Playthroughs::Tape.parse(TAPE)
    with_cartridge_file do |path|
      tapped = -> { VBlank::Diagnostics::CartridgeFile.new(path, multitap: true) }

      refute tape.compare(tapped.call, tapped.call).drift?, "the same file with an adapter in plays alike"
      assert tape.compare(tapped.call, VBlank::Diagnostics::CartridgeFile.new(path)).drift?,
             "with no adapter, players 3 and 4 stay put"
    end
  end
end
