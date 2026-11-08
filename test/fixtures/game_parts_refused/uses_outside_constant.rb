# frozen_string_literal: true

# A part of a game that reaches the file system through a constant from outside the game.
module PartUsingOutsideConstant
  def self.level = File.read("level.txt")
end
