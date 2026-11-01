# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "list_reading_tests"

class TestReadingLists < Minitest::Test
  include ListReadingTests

  private def console = :gba

  # A list the build put in the roomy memory is read where it went.
  def test_a_list_in_the_roomy_memory_is_read_where_the_build_put_it
    built = VBlank.build("LISTFAR", console: :gba, out: nil, err: nil) do
      screen :bitmap
      far = list :far, capacity: 400, fast: false
      step = 0
      game_loop do
        step += 1
        far.push step * 3 if step < 6
      end
    end

    assert_equal 0x0200_0000, built.built.lists.fetch(:far).base & 0xFF00_0000
    assert_equal [3, 6, 9, 12, 15], cartridge(built).list(:far)
  end
end
