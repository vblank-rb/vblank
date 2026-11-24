# frozen_string_literal: true

# A Struct and a Data class written in a file brought in with plain `require`, which no rewrite
# reads, for test/all/vblank/dsl/test_plain_ruby_answers.rb: game code makes them as it makes the
# ones in a game file, and must get Ruby's answers from them all the same.

# A point in a plain file.
PlainFilePoint = Struct.new(:x, :y)

# A point in a plain file that cannot change.
PlainFileFixedPoint = Data.define(:x, :y)

# A point made by a method in a plain file, never named by game code.
PlainFileMadePoint = Struct.new(:x, :y)

# Makes a PlainFileMadePoint at +x+.
module PlainFilePoints
  def self.at(x) = PlainFileMadePoint.new(x, 0)
end
