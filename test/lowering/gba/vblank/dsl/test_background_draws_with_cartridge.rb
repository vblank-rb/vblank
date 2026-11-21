# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_background_draws_with"

# A recoloured background on the Advance's cartridge, its pixels read in the emulator. What
# `draw_with` does to a background on every run is in
# test/all/vblank/dsl/test_background_draws_with.rb.
class TestBackgroundDrawsWithCartridge < Minitest::Test
  include BackgroundDrawsWithGames

  def test_the_console_draws_the_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(a_wall_of_bars { |rays| rays.draw_with :shimmer }, name: "BGSWAP"),
                                  frames: 3)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), v.pixel_gba(5, 1), "and the second"
  end

  # --- THE TINT NOTE IS WRITTEN AT POWER-ON ---
  #
  # A layer told `draw_with` copies its list in through whatever tint is in force, and reads
  # the note of which tint that is to find out (PaletteTint#emit_colors_into_bank). A game
  # that never tints still reads it, so the build has to write "no tint" there before anything
  # does: the console makes no promise about what its memory holds at power-on. The emulator
  # hands out cleared memory, so a game finding nought proves nothing. This puts a tint in the
  # note first, in the gap between loading the cartridge and running its first instruction,
  # and asks whether the layer still shows its list's own colours.
  def test_a_layer_drawn_with_a_list_ignores_what_the_tint_note_held_at_power_on
    require_emulator!
    rom = assemble_rom(a_wall_of_bars { |rays| rays.draw_with :shimmer }, name: "BGSTALE")
    note = rom.var_addresses.fetch(:__tint_state)

    played_after_writing(rom, note, STALE_TINT_NOTE) do |probe|
      assert_equal Color.resolve(:yellow), console_color(probe.pixel(1, 1)), "the first place of the list, untinted"
      assert_equal Color.resolve(:white), console_color(probe.pixel(5, 1)), "and the second"
    end
  end

  # The same for where the layer's list in force starts, in a game that changes screen kind and
  # starts on a tiled screen. Setting that screen up copies the background colours and then puts
  # each layer's list in force back over them (PaletteTint#emit_changed_bg_lists_again), which
  # reads that variable before the game's own first statement has run. A stale word there would
  # copy sixteen colours from wherever it pointed, and nothing would put them right while the
  # layer is never told anything. Here it points at the start of the cartridge.
  def test_a_layer_never_told_anything_ignores_where_its_list_pointed_at_power_on
    require_emulator!
    rom = assemble_rom(a_wall_beside_a_turning_scene, name: "BGSTALEAT")
    list_at = rom.var_addresses.fetch(:__bg_rays_colors_at)

    played_after_writing(rom, list_at, VBlank::Console::Hardware::ROM_START) do |probe|
      assert_equal Color.resolve(:red), console_color(probe.pixel(1, 1)), "the layer's own first colour"
      assert_equal Color.resolve(:green), console_color(probe.pixel(5, 1)), "and its second"
    end
  end

  # +rom+ played three frames in the emulator with +word+ put at +address+ before its first
  # instruction runs, then handed to the block.
  private def played_after_writing(rom, address, word)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "stale.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.write32(address, word)
        probe.step(3)
        yield probe
      ensure
        probe.close
      end
    end
  end

  # The wall of bars every tiled scene shows, never told to draw with another list, beside a
  # turning scene the game never reaches: enough for the build to set each screen kind up as a
  # scene takes over, and so to set the title's up before the game's first statement. The wall
  # is the whole game's rather than the title's, so no scene sends colours that would hide a
  # stale copy.
  private def a_wall_beside_a_turning_scene
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      state = var :state, 0
      scene(:title) { rays.draw_with :shimmer if pressed(:a) }
      scene(:turn) do
        screen :rotozoom
        background(:turner, tiles: :wall, map: Array.new(16) { "#" * 16 }).scale(1.0)
      end
      game_loop do
        state = 1 if pressed(:b)
        call({ 0 => :title, 1 => :turn }, number: :state)
      end
    end
    builder.finalize_program
    builder.program
  end

  # Half of the walk toward pure red: the colour above the steps, as the note packs them
  # (PaletteTint#tint_state_word), in the coarse walk of a game that asks for no fraction.
  STALE_TINT_NOTE = (0x001F << 6) | 16

  # The probe's eight bits a channel as the console's fifteen-bit colour (Verifier#pixel_gba).
  private def console_color(rgb)
    red, green, blue = rgb
    (red >> 3) | ((green >> 3) << 5) | ((blue >> 3) << 10)
  end

  # The colour behind everything is not one of the layer's
  # (BackgroundDrawsWithGames#a_wall_with_gaps_and_lists_that_start_with_a_colour).
  def test_a_list_that_starts_with_a_colour_leaves_the_backdrop_as_it_was
    wall = a_wall_with_gaps_and_lists_that_start_with_a_colour
    v = assert_emulator_loads_rom(assemble_rom(wall, name: "BGBACK"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the wall is drawn with the other list"
    assert_equal Color.resolve(:black), v.pixel_gba(9, 1), "and the gap beside it is still the backdrop"
  end

  # --- THE LAYER'S COLOURS ARE ITS OWN ---
  #
  # The console draws every pixel by looking a colour up in one shared table, and the
  # framework normally lets two pictures drawn from the same colours share one group of
  # sixteen entries — a saving nobody has to hear about. It stops being invisible the moment
  # a layer can be recoloured, because the swap writes into that group: anything else
  # reading it would change colour too, and nothing in the program would say why.
  #
  # So a layer that can be recoloured gets a group nobody else reads. This is the test that
  # says so, and it can only be asked of the console — the interpreter has no groups to
  # share, so it agrees whatever the build decided.
  private def two_walls_drawn_from_the_same_colours
    front = Array.new(20) { |r| (r < 10 ? "#" : " ") * 30 }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar_front, width: 8, height: 8, data: BAR, colors: OWN
      image :bar_back, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :front_wall, "#" => :bar_front
      tiles :back_wall, "#" => :bar_back
      layers :far, :near
      layer(:far) { background :steady, tiles: :back_wall, map: Array.new(20) { "#" * 30 } }
      rays = layer(:near) { background :rays, tiles: :front_wall, map: front }
      game_loop { rays.draw_with :shimmer }
    end
    builder.finalize_program
    builder.program
  end

  def test_recolouring_one_layer_leaves_another_drawn_from_the_same_colours_alone
    v = assert_emulator_loads_rom(assemble_rom(two_walls_drawn_from_the_same_colours, name: "BGOWNPAL"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the layer that was told to shimmer"
    assert_equal Color.resolve(:red), v.pixel_gba(1, 120),
                 "the layer behind it changed colour too: the two are sharing one set of sixteen"
  end
end
