# frozen_string_literal: true

module VBlank
  module DSL
    # Edges and overlaps
    #
    # A sprite and a box both know their four edges, `left`, `top`, `right` and `bottom`, so
    # both can be asked whether they overlap something and whether they have left the screen.
    # A sprite's edges come from its place and its collision box, which by default is the
    # rectangle round its visible pixels (see the `hitbox:` option of `sprite`), so
    # `hero.overlaps?(coin)` works with no boxes at all.
    #
    # ```ruby
    # score += 1 if hero.overlaps?(coin)
    # shot.hide if shot.above_top?
    # ```
    #
    # Each answer is a test, as a comparison is, so write it after `if` or join it with `&&`
    # and `||`.
    #--
    # The rectangle-bounds contract for collision: anything that answers the four edges and
    # `collision_builder` can mix this in and gains these tests. It stays a rectangle test;
    # PixelBounds adds the per-pixel half for sprites.
    #++
    module Bounds
      # Tests whether this thing's rectangle overlaps another's, the collision test a game makes
      # every frame.
      #
      # Edges that only touch count as a hit. `other` is anything with four edges: another
      # sprite, a Box, or a handle of your own that answers `left`, `top`, `right` and `bottom`.
      # Two sprites that are both drawn per pixel (neither given a `hitbox:`) are then also
      # tested pixel by pixel, so the hit is where their drawn pixels meet.
      #
      # ```ruby
      # score += 1 if hero.overlaps?(coin)
      # ```
      #--
      # Two rectangles touch when, on each axis, neither starts past where the other ends.
      #++
      def overlaps?(other)
        left <= other.right && other.left <= right && top <= other.bottom && other.top <= bottom
      end

      # --- where am I relative to the screen ---
      #
      # Common "has it left the screen" tests, read from this rectangle's own edges and
      # the screen size — so game code needs no coordinate literals or sprite-size math.
      # "Off an edge" means fully past it — nothing of the rectangle still shows there —
      # so a thing sliding half off a side isn't off_screen? yet. The screen is the one the
      # game is being built for (see Builder#console), asked of `collision_builder`, which
      # everything mixing this in answers; a rectangle's right/bottom read one past its
      # last pixel (see Box), so the edge tests below are written to match.

      # Tests whether this thing is wholly past the left edge of the screen, with nothing of it
      # still showing.
      #
      # ```ruby
      # enemy.hide if enemy.off_left?
      # ```
      def off_left?
        right <= 0
      end

      # Tests whether this thing is wholly past the right edge of the screen, with nothing of it
      # still showing.
      def off_right?
        left >= collision_builder.console.screen_width
      end

      # Tests whether this thing is wholly above the top of the screen, with nothing of it still
      # showing.
      #
      # ```ruby
      # shot.hide if shot.above_top?   # a shot flew off the top
      # ```
      def above_top?
        bottom <= 0
      end

      # Tests whether this thing is wholly below the bottom of the screen, with nothing of it
      # still showing.
      def below_bottom?
        top >= collision_builder.console.screen_height
      end

      # Tests whether this thing is wholly off the screen past any edge. A thing half off a side
      # is not off the screen yet.
      #
      # ```ruby
      # rock.move_to 120, 0 if rock.off_screen?
      # ```
      def off_screen?
        off_left? || off_right? || above_top? || below_bottom?
      end
    end
  end
end
