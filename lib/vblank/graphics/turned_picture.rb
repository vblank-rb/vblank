# frozen_string_literal: true

module VBlank
  module Graphics
    # A picture named turned, before there is a build to turn it in: what `VBlank.mirror` and
    # `VBlank.upside_down` give a Struct's `drawn_as`, which is read as the file loads. The build
    # turns it when the Array of the Struct is made (Builder#mirror, Builder#upside_down), so it
    # costs what a picture turned there costs.
    #
    # ```ruby
    # Fish = Struct.new(:x, :y) do
    #   drawn_as facing: { right: :fish_right, left: VBlank.mirror(:fish_right) }
    # end
    # ```
    TurnedPicture = Data.define(:way, :source)
  end

  # The picture +source+ turned left to right, for a Struct's `drawn_as` (Graphics::TurnedPicture).
  # In a game block, `mirror` does the same.
  def self.mirror(source) = Graphics::TurnedPicture.new(way: :mirrored, source: source)

  # The picture +source+ turned top to bottom, for a Struct's `drawn_as`, as `upside_down` in a game block.
  def self.upside_down(source) = Graphics::TurnedPicture.new(way: :upside_down, source: source)
end
