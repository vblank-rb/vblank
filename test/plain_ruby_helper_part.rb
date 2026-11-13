# frozen_string_literal: true

# A part of a game in a file of its own, written in normal Ruby: what `VBlank.require_game_file`
# brings in for test/all/vblank/dsl/test_plain_ruby.rb.
class PlainRubyHelperPart
  LIMIT = 3
  NAME = "part"
  WRITTEN_ON = __LINE__

  attr_reader :count

  def initialize(build)
    @count = build.var(:part_count, 0)
    @flips = build.var(:part_flips, 0)
  end

  def step
    if @count < LIMIT
      @count += 1
    else
      @flips = 9
    end
  end
end

# A method of the game's defined in a file of its own, so a game block calling it cannot see what
# it does: it changes nothing.
def plain_ruby_helper_pass_over(value) = value

# An object of the game's whose method moves a place it is handed on by one, defined in a file of
# its own so a game block calling it through the object cannot see the method.
class PlainRubyPlaceMover
  def move_place_on(place) = place.increase!(1)
end
