# frozen_string_literal: true

# The second file of parts split over two files, brought in by `VBlank.require_game_file` after
# test/plain_ruby_split_counts_named.rb, which names each Array and starts it. Here two are
# changed at an index the game works out, so each is a list, and one only at indexes known while
# building, so it stays a variable for each.

# SplitCountsPart reopened: the method its routine calls.
class SplitCountsPart
  def count
    @counts[@which] += 1
  end
end

# A subclass of a part named in the other file.
class SplitCountsChildPart < SplitCountsParentPart
  def initialize(builder)
    super
    builder.func(:split_counts_child_tick) { @counts[@which] += 1 }
  end
end

# SplitKnownCountsPart reopened: the second count goes up by one a pass.
class SplitKnownCountsPart
  def count
    @counts[1] += 1
  end
end
