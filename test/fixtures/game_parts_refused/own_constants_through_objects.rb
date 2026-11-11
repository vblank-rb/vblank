# frozen_string_literal: true

# A part of a game that reads its own constants through an object: through itself, through the
# class of one of its things, and through the class of a thing it is handed.
module PartReadingThroughObjects
  BOX = 4

  def self.own_box = self::BOX

  # A kind of thing, which keeps a fact about itself on its class.
  class Crate
    BOX = 6

    def box = self.class::BOX
  end

  def self.box_of(kind) = kind.class::BOX
end
