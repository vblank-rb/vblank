# frozen_string_literal: true

# The first file of parts split over two files, brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_ruby_parts.rb. It names each Array and starts it, and reads none
# of them at an index the game works out: test/plain_ruby_split_counts_changed.rb, brought in
# after, does. Each plays as CountsByNumberPart in test/plain_ruby_named_parts.rb, written in one.

# Reopened in the other file, which adds the method its routine calls.
class SplitCountsPart
  game_variables :counts

  def initialize(builder)
    @counts = [0, 0]
    @which = builder.var(:split_counts_which, 1)
    builder.func(:split_counts_tick) { count }
  end
end

# A parent whose subclass, in the other file, changes the Array.
class SplitCountsParentPart
  game_variables :counts

  def initialize(builder)
    @counts = [0, 0]
    @which = builder.var(:split_counts_parent_which, 1)
  end
end

# Named here and read only at indexes known while building, there too: a variable for each.
class SplitKnownCountsPart
  game_variables :counts

  def initialize(builder)
    @counts = [0, 0]
    builder.func(:split_known_counts_tick) { count }
  end
end
