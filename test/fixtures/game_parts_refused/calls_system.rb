# frozen_string_literal: true

# A part of a game that runs a command outside the game, which a game block may not.
module PartCallingSystem
  def self.listed = system("true")
end
