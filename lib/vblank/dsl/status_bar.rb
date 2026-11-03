# frozen_string_literal: true

module VBlank
  module DSL
    # A handle to a status bar, which `status_bar :score, ...` hands back: a strip of tiles fixed
    # to the screen from its top row down to the bottom, over a field that scrolls under it.
    #
    #   bar = status_bar :score, tiles: :hud, map: SCORE_BAR, top: screen_height - 16
    #   game_loop do
    #     bar.move_to bar.top + 3      # slides down, a few rows a frame, until it is out of view
    #     bar.set_tile 5, 0, "7"       # a digit of the score changes
    #   end
    #
    # It never scrolls: where it sits is its top row, and nothing else.
    class StatusBar
      Build = IR::Build

      # Built by the `status_bar` verb.
      #
      # @param builder [Builder] the build these operations record into
      # @param name [Symbol] the bar
      # @param top_var [Symbol] the hidden variable its top row is kept in
      # @param background [Background] the background it is drawn as, whose cells `set_tile`
      #   changes
      def initialize(builder, name:, top_var:, background:)
        @builder = builder
        @name = name
        @top_var = top_var
        @background = background
      end

      attr_reader :name

      # PUT THE BAR'S TOP AT SCREEN ROW +row+, which may be something the game works out. The
      # bar covers the screen from there to the bottom, so a row at the bottom of the screen or
      # past it puts the whole bar out of view, and a row above the top is the top.
      #
      # Like a scroll, it is shown from the gap between frames, so a game can say it anywhere
      # in a frame, as many times as it likes, and the picture never shows the bar in two
      # places at once.
      def move_to(row)
        self.top = row
        @builder.record_inline_bar_node(@builder.record_statement(Build.place_bar(@name, top: Build.var_ref(@top_var))))
        self
      end

      # HIDE THE SPRITES UNDER THE BAR, or show them again: for a menu brought up over the field,
      # where the score bar in play lets the ball show over it. With +covers+ true no sprite shows
      # from the bar's top to the bottom of the screen, and a sprite partly above the top shows
      # its part above. Like a move, it is shown from the gap between frames, so a bar moved and
      # told to cover in one pass does both on one frame.
      def covers_sprites=(covers)
        unless [true, false].include?(covers)
          raise ArgumentError, "`covers_sprites =` was given #{covers.inspect}. It must be true or false."
        end

        covers_var = @builder.bar_covers_var(@name)
        @builder.record_statement(Build.set(covers_var, Build.int(covers ? 1 : 0)))
        @builder.record_inline_bar_node(@builder.record_statement(
                                          Build.place_bar(@name, top: Build.var_ref(@top_var), covers: Build.var_ref(covers_var))
                                        ))
      end

      # The row the bar's top is at, as the game last said it, as a {Value}.
      def top = Value.new(@builder, Build.var_ref(@top_var), name: @top_var)

      # PUT A DIFFERENT TILE IN ONE CELL OF THE BAR: a digit of the score, a heart lost. The
      # same as a background's `set_tile`: +col+ and +row+ are cells of the bar's map, and the
      # tile is named the way the map was written.
      #
      # A change shows on the frame after the pass that made it, with the rest of the pass's picture.
      # +now+ shows it on the frame being drawn, as a menu in the bar wants when it answers a press:
      # the screen is drawn from the top, so rows it has not reached yet show the change. Each such
      # cell waits for moments the display is not reading, so it is for a few cells, not a whole bar.
      def set_tile(col, row, tile, now: false)
        unless [true, false].include?(now)
          raise ArgumentError, "`now:` is #{now.inspect}. It must be true or false."
        end

        @background.set_tile(col, row, tile, now: now || nil)
        self
      end

      # A BAR IS NOT HELD TO A BOX. It is already held to the rows from its top down, and the
      # console uses the part of its display that would hold the box for that.
      def show_only_inside(*) = refuse_box!("show_only_inside")
      def show_everywhere = refuse_box!("show_everywhere")

      # SHOW ANOTHER OF THE BAR'S MAPS, for a bar declared with several. The whole bar changes in
      # one call, which is how a game clears a message that is too many cells to change with
      # `set_tile` in one pass: give the bar an empty map and show it. Cells changed with
      # `set_tile` before this are forgotten. Cells changed after it, in the same pass too, show
      # over the new map. Showing the map that is up already changes nothing.
      def show_map(which)
        @background.show_map_now(which)
        self
      end

      private

      def refuse_box!(verb)
        raise ArgumentError,
              "status_bar :#{@name} cannot use #{verb}. A status bar always shows from its top row to the " \
              "bottom of the screen. To move it, use `move_to`. To show tiles only inside a box, declare them " \
              "with `background` and use `show_only_inside`."
      end
    end
  end
end
