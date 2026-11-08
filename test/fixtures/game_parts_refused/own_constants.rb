# frozen_string_literal: true

# A part of a game that names its own constants, and one another part of the game defines later.
module PartWithOwnConstants
  SPEED = 3

  def self.speed = SPEED
  def self.later = PartDefinedLater::STEP
end
