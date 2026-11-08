# frozen_string_literal: true

module VBlank
  module IR
    # WHERE A BACKGROUND'S STATE IS KEPT, so anything reading a running game asks for it by the
    # game's name (`player.background(:sky).scroll_x`) rather than by the hidden variables the
    # build made for it (__bg_sky_sx). The build writes one for each background on the program
    # (Program#background_readings), as it does a sprite's (SpriteReading).
    #
    # +scroll_x+ and +scroll_y+ name the variables its scroll is kept in, in pixels.
    # +shown_map+ names the one holding which of +maps+ (the map names, in the order they were
    # declared) the game has set showing, and is nil for a background of one map.
    BackgroundReading = Data.define(:name, :scroll_x, :scroll_y, :shown_map, :maps) do
      # The background as it stands, read from +reader+'s stored numbers (IR::ReadingByName#raw_var).
      def state_from(reader)
        BackgroundState.new(name: name, scroll_x: reader.raw_var(scroll_x), scroll_y: reader.raw_var(scroll_y),
                            map: shown_map ? maps.fetch(reader.raw_var(shown_map)) : maps.first)
      end
    end

    # A background read back: how far it is scrolled across and down, and the name of the map
    # the game has set showing. A map set with `show_map` shows from the next frame on, so +map+
    # is the one the game asked for, which the picture shows a frame later.
    BackgroundState = Data.define(:name, :scroll_x, :scroll_y, :map)
  end
end
