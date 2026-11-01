# frozen_string_literal: true

# The fish: one picture, a shoal of them, and a different set of colours on each.
#
# `colors` declares a list of colours no picture owns, and a sprite told `draw_with` one
# is matched to it BY PLACE — a pixel drawn in the second colour of the fish's own list is
# drawn in the second colour of this one. So the shape and the shading stay exactly as
# drawn and only the colours move: one picture in the console's sprite memory, and a
# shoal of six species swimming in it.
#
# What makes it per-FISH rather than per-pool is that `draw_with` is said inside the walk
# over the live ones, where each instance's own fields are in reach. `kind` is an ordinary
# field the fish carries, so one line written once leaves six fish six colours — and the
# choice rides in the sprite's own table entry, written with its position, so the colours
# change on the frame the fish moves and never a frame either side.
#
# They swim behind the water like the diver, because they are in the same layer.
module Dive
  class Fish
    SIZE = 16
    SHOAL = 6

    # The lists the fish are drawn with, laid out like the picture's own: see-through
    # first, then the body, then the eye. A fish whose `kind` names none of these would be
    # drawn in its own colours, so a number that ran off the end looks ordinary.
    SPECIES = Ractor.make_shareable(%i[perch gold ember slate plum moss])

    # Where each one swims, how fast, and which species it is. Negative is leftward, and
    # `face` below turns the picture round to match. Every one of them starts UNDER the
    # surface, because a fish in the sky is a fish.
    SHOAL_AT = Ractor.make_shareable([[20, 58, 1], [180, 74, -1], [60, 100, 2],
                [210, 126, -1], [120, 64, -2], [8, 142, 1]])

    SCREEN_W = 240
    SCREEN_H = 160

    BODY = Ractor.make_shareable(<<~ART)
      ................
      ......########..
      ..#..##########.
      .###.##########o
      .###.##########o
      ..#..##########.
      ......########..
      ................
    ART

    def initialize(build)
      @build = build
      declare_art
      # The console holds sixteen groups of sprite colours and lends them to whatever is on
      # screen, so a fish swimming off the edge could give its group up and borrow one back
      # when it returns. The whole shoal is in this dive, so `colors_in_use` says so, and all
      # six species keep their groups for as long as the dive lasts.
      build.colors_in_use SPECIES
      @fish = build.layer(:swimmers) do
        build.pool :fish, x: 0, y: 0, speed: 0, kind: 0, capacity: SHOAL,
                          facing: { right: :fish_right, left: build.mirror(:fish_right) }
      end
      SHOAL_AT.each_with_index do |(x, y, speed), which|
        @fish.spawn x: x, y: y, speed: speed, kind: which % SPECIES.length
      end
    end

    # Swim on, keep the place in the SEA rather than the place on the screen, and each
    # wear its own colours.
    #
    # +sank+ is how far you dropped this frame, which the fish undo — so a fish stays
    # where it was in the water and you go past it, instead of a shoal riding down on your
    # shoulder. Swim down far enough and they are gone over the top; come back up and
    # there are different ones. +surface+ is where the top of the sea is on screen, so a
    # fish coming back round from below arrives under it rather than in the sky.
    def update(sank, surface)
      @fish.each do |fish|
        fish.x += fish.speed
        fish.y -= sank
        if fish.speed > 0
          fish.face :right
        else
          fish.face :left
        end
        fish.x = -SIZE if fish.x > SCREEN_W
        fish.x = SCREEN_W if fish.x < -SIZE
        fish.y = surface if fish.y > SCREEN_H # you came up past this one
        fish.y = SCREEN_H if fish.y < -SIZE   # you went down past it
        fish.draw_with SPECIES, showing: fish.kind
      end
    end

    private

    def declare_art
      # The picture's own list is what `draw_with` swaps against, place for place, so it
      # has to be said here even though the art names its colours as characters too.
      @build.image(:fish_right, "." => :transparent, "#" => Ink::FISH_BODY, "o" => Ink::FISH_EYE,
                                colors: [:transparent, Ink::FISH_BODY, Ink::FISH_EYE]) { BODY }

      Ink::SHOAL.each { |name, shades| @build.colors name, [:transparent, *shades] }
    end
  end
end
