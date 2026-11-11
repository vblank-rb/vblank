# frozen_string_literal: true

# A part of a game that reads a constant through an object it makes from a constant outside the
# game: the constant read is the object's own, and the one the expression names is still checked.
module PartUsingOutsideConstantInExpression
  def self.level_kind = File.new("level.txt").class::SEPARATOR
end
