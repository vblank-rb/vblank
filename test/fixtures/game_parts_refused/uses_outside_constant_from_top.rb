# frozen_string_literal: true

# A part of a game that reaches the file system through a constant from outside the game, named
# from the top of Ruby's constants.
module PartUsingOutsideConstantFromTop
  def self.level = ::File.read("level.txt")
end
