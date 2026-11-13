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
