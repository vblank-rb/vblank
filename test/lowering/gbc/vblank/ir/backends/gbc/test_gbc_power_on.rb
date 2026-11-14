# frozen_string_literal: true

require "test_helper"
require "many_tiles"
require "sound_comparison"

# WHAT A COLOR CARTRIDGE SHOWS FROM POWER-ON UNTIL THE GAME'S FIRST FRAME. The cartridge copies its
# art into the console before the game's first line, and a game sets itself up before its first
# frame, which together can take several frames. A Color game whose screens fade in from white
# never shows black on the way: the screen shows the backdrop, the first colour of its first list,
# from power-on until the game draws. A game whose backdrop is black shows black, as it always did.
class TestGBCPowerOn < Minitest::Test
  include SoundComparison

  # A tile of each number, drawn by place from a list whose first colour is white: none of the
  # screen is ever black, so a black pixel is the console showing nothing.
  TILES = 300
  LIST = %i[transparent white red green blue].freeze

  # +count+ tiles of different pictures in the tileset :pale_set, each drawn by place from :pale,
  # declared in +game+; the map of a screen that shows them all in turn, row by row.
  def self.declare_pale_tiles(game, count)
    game.colors :pale, LIST
    names = (0...count).map do |n|
      game.image :"tile#{n}", width: 8, height: 8, colors: :pale,
                              places: Array.new(64) { |i| (n[i % 9] + n[(i + 3) % 9] + (i / 32)) % 4 + 1 }
      :"tile#{n}"
    end
    keys = (0...count).map { |n| (n + 256).chr(Encoding::UTF_8) }
    game.tiles :pale_set, keys.zip(names).to_h
    Array.new(18) { |r| (0...20).map { |c| keys[((r * 20) + c) % count] }.join }
  end

  private def white_game_with_much_art(setting_up:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      map = TestGBCPowerOn.declare_pale_tiles(self, TILES)
      field = background :field, tiles: :pale_set, map: map
      # Drawn with lists of its own, as a screen faded in from white is: its first colour, white,
      # is then the backdrop, since no cell of it is empty.
      colors :pale_again, %i[transparent white blue green red]
      count = 0
      repeat(setting_up) { count += 1 }
      game_loop { field.draw_with :pale_again }
    end
    b.finalize_program
    b.program
  end

  # A GAME WHOSE SCREENS BRING THEIR OWN COLOURS IN: a white title, and a second screen of eight
  # lists more, which together are more than the Color's eight at once. Each screen's lists come in
  # with it, and the title's are not in the console until the game first shows it. A title of
  # +title_tiles+ different tiles takes frames to copy in after the game's first frame, and until
  # its lists come in with it the screen shows nothing drawn: the game's +backdrop+, nil for black.
  private def white_title_among_lists(setting_up: 0, title_tiles: 1, backdrop: nil)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      backdrop ? screen(:tiled, backdrop: backdrop) : screen(:tiled)
      map = TestGBCPowerOn.declare_pale_tiles(self, title_tiles)
      colors :pale_again, %i[transparent white blue green red]
      # Each list holds the backdrop, so one of them can be the list an empty cell shows.
      lists = (0...8).map { |n| [:transparent, VBlank::Graphics::Color.rgb(31, n, n), 31 << 5, 31 << 10, backdrop || 0] }
      row = ManyTiles.declare_listed(self, :many, lists)
      scene(:title) do
        title = background :title, tiles: :pale_set, map: map
        title.draw_with :pale_again
      end
      scene(:busy) { background :busy, tiles: :many, map: [row] }
      count = 0
      repeat(setting_up) { count += 1 }
      var :state, 0
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :busy
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A GAME WHOSE FIRST SCREEN IS PAINTED white, pixel by pixel, rather than drawn from tiles.
  private def white_painted_game(setting_up:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      count = 0
      repeat(setting_up) { count += 1 }
      game_loop do
        clear_screen :white
        fill_rect 40, 40, 20, 20, :red
      end
    end
    b.finalize_program
    b.program
  end

  # Sixteen places across the screen.
  SPOTS = [20, 60, 100, 140].product([16, 56, 96, 136]).freeze

  # The frames of the first thirty a cartridge of +program+ shows black on at any of SPOTS.
  private def black_frames(program)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "WHITE")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 0)
    (1..30).filter_map do |frame|
      v.step
      frame if SPOTS.any? { |x, y| v.pixel_gba(x, y).zero? }
    end
  end

  def test_a_white_game_never_shows_black_while_it_loads
    assert_empty black_frames(white_game_with_much_art(setting_up: 20_000)), "frames that showed black"
  end

  def test_a_white_title_among_screens_with_their_own_colours_never_shows_black_while_it_loads
    assert_empty black_frames(white_title_among_lists(setting_up: 20_000)), "frames that showed black"
  end

  # A TITLE WITH MUCH ART, which takes two frames to copy in after the game's first, shows nothing
  # drawn until then: black, the backdrop of a game that says none — and the game's own, said white,
  # the way a cartridge that fades its screens in from white starts.
  def test_a_white_title_with_much_art_shows_the_backdrop_while_it_loads
    assert_equal [5, 6], black_frames(white_title_among_lists(title_tiles: 200)), "black while it loads"
    assert_empty black_frames(white_title_among_lists(title_tiles: 200, backdrop: :white)), "frames that showed black"
  end

  # ...and plays as the interpreter plays it, pass for pass.
  def test_a_white_title_on_a_white_backdrop_plays_as_the_interpreter_plays_it
    game_player.run(white_title_among_lists(title_tiles: 200, backdrop: :white), frames: 6)
  end

  def test_a_white_painted_screen_never_shows_black_while_it_loads
    assert_empty black_frames(white_painted_game(setting_up: 20_000)), "frames that showed black"
  end

  # THE FRAMES SPENT SETTING UP ARE COUNTED, though the screen is off for all of them: a game that
  # spins before its loop notes what `frames_since_power_on` read on its first pass, and the frame
  # that pass's change is first seen on is one after that. A game that +plays+ a recording starts it
  # before it spins: a square wave of 256Hz, long enough to be heard after the first frame.
  private def counting_game(setting_up, plays: false)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = ([80] * 16 + [-80] * 16) * 400
    b.instance_eval do
      screen :bitmap
      sample(:hum, pcm: recording).play if plays
      count = 0
      passes = 0
      first = -1
      repeat(setting_up) { count += 1 }
      game_loop do
        first = frames_since_power_on if passes == 0
        passes += 1
      end
    end
    b.finalize_program
    b.program
  end

  # [the frame the first pass is first seen on, what it read]
  private def first_pass_on_color(setting_up, plays: false)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(counting_game(setting_up, plays: plays), title: "POWERON")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.built.variables)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 200 frames" if frame == 200
      v.step
      frame += 1
    end
    [frame, v.var(:first)]
  end

  def test_the_frames_spent_setting_up_are_counted
    quick_frame, quick = first_pass_on_color(0)
    slow_frame, slow = first_pass_on_color(3_000)

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame + 3, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end

  # WHEREVER IN A FRAME SETTING UP ENDS, the count is the frames shown. The first frame's copy of
  # everything set up (rt_upload_whole) runs with the screen still off, a whole screen's grid of
  # cells taking a good part of a frame, so a frame that ends during it is one of the frames spent
  # setting up. Setting up that ends a little sooner or later, by a tenth of a frame at a time over
  # two frames, finds each place the copy can be in a frame. A game with a song waits for its first
  # frame its own way (Frame#emit_wait_with_songs), so it is played both ways.
  private def counting_game_with_a_grid(setting_up, song:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      map = TestGBCPowerOn.declare_pale_tiles(self, TILES)
      background :field, tiles: :pale_set, map: map
      if song
        enable_sound
        song(:tune) { voice(:lead) { |v| v.note :C5, :whole } }
        play_song :tune
      end
      count = 0
      passes = 0
      first = -1
      repeat(setting_up) { count += 1 }
      game_loop do
        first = frames_since_power_on if passes == 0
        passes += 1
      end
    end
    b.finalize_program
    b.program
  end

  # Each number of turns setting up that the first pass misreads, saying what it read.
  private def misread_first_passes(song:)
    (0..20).map { |step| 3_000 + (step * 100) }.filter_map do |setting_up|
      rom = VBlank::Console.for(:gbc).builder.cartridge_for(counting_game_with_a_grid(setting_up, song: song), title: "POWERON")
      v = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.built.variables)
      frame = 1
      until v.var(:passes).positive?
        flunk "no pass ran in 200 frames" if frame == 200
        v.step
        frame += 1
      end
      "#{setting_up} turns: first seen on #{frame}, read #{v.var(:first)}" unless v.var(:first) == frame - 1
    end
  end

  def test_the_frames_spent_setting_up_are_counted_wherever_setting_up_ends
    assert_empty misread_first_passes(song: false), "the first pass reads one less than the frame it is first seen on"
  end

  def test_the_frames_spent_setting_up_are_counted_wherever_setting_up_ends_in_a_game_with_a_song
    assert_empty misread_first_passes(song: true), "the first pass reads one less than the frame it is first seen on"
  end

  # THE FIRST PASS'S MOMENT WAITS FOR ITS SOUNDS. The first frame's copy can meet a frame's end
  # with the screen still off, and the reader then finds the first pass waiting; the screen's first
  # blank after it comes on shows that pass while the processor sleeps, before the wait reaches the
  # place the reader takes the pass's sounds at (GBC::SoundLog). Read there, the pass had no sounds
  # to count. Wherever setting up ends, the run plays as the interpreter does.
  def test_the_first_pass_plays_as_the_interpreter_wherever_setting_up_ends_in_a_game_with_a_song
    (0..20).map { |step| 3_000 + (step * 100) }.each do |setting_up|
      VBlank::IR::Backends::GBC::CheckedRun.new.run(counting_game_with_a_grid(setting_up, song: true), frames: 3)
    end
  end

  # A GAME THAT PLAYS A RECORDING COUNTS THEM TOO: the timer that counts the frames the screen is
  # off for plays the recording's samples once the screen is on, and a recording started while the
  # game sets up starts with its first frame, as the interpreter's mix does.
  def test_the_frames_spent_setting_up_are_counted_in_a_game_that_plays_a_recording
    quick_frame, = first_pass_on_color(0, plays: true)
    slow_frame, slow = first_pass_on_color(3_000, plays: true)

    assert_operator slow_frame, :>, quick_frame + 3, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end

  # A GAME THAT KEEPS A SMALL SAVE RECORD, as a high-score table is: a list of 61 bytes, so a body
  # of 65, loaded at power-on. Pokémon Pinball's retail cartridge checks four such blocks at
  # power-on (home/save.asm, LoadSavedData) and reaches its main loop's first pass on frame 11,
  # measured in the emulator; setting the record up must cost no more than that.
  private def saving_game(record: true)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      if record
        scores = list :scores, capacity: 61, width: :byte
        high = save_data(:high, copies: 1) { keep scores }
        high[0].load
      end
      passes = 0
      game_loop { passes += 1 }
    end
    b.finalize_program
    b.program
  end

  # The frame the first pass of +program+'s cartridge is first seen on, from +save+.
  private def first_pass_frame(program, save: nil)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "SAVESTART")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.built.variables, save: save)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 200 frames" if frame == 200
      v.step
      frame += 1
    end
    frame
  end

  # The record's lists (its own, and the table of places every game with a record keeps) move
  # between save memory and the game as blocks (Runtime::Lists#emit_save_moves), which is what
  # brought both starts to two frames after the same game with no record.
  def test_a_small_save_record_on_an_empty_chip_starts_two_frames_after_a_game_with_none
    without = first_pass_frame(saving_game(record: false))

    assert_operator first_pass_frame(saving_game), :<=, without + 2, "the first pass, on an empty chip"
  end

  def test_a_small_save_record_with_a_good_save_starts_two_frames_after_a_game_with_none
    program = saving_game
    good = Reference.save_into(SaveImage.new, program, :high, 0, scores: (1..61).to_a)
    without = first_pass_frame(saving_game(record: false))

    assert_operator first_pass_frame(program, save: good), :<=, without + 2, "the first pass, with a good save"
    assert_operator without + 2, :<=, 11, "retail's own first pass is on frame 11"
  end

  def test_a_recording_started_while_the_game_sets_up_is_heard_once_it_runs
    program = counting_game(3_000, plays: true)
    first = game_player.run(program, frames: 3)[:first]
    heard = console_voice(program, :wave, frames: first + 20)

    assert_in_delta 256, heard.held_note(first + 10).pitch, 4
  end
end
