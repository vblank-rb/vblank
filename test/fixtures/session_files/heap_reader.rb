# frozen_string_literal: true

# Changes a slot of anything's `heaps` at a place the game works out. Brought in by one game's own
# block in test/all/vblank/builder/test_session.rb, so only that build reads it.
class HeapReader
  def initialize(store)
    @store = store
  end

  def bump(at) = @store.heaps[at] += 1
end
