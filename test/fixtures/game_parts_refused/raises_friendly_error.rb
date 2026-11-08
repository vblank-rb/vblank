# frozen_string_literal: true

# A part of a game whose method stops the build with a friendly error, as Ruby code does.
module PartRaisingFriendlyError
  def self.checked(speed)
    raise ArgumentError, "A speed is a whole number from 1 to 8." unless (1..8).cover?(speed)

    speed
  end
end
