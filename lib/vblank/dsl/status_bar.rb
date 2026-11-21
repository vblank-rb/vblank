# frozen_string_literal: true

module VBlank
  module DSL
    # A status bar
    #
    # `status_bar :score, ...` hands one back: a strip of tiles fixed to the screen from its top
    # row down to the bottom, over a field that scrolls under it.
    #
    # ```ruby
    # bar = status_bar :score, tiles: :hud, map: SCORE_BAR, top: screen_height - 16
    # game_loop do
    #   bar.move_to bar.top + 3      # slides down, a few rows a frame, until it is out of view
    #   bar.set_tile 5, 0, "7"       # a digit of the score changes
    # end
    # ```
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

      # The name the bar was declared with.
      attr_reader :name

      # Puts the bar's top at screen row `row`, which may be a number the game works out.
      #
      # The bar covers the screen from there to the bottom, so a row at the bottom of the screen
      # or past it puts the whole bar out of view, and a row above the top is the top. As a
      # scroll does, it shows from the gap between frames, so a game can set it anywhere in a
      # frame, as many times as it likes, and the picture never shows the bar in two places.
      #
      # ```ruby
      # bar.move_to screen_height - 16
      # ```
      def move_to(row)
        self.top = row
        @builder.record_inline_bar_node(@builder.record_statement(Build.place_bar(@name, top: Build.var_ref(@top_var))))
        self
      end

      # Hides the sprites under the bar when given true, and shows them again when given false.
      #
      # That suits a menu brought up over the field, where the bar in play lets a ball show over
      # it. While it covers, no sprite shows from the bar's top to the bottom of the screen, and a
      # sprite partly above the top shows its part above. As a move does, it shows from the gap
      # between frames, so a bar moved and told to cover in one pass does both on one frame.
      #
      # ```ruby
      # bar.covers_sprites = true
      # ```
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

      # The screen row the bar's top is at, as the game last set it, as a Value.
      def top = Value.new(@builder, Build.var_ref(@top_var), name: @top_var)

      # Puts a different tile in one cell of the bar: a digit of the score, a heart lost.
      #
      # It works as Background#set_tile does: `col` and `row` are cells of the bar's map, and the
      # tile is named the way the map was written. A change shows on the frame after the pass
      # that made it, with the rest of the pass's picture.
      #
      # ```ruby
      # bar.set_tile 5, 0, "7"
      # ```
      #
      # * `now:` - true shows the change on the frame being drawn, as a menu in the bar wants
      #   when it answers a press: the screen is drawn from the top, so rows it has not reached
      #   yet show the change. Each such cell waits for moments the display is not reading, so it
      #   is for a few cells, not a whole bar.
      def set_tile(col, row, tile, now: false)
        unless [true, false].include?(now)
          raise ArgumentError, "`now:` is #{now.inspect}. It must be true or false."
        end

        @background.set_tile(col, row, tile, now: now || nil)
        self
      end

      # Refuses, saying why: a status bar is not held to a box as a background is
      # (Background#show_only_inside).
      #
      # A bar always shows from its top row to the bottom of the screen. Move it with #move_to.
      #--
      # The console uses the part of its display that would hold the box to hold the bar's rows.
      #++
      def show_only_inside(*) = refuse_box!("show_only_inside")

      # Refuses, saying why, as #show_only_inside does: a status bar has no box to set aside.
      def show_everywhere = refuse_box!("show_everywhere")

      # Shows another of the bar's maps, for a bar declared with several.
      #
      # The whole bar changes in one call, which is how a game clears a message that is too many
      # cells to change with #set_tile in one pass: give the bar an empty map and show it. Cells
      # changed with #set_tile before this are forgotten. Cells changed after it, in the same pass
      # too, show over the new map. Showing the map that is up already changes nothing.
      #
      # ```ruby
      # bar.show_map :empty
      # bar.set_tile 1, 0, "!"
      # ```
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
