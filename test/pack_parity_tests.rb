# frozen_string_literal: true

require "tmpdir"
require "pack_games"

# EVERY REGISTERED PACK GAME (PackGames, test/pack_games.rb) BUILT BOTH WAYS AND HELD TO ONE
# ANSWER: built with its pack left out and handed the pack file its all-in-one build made, it shows
# and sounds what the all-in-one build does on every pass, or the build refuses in plain words
# that name the fix. A game that names frames of its original is handed instead the file its
# pack's unpacking writes from the copy, held byte for byte to the all-in-one one (#pack_file_handed).
# There is a test for each game, all one body (#assert_registered_game_parity).
#
# Only a build for a computer leaves its pack out, and nothing hands a cartridge a file. So this is
# played by each run whose player reads a file as it starts: the interpreter
# (test/interpreter/vblank/builder/test_pack_parity_interpreter.rb) and the game as C, JavaScript
# and Ruby (test/lowering/{native,js,ruby}/vblank/ir/backends/*/test_*_pack_parity.rb), each
# checked against the interpreter on every frame as every game is.
#
# A lowering's file also says how its build is written out (#written_out), and each game's build
# with its pack left out is then searched for the numbers the pack file puts into it
# (#assert_written_without_the_packs_numbers).
module PackParityTests
  include VBlank::Testing::PackParity

  ValidationError = VBlank::IR::Guardrails::ValidationError

  # How long a run of numbers the search looks for is, and how many different numbers it must
  # hold: a shorter or plainer run (a row of one colour, a count from nought) is in any program.
  NEEDLE_LENGTH = 12
  NEEDLE_VARIETY = 4
  # The runs taken from one table or picture: its start, its middle and its end.
  NEEDLES_EACH = 3

  # The games whose all-in-one builds the search is shown to find the pack's numbers in: a
  # picture of tiles, a picture of pixels and a recording. A background and a list of colours are
  # not among them: an all-in-one build keeps them another way than a filled program does (a tile
  # for each the map names, where the filled one has a tile for each cell), so their runs differ.
  # PackBackgroundAtStartTests and PackColorListAtStartTests search for those as an all-in-one
  # build keeps them.
  SEARCHED = %i[sprite_of_pack_tiles picture_of_pack_pixels recordings_of_pack_samples].freeze

  # Written out as plain methods, not made from a block, so a test in a Ractor can call them.
  PackGames::ALL.each do |game|
    module_eval("def test_#{game.name}_built_with_its_pack_left_out_is_its_all_in_one_build_or_refused = " \
                "assert_registered_game_parity(:#{game.name})", __FILE__, __LINE__ - 1)
  end

  # The program as this run's lowering writes it out (C, JavaScript or Ruby), or nil on a run that
  # writes none out: the interpreter's.
  private def written_out(_program) = nil

  private def assert_registered_game_parity(name)
    game = PackGames.named(name)
    kit = game.kit.new
    Dir.mktmpdir do |folder|
      whole = kit.build(game, folder, PackGames::ALL_IN_ONE)
      left_out = nil
      refusal = refusal_of(game) { left_out = kit.build(game, folder, PackGames::LEFT_OUT) }
      next assert_registered_refusal(game, refusal) if refusal

      wanted = played_unless_console_refuses(whole.program, nil, game)
      next assert_console_refuses_left_out(game, left_out.program, whole.pack_file) unless wanted

      file = pack_file_handed(game, whole, left_out)
      handed = nil
      refusal = refusal_of(game) { handed = played(left_out.program, file, game) }
      next assert_registered_refusal(game, refusal) if refusal

      assert_registered_as_built(game)
      assert wanted.shows_or_sounds?, "#{game.name}: the all-in-one build shows a black screen and makes no sound in " \
                                      "#{game.passes} passes, so there is nothing to compare. Make the game draw or sound."
      assert_alike_or_registered_difference(game, VBlank::Testing::PackParity.difference(wanted, handed))
      assert_written_without_the_packs_numbers(game, left_out.program, whole.pack_file)
    end
  end

  # THE PACK FILE THE BUILD WITH ITS PACK LEFT OUT IS HANDED. Where the game names frames of its
  # original's, that is the file its pack's unpacking writes from the copy, played on this run's
  # player, as a shell makes it on the player's machine: the unpacking reads each frame through its
  # layout as game code (Original::FrameRewrite), a reader the game wrote among it, while the
  # all-in-one build read the same frames with numbers. The two files must be the same, byte for
  # byte. Elsewhere it is the all-in-one build's file: an unpacking of slots copied as they are
  # reads no layout, and playing one for every game would cost the run a build of each.
  private def pack_file_handed(game, whole, left_out)
    return whole.pack_file unless names_frames?(whole.pack_file)

    refute_nil left_out.data_pack, "#{game.name} names frames of its original, and its line in test/pack_games.rb gives back " \
                                   "its program alone. Give back built_by(builder), so that its pack's unpacking is played."
    unpacked = unpacked_pack_file(game, left_out.data_pack)
    assert_nil first_byte_apart(whole.pack_file, unpacked),
               "#{game.name}: the pack file its unpacking writes from the copy is not the all-in-one build's. " \
               "#{first_byte_apart(whole.pack_file, unpacked)}"
    unpacked
  end

  # How long an unpacking may play: the largest registered copy's tiles take a few dozen frames.
  UNPACKING_FRAMES = 400

  # PLAYED AS A SHELL PLAYS IT: as the game's console, and not held to that console's memory.
  #
  # A real shell builds the unpacking for the console the game is built for, with
  # `for_computer: true` (Builder::DataPacks#unpacking_options), so its screen, clock and frame are
  # that console's. But no shell runs the build's guardrails on it. Original::Shell.build checks
  # only the game, through Cartridge::Game#checked_program; each unpacking comes straight from
  # DSL::DataPack#unpacking. Then each shell lowers it unchecked: the Ruby one plays it in
  # Live::BackgroundUnpacking from Backends::Ruby#live_source, the C one compiles it as a part of
  # its own (Backends::Native#build_desktop_shell), and the web page runs only
  # JS#refuse_console_only_steps! on it, which asks for no memory. An all-in-one build plays it as
  # Ruby (Original::Unpacking#run_as_ruby), unchecked too. So a Color port whose pack is bigger than
  # the Color's work memory unpacks for a player: the unpacking runs only on a computer, never in a
  # cartridge's memory.
  #
  # A checked run's player holds each game it plays to the build's guardrails for the run's
  # console, and plays an unpacking without them, as a shell does (Testing::BuildChecks).
  private def unpacked_pack_file(game, data_pack)
    copy = data_pack.original.copy
    unpacking = data_pack.unpacking(release: data_pack.original.releases.with_sha1(copy.sha1))
    played = game_player.hand_file(File.binread(copy.path)).run(unpacking.program, frames: UNPACKING_FRAMES)
    assert unpacking.finished_in?(played), "#{game.name}: its pack's unpacking did not finish in #{UNPACKING_FRAMES} frames"
    assert_nil unpacking.fault_in(played), "#{game.name}: its pack's unpacking went wrong"
    unpacking.pack_file_in(played, sha1: copy.sha1, build_version: data_pack.build_version)
  end

  private def names_frames?(pack_file) = !pack_file.nil? && !VBlank::Original::Pack.from_bytes(pack_file).frame_records.empty?

  # Where +one+ and +other+ first differ, in words, or nil where they are the same bytes.
  private def first_byte_apart(one, other)
    return if one == other

    at = (0...[one.bytesize, other.bytesize].min).find { |place| one.getbyte(place) != other.getbyte(place) }
    return "The all-in-one file is #{one.bytesize} bytes and the unpacked one #{other.bytesize}." unless at

    format("They differ first at byte %<at>d: 0x%<one>02X all-in-one and 0x%<other>02X unpacked.",
           at: at, one: one.getbyte(at), other: other.getbyte(at))
  end

  private def played(program, file, game)
    player = file ? game_player.hand_file(file) : game_player
    VBlank::Testing::PackParity.played(player, program, game.passes, game.presses)
  end

  # The all-in-one build's run, or nil where this run's console refuses the game as any build of
  # it for that console is refused (Testing::BuildChecks): a game of something the console lacks.
  private def played_unless_console_refuses(program, file, game)
    played(program, file, game)
  rescue ValidationError
    nil
  end

  # A game this run's console refuses all-in-one is refused built with its pack left out too.
  private def assert_console_refuses_left_out(game, program, file)
    assert_raises(ValidationError, "#{game.name}: this console's build refuses the all-in-one game, and plays it with " \
                                   "its pack left out") { played(program, file, game) }
  end

  # The refusal the block raises: the stated one (PackParity#pack_at_start_refusal), or, for a game
  # registered as refused in words that do not name the fix yet, that refusal by its phrase. Any
  # other error is raised on.
  private def refusal_of(game, &)
    pack_at_start_refusal(&)
  rescue ArgumentError, VBlank::BuildError => e
    raise unless game.refused && !game.refused.names_fix && e.message.include?(game.refused.phrase)

    e
  end

  private def assert_registered_refusal(game, refusal)
    assert game.refused, "#{game.name} is refused in a build with its pack left out, and it is not registered as refused " \
                         "(test/pack_games.rb). The refusal: #{refusal.message}"
    assert refused_on_this_run?(game.refused), "#{game.name} is registered as refused by #{game.refused.by}, and this run " \
                                               "refused it: #{refusal.message}"
    assert_includes refusal.message, game.refused.phrase
    assert_equal game.refused.names_fix, VBlank::Testing::PackParity.stated_refusal?(refusal),
                 "#{game.name} is registered as refused in words that do not say to build all-in-one, and they now say " \
                 "it. Take `names_fix: false` off its line in test/pack_games.rb. The refusal: #{refusal.message}"
  end

  # A game marked refused that now builds and plays is held alike from here on: its mark comes off.
  private def assert_registered_as_built(game)
    return unless game.refused && refused_on_this_run?(game.refused)

    flunk "#{game.name} is registered as refused with its pack left out (#{game.refused.phrase.inspect}), and it now " \
          "builds and plays. Take `refused:` off its line in test/pack_games.rb, so that its two builds are held alike."
  end

  # Whether this run is one of those +refusal+ names (PackGames::REFUSED_BY).
  private def refused_on_this_run?(refusal)
    case refusal.by
    when :builder then true
    when :computer_build then VBlank::Testing.checked?
    when :computer_build_mixing_at_recording_rates
      console = VBlank::Console.described(game_console)
      VBlank::Testing.checked? && console.mixes_recordings && console.recording_voice_hz.nil?
    end
  end

  private def assert_alike_or_registered_difference(game, difference)
    unless game.differs&.shown_on?(game_console)
      return assert_nil difference, "#{game.name}: built with its pack left out and handed its pack, the game does not " \
                                    "play as its all-in-one build. #{difference}"
    end

    refute_nil difference, "#{game.name} is registered as a game its two builds show differently today " \
                           "(#{game.differs.what}), and they now play alike. Take `differs:` off its line in test/pack_games.rb."
  end

  # THE BUILD WITH ITS PACK LEFT OUT, WRITTEN OUT, HOLDS NONE OF THE NUMBERS THE FILE PUTS INTO IT.
  # The interpreter plays such a program with the file's numbers in place (IR::StartFile.filled),
  # so what the file adds is every table, picture and recording that differs between the program
  # and the filled one. A run of those numbers in the written-out code is the original's data
  # shipped in a build that must hold none.
  private def assert_written_without_the_packs_numbers(game, left_out, file)
    # Written out as this run plays it, for the run's console, which decides what a build refuses.
    text = written_out(program_played(left_out))
    return unless text

    runs = joined_runs_in(text)
    numbers_from_file(left_out, file).each do |needle|
      held = runs.select { |run| run.include?(",#{needle.join(',')},") }
      assert_empty held.map { |run| run[0, 40] }, "#{game.name}: built with its pack left out, the written-out game holds " \
                                                  "the pack's numbers #{needle.inspect}"
    end
  end

  # THE SEARCH FINDS WHAT IT LOOKS FOR: the all-in-one build of each of +names+, written out, holds
  # runs of the numbers its pack file puts into the build with the pack left out. Without this
  # the search above could pass by never finding anything. A lowering's test file calls this.
  private def assert_search_finds_the_packs_numbers_all_in_one(*names)
    names.each do |name|
      game = PackGames.named(name)
      Dir.mktmpdir do |folder|
        whole = game.kit.new.build(game, folder, PackGames::ALL_IN_ONE)
        left_out = game.kit.new.build(game, folder, PackGames::LEFT_OUT)
        runs = joined_runs_in(written_out(program_played(whole.program)))
        needles = numbers_from_file(left_out.program, whole.pack_file)
        found = needles.count { |needle| runs.any? { |run| run.include?(",#{needle.join(',')},") } }

        refute_empty needles, "#{name}: the pack file puts numbers into the build with its pack left out"
        assert_operator found, :>, 0, "#{name}: the all-in-one build written out holds none of the #{needles.length} runs " \
                                      "of the pack's numbers the search looks for, so the search proves nothing"
      end
    end
  end

  # Each table of numbers +text+ holds as one string, a comma on each side of every number: all
  # its whole numbers in order, and every run of base64 unpacked each way an array is packed.
  private def joined_runs_in(text)
    blobs = text.scan(%r{[A-Za-z0-9+/=\n]{64,}}).map { |blob| blob.delete("\n").unpack1("m") }
    lists = [text.scan(/-?\d+/)] + blobs.flat_map { |bytes| WrittenOutSearch::PACKINGS.map { |packing| bytes.unpack(packing) } }
    lists.map { |list| ",#{list.join(',')}," }
  end

  # Runs of the numbers the file puts into +program+: taken from each operand the program filled
  # from +file+ holds that no step of the program itself does, and left out where the program
  # holds the same run among its own numbers (a made-up game may use its original's colours in a
  # list of its own).
  private def numbers_from_file(program, file)
    own_values = program.walk.flat_map { |node| node.attrs.values }
    own = own_values.to_set
    own_runs = own_values.flat_map { |value| numbers_of(value) }.map { |numbers| ",#{numbers.join(',')}," }
    VBlank::IR::StartFile.filled(program, file).walk.flat_map do |node|
      node.attrs.values.reject { |value| own.include?(value) }.flat_map { |value| needles_of(value) }
    end.uniq.reject { |needle| own_runs.any? { |run| run.include?(",#{needle.join(',')},") } }
  end

  # +value+, an operand, as the lists of numbers a build may write it as: a list's own numbers, or
  # bytes read as bytes, signed and not, and as sixteen-bit numbers, signed and not, which is how
  # a recording keeps its samples and a picture its pixels.
  private def numbers_of(value)
    case value
    when String then [value.bytes, value.unpack("c*"), value.unpack("v*"), value.unpack("s<*")]
    when Array then [value.flatten.grep(Integer)]
    else []
    end
  end

  # A few runs of +value+'s numbers, each varied enough to be in no program by chance: not a row
  # of one colour, and not a count going up or down by a step.
  private def needles_of(value)
    numbers_of(value).flat_map do |numbers|
      last = numbers.length - NEEDLE_LENGTH
      next [] if last.negative?

      [0, last / 2, last].uniq.first(NEEDLES_EACH).map { |at| numbers[at, NEEDLE_LENGTH] }.select do |run|
        run.uniq.length >= NEEDLE_VARIETY && run.each_cons(2).map { |one, other| other - one }.uniq.length > 1
      end
    end
  end
end
