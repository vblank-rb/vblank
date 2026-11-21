# frozen_string_literal: true

module VBlank
  module DSL
    # Tiles the game paints itself
    #
    # `tiles :box, from: list, count: n` hands one back: a run of tiles whose pixels live in the
    # game's own list.
    #
    # Writing into the list changes nothing on screen by itself, because the screen draws its
    # tiles out of video memory, not out of the list. #changed asks for the list to be copied
    # there in the gap before the next frame, so the player never sees a picture half copied.
    #
    # ```ruby
    # box = tiles :box, from: pixels, count: 24
    # game_loop do
    #   type_next_letter
    #   box.changed
    # end
    # ```
    class TileRun
      # The name the tiles were declared with.
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # Shows the list's pixels on the next frame.
      #
      # Saying it several times in one frame is still one copy, and saying it every frame copies
      # every frame, which is what a box typing a letter a frame wants.
      #
      # * `now:` - true copies the pixels where the line is, inside the frame's own work, so they
      #   show on this frame: a letter typed on the frame the button was read. The price is that
      #   the console may be drawing the screen while the copy is made, so for one frame the top
      #   of the picture can be old and the bottom new.
      #--
      # The Color locks its video memory while it draws, so its lowering packs the list here and
      # puts it in between frames, in time for the same picture.
      #++
      def changed(now: false)
        now ? @builder.emit_tile_copy_in_place(@name) : @builder.request_tile_copy(@name)
        nil
      end
    end
  end
end
