# frozen_string_literal: true

module VBlank
  module Diagnostics
    # IS HALF THE DRAWING BEING LOST? Measured, on a real run, rather than estimated.
    #
    # THE FOOTGUN THIS IS ABOUT, and it is the tear-free screen's own. That screen keeps
    # TWO pictures and shows them in turn: the program draws into the one nobody is looking
    # at, and they trade places between frames. That is what stops a player ever seeing a
    # half-drawn picture. The price is that a frame's drawing lands on ONE of the two.
    #
    # A program that repaints everything every frame never notices, because both pictures
    # end up complete. A program that ADDS to what is already there — a dissolve, a trail
    # behind something moving, a plot filling in, a map uncovering itself — puts half its
    # additions in each picture. The screen then alternates between two half-finished
    # pictures, sixty times a second. What the player sees is flicker, and nothing on
    # screen explains it: the program looks right, and every dot it drew really was drawn.
    #
    # THIS IS THE EXACT COMPLEMENT OF {Tearing}. That one asks whether a game drawing into
    # the single picture the display is reading got caught halfway; it applies only to a
    # direct-color screen and shows it. This one applies only to a tear-free screen. A game
    # has one screen or the other, so exactly one of the two questions can be asked of it,
    # and neither is ever asked where it has no meaning.
    #
    # HOW IT IS MEASURED, and why nothing has to track writes. Take the picture on screen
    # just after each of four page swaps running: the two pictures in turn, then the two
    # again. Four, not two: only one picture is drawn into per pass, so two swaps show each
    # picture once and nothing about whether it changed. Over four each has had its turn. A
    # pixel where the two pictures DISAGREE and NEITHER of them changed is a pixel no pass is
    # going to fix — the disagreement is permanent, and the player is watching it flicker.
    #
    # AT A SWAP, NOT A FIXED NUMBER OF FRAMES APART. A pass can take several frames, and the
    # picture being drawn sits half finished for all of them; read then, it disagrees with the
    # one on screen and holds still, though the player never sees it. Only a picture just put
    # on screen is one the player sees (Profiler.flicker_in).
    #
    # WHAT THAT RULES OUT, which is the whole reason it is measured rather than read off
    # the program:
    #
    #   - a game that repaints every frame: each picture changes, so nothing is flagged;
    #   - a game whose picture is still: the two pictures agree, so nothing is flagged;
    #   - a game that repaints only PART of the screen and handles the rest properly —
    #     `keep_showing` paints a change into both pictures, so they converge and nothing
    #     is flagged. A build-time check cannot tell that apart from the broken version,
    #     because the difference is how many frames an op runs on.
    #
    # WHAT IT CANNOT TELL APART. A game that deliberately alternates a picture every
    # single frame reads exactly like this one, because the check compares values and a
    # deliberate alternation leaves the same value in each picture. That is rare — a blink
    # is usually counted in tens of frames, not one — and this reports rather than raises,
    # so the cost of being wrong is a line to ignore.
    #
    # AN ADVANCE CARTRIDGE'S ALONE. It reads what the Advance's build and hardware keep, and only
    # Cartridge::ROM and the Advance's Profiler reach it; a Color cartridge's profile is GBCProfiler's.
    module Flicker
      # WHAT A RUN SAW. +pixels+ is how many are stuck disagreeing between the two
      # pictures with nothing coming to fix them — 0 for a game whose drawing all arrives.
      # +first+ is where to look, as [x, y], so a person has somewhere to start. A reading
      # that does not apply to this screen shows it with #measured? false, so "we did not
      # look" can never be mistaken for "nothing was wrong".
      Reading = Data.define(:pixels, :first) do
        def self.none = new(pixels: nil, first: nil)

        def measured? = !pixels.nil?
        def losing? = measured? && pixels.positive?
      end

      # How many pixels have to be stuck before it is worth saying. One or two can come of
      # a game that draws a single pixel and leaves it, which is odd but harmless; a lost
      # dissolve or trail is thousands. This sits well below anything a real effect makes
      # and well above a stray.
      FLOOR = 16

      module_function

      # Whether this question can be asked of the screen this program runs. A tear-free
      # screen keeps two pictures, so it can lose half a drawing; every other screen keeps
      # one and cannot. The mirror of {Tearing.measurable?}, and the two never both hold.
      def measurable?(program)
        IR::Modes.resolve(program).any_buffered?
      end

      # THE RULE, and it is the whole of this module: given both pictures, and both again
      # two page swaps later, which pixels are stuck?
      #
      # Each snapshot is a pair of flat, row-major pictures in a FIXED order — the same
      # picture first in both snapshots. Which of the two the display happens to be showing
      # does not matter here; what matters is that a picture is
      # compared against itself.
      def read(before, after, width: Console::ADVANCE.screen_width)
        first_a, second_a = before
        first_b, second_b = after

        stuck = (0...first_a.length).select do |i|
          first_a[i] != second_a[i] && first_a[i] == first_b[i] && second_a[i] == second_b[i]
        end
        return Reading.new(pixels: 0, first: nil) if stuck.length < FLOOR

        at = stuck.first
        Reading.new(pixels: stuck.length, first: [at % width, at / width])
      end
    end
  end
end
