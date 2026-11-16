# frozen_string_literal: true

# A GAME LAID OUT FOR THE GAME BOY COLOR, BUILT AS THE ADVANCE WITH THE COLOR'S SCREEN, as the C,
# JavaScript and Ruby builds show it: the game's 160×144 at its own size in the middle of the
# Advance's 240×160, with the border round it that the cartridge draws
# (test/lowering/gba/vblank/ir/backends/gba/test_border_sprites.rb is the cartridge's own test). A
# file of each of those runs includes this and names its HeadlessRun.
module BorderFrameTests
  LEFT = 40
  TOP = 8

  # Four bars of colour across the top of the game's screen and a white one across its foot, so a
  # picture landed in the wrong place, or cut short, reads wrong.
  PLAIN = Ractor.make_shareable(VBlank.game("BORDERN", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :bitmap
    game_loop do
      clear_screen :black
      fill_rect 0, 0, 40, 8, :red
      fill_rect 40, 0, 40, 8, :green
      fill_rect 80, 0, 40, 8, :blue
      fill_rect 0, 136, 160, 8, :white
    end
  end)

  # ...with a border of its own, drawn as text art and repeated round the screen.
  PATTERNED = Ractor.make_shareable(VBlank.game("BORDERQ", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
    screen :bitmap
    border "#" => :blue, "." => :yellow do
      "#.\n.#\n"
    end
    game_loop { clear_screen :red }
  end)

  # A game for the Advance's own screen, which has no border.
  WHOLE = Ractor.make_shareable(VBlank.game("BORDERX", consoles: %i[gba]) do
    screen :bitmap
    game_loop do
      clear_screen :black
      fill_rect 0, 0, 40, 8, :red
    end
  end)

  def test_a_color_game_is_shown_in_the_middle_with_the_default_border
    run = played(PLAIN)
    border = VBlank::Graphics::Border.default(whole: [240, 160], inner: [160, 144])

    assert_equal [240, 160], [run.framed.width, run.framed.height]
    [[0, 0], [239, 0], [0, 159], [239, 159], [LEFT - 1, 80], [LEFT + 160, 80], [120, TOP - 1], [120, TOP + 144]]
      .each do |x, y|
        assert_equal border[(y * 240) + x], run.framed.pixel(x, y), "the border at (#{x}, #{y})"
      end
    assert_equal run.screen.shown, game_area(run), "the game's whole screen, at (40, 8)"
  end

  def test_a_border_of_the_games_own_is_repeated_round_the_screen
    program = PATTERNED.program(console: :gba)
    run = played(PATTERNED)
    width, height = program.border_size
    border = VBlank::Graphics::Border.whole_picture(width: width, height: height, pixels: program.border, whole: [240, 160])

    [[0, 0], [1, 0], [0, 1], [239, 159], [LEFT - 1, TOP]].each do |x, y|
      assert_equal border[(y * 240) + x], run.framed.pixel(x, y), "the border at (#{x}, #{y})"
    end
    refute_equal run.framed.pixel(0, 0), run.framed.pixel(1, 0), "two colours, in turn"
    assert_equal run.screen.shown, game_area(run)
  end

  def test_a_game_for_the_whole_screen_is_framed_as_it_is_shown
    run = played(WHOLE)

    assert_equal [240, 160], [run.framed.width, run.framed.height]
    assert_equal run.screen.shown, run.framed.pixels
  end

  private

  def played(game) = self.class::HeadlessRun.new.run(game.program(console: :gba), frames: 3)

  # The game's 160×144 out of the framed picture, row by row.
  def game_area(run)
    (0...144).flat_map { |y| (0...160).map { |x| run.framed.pixel(LEFT + x, TOP + y) } }
  end
end
