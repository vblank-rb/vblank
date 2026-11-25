# frozen_string_literal: true

module VBlank
  module Original
    # The progress bar a shell shows while it unpacks: a routine of the unpacking's
    # (Unpacking::PROGRESS), called before every wait for the next frame (CopyReader), drawing a bar
    # as far along as +done+ (Builder's UnpackingBytes or UnpackingWork) says, and the whole bar once
    # +finished+ is 1. Game code, so every runtime draws it, and the interpreter is its answer key.
    #
    # The screen is painted only when the bar's width changes. The routine waits every few hundred
    # bytes, hundreds of thousands of times for a port's music, and the bar moves a pixel only every
    # few thousand of them; clearing the screen and painting the words and the bar again at each wait
    # was a large share of a fast runtime's unpacking. The screen is a plain one (`screen :bitmap`),
    # which keeps its one picture from frame to frame, so a bar left alone shows as it was painted.
    #
    # This file is read as game code (VBlank.require_game_file), so its `if` is a branch in the
    # routine.
    class UnpackingProgress
      # Where the bar is, in pixels from the screen's edges, and how tall it is.
      SIDE = 16
      HEIGHT = 8
      # The colours of the bar's done part and of the rest.
      FILLED = :white
      EMPTY = :gray

      # +maker+ is the unpacking's builder. The width the bar was last painted at is a variable of
      # the building blocks' (Unpacking::PAINTED_WIDTH), -1 before the first paint.
      def initialize(maker)
        @maker = maker
        @painted_width = maker.var(Unpacking::PAINTED_WIDTH, -1)
      end

      # The routine, defined on the builder.
      def define(done, finished)
        across = @maker.screen_width - (2 * SIDE)
        top = (@maker.screen_height - HEIGHT) / 2
        @maker.screen :bitmap
        @maker.func(Unpacking::PROGRESS) do
          shown = (done.pixels_shown(across) + (finished * across)).clamp(0, across)
          if shown != @painted_width
            @maker.clear_screen :black
            @maker.draw_text "UNPACKING", :center, top - 16, :white
            @maker.fill_rect SIDE, top, across, HEIGHT, EMPTY
            @maker.draw_rect_at SIDE, top, shown, HEIGHT, FILLED
            @painted_width.store!(shown)
          end
        end
      end
    end
  end
end
