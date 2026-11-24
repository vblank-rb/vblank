# frozen_string_literal: true

# A part of one game, for test/all/vblank/dsl/test_plain_ruby_writer_names.rb: it turns a dial up
# through its writer, so `level` is a name this game's code changes.
class WriterNamesTurner
  def nudge(dial) = dial.level += 3
end

# The dial it turns.
class WriterNamesDial
  attr_accessor :level

  def initialize
    @level = 1
  end
end
