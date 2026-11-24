# frozen_string_literal: true

# Structs and Data classes written in a file brought in with plain `require`, which no rewrite
# reads, for test/all/vblank/dsl/test_plain_file_structs.rb: game code makes them, or is handed
# them by the methods below, and must get Ruby's answers from them all the same. Each test has
# classes of its own, so a failure names one case.

PlainFilePoint = Struct.new(:x, :y)              # Made by game code from a changing number
PlainFileLoopPoint = Struct.new(:x, :y)          # Made by game code in the game loop
PlainFileStepPoint = Struct.new(:x, :y)          # A field game code changes
PlainFileFixedPoint = Data.define(:x, :y)        # A Data class made by game code
PlainFileMadePoint = Struct.new(:x, :y)          # Made by a method of this file
PlainFileArrayPoint = Struct.new(:x, :y)         # Handed back inside an Array
PlainFileHashPoint = Struct.new(:x, :y)          # Handed back inside a Hash
PlainFileInnerPoint = Struct.new(:x, :y)         # Held in a field of another object
PlainFilePair = Struct.new(:inner, :n)           # The object holding it
PlainFileBlockPoint = Struct.new(:x, :y)         # Handed to a block
PlainFileYieldedPoint = Struct.new(:x, :y)       # Handed to a block that never names it
PlainFileLocalClassPoint = Struct.new(:x, :y)    # Made through a local holding the class
PlainFileArgumentPoint = Struct.new(:x, :y)      # Handed to a method of game code
PlainFileEarlyPoint = Struct.new(:x, :y)         # Two made before game code names either
PlainFileFrozenPoint = Struct.new(:x, :y).freeze # A frozen class
PlainFileBase = Struct.new(:x, :y)               # A class made from Struct.new...
class PlainFileChild < PlainFileBase; end        # ...and one made from it

# Methods of a plain file that make the objects above from a number game code hands them.
module PlainFilePoints
  def self.at(x) = PlainFileMadePoint.new(x, 0)
  def self.many(x) = [PlainFileArrayPoint.new(x, 0)]
  def self.keyed(x) = { first: PlainFileHashPoint.new(x, 0) }
  def self.pair(x) = PlainFilePair.new(PlainFileInnerPoint.new(x, 0), 0)
  def self.each_at(x) = yield(PlainFileBlockPoint.new(x, 0))
  def self.yield_at(x) = yield(PlainFileYieldedPoint.new(x, 0))
  def self.argument_at(x) = PlainFileArgumentPoint.new(x, 0)
  def self.two_at(x) = [PlainFileEarlyPoint.new(x, 0), PlainFileEarlyPoint.new(x + 1, 0)]
  def self.child_at(x) = PlainFileChild.new(x, 0)
  def self.base_at(x) = PlainFileBase.new(x, 0)
  def self.frozen_at(x) = PlainFileLoopPoint.new(x, 0).freeze
end
