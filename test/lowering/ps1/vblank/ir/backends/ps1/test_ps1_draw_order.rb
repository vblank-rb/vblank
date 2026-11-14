# frozen_string_literal: true

require "test_helper"

# A RUN OF SPRITES DRAWN IN AN ORDER A LIST HOLDS, read as the interpreter reads the list
# (Reference#names_in_draw_order): every entry it holds, however many that is, a place below nought
# counting back from the last sprite of the run, and a place naming none of them stopping the game. The
# builder keeps the list at the run's length and fills it with places that name its sprites, so only a
# run written by hand reaches the rest: the native run's test_native_picture.rb holds the game as C to
# the same games. Here, on the PlayStation's program alone, since the Color, the Super Nintendo and the
# Genesis read as many entries as the run has sprites.
class TestPS1DrawOrder < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  BLOCK = Ractor.make_shareable("#{'#' * 16}\n" * 16)

  # -1 is the green block, so it goes down first, under the red one; then red under green; then the list
  # names only red, and green is not drawn.
  def test_a_draw_order_holds_places_as_the_interpreter_reads_them
    program = two_blocks_and_a_list do |order|
      order.push(-1)
      order.push 0
      n = var :n, 0
      game_loop do
        if n == 3
          order[0] = 0
          order[1] = 1
        end
        order.pop if n == 6
        n += 1
      end
    end

    run = PS1::CheckedRun.new.run(program, frames: 10)
    assert_equal Color.resolve(:red), run.screen.pixel(70, 66), "red alone once the list names only it"
    assert_equal [:back], run.sprites.map(&:name), "the green block is not drawn at the end"
  end

  # A place that names none of the run's sprites stops the game, as it stops the interpreter. The
  # interpreter stops first in a checked run, so the program is played alone.
  def test_a_draw_order_naming_no_sprite_stops_the_game
    program = two_blocks_and_a_list do |order|
      order.push 0
      order.push 2
      game_loop {}
    end

    assert_raises(IndexError) { Reference.new.run(program, frames: 3) }
    error = assert_raises(VBlank::IR::ProgramError) { PS1::HeadlessRun.new.run(program, frames: 3) }
    assert_match(/draw order names sprite 2 of the 2/, error.message)
  end

  private

  # Two blocks that overlap, the red one listed first, and a list the game keeps their order in by hand,
  # written onto the statement that draws them.
  def two_blocks_and_a_list(&game)
    block = BLOCK
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:back, "#" => :red) { block }
      image(:fore, "#" => :green) { block }
      sprite :back, at: [60, 60]
      sprite :fore, at: [68, 64]
      instance_exec(list(:order, capacity: 4, width: :byte), &game)
    end
    builder.finalize_program
    program = builder.program.copy.tap { |copy| copy.console = :ps1 }
    with_order_written_by_hand(program)
  end

  def with_order_written_by_hand(program)
    program.walk.select { |node| node.kind == :present_objects }.each do |drawn|
      run = VBlank::IR::Build::DrawOrder.new(objects: drawn.names, order: :order)
      ordered = VBlank::IR::Build.present_objects(drawn.names, orders: [run])
      beside = drawn.parent.children
      beside[beside.index(drawn)] = ordered
      ordered.parent = drawn.parent
    end
    program
  end
end
