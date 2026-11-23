# frozen_string_literal: true

# A shelf of three heaps, handed out through a plain reader, which the game reads only at places
# known while building. Brought in by test/all/vblank/builder/test_session.rb before any build.
class HeapShelf
  attr_reader :heaps

  def initialize
    @heaps = [1, 2, 3]
  end
end
