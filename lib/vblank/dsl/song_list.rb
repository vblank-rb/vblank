# frozen_string_literal: true

module VBlank
  module DSL
    # A list of songs
    #
    # The game's music, played by name or by number. `songs` hands one back.
    #
    # ```ruby
    # music = songs :music, [title_theme, file_select, forest]
    # music.play 0          # the title theme
    # music.play track      # whichever song a number the game keeps names
    # music.stop
    # ```
    #
    # Playing works the way `play_song` does: it sets which song plays now. Naming the song
    # already playing changes nothing, and naming another starts that one from its first note.
    # A number the game works out that names no song leaves the music as it is, the same as
    # `show_map` with a number that names no map.
    class SongList
      include ScoreList

      # Plays a song of the list, and returns the list so calls chain.
      #
      # ```ruby
      # music.play :forest
      # music.play level, this_frame: true
      # ```
      #
      # * `which` - the song: a name the list was given, a number counting from 0, or a number the
      #   game works out as it runs.
      # * `this_frame:` - true to start the song here rather than on the next frame, as with
      #   `play_song`.
      # * `sent_after_rows:` - the screen row the request is sent at, as with `play_song`.
      def play(which, this_frame: false, sent_after_rows: nil)
        @builder.play_from_list(@name, entry_number(which), this_frame: this_frame, sent_after_rows: sent_after_rows)
        self
      end

      # Stops the music, the same as `stop_music`, and returns the list.
      #
      # ```ruby
      # music.stop
      # ```
      def stop
        @builder.stop_music
        self
      end

      private

      def entry_noun = "song"
    end
  end
end
