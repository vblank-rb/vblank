# frozen_string_literal: true

module VBlank
  module Live
    # THE FILE A GAME'S SAVE MEMORY IS KEPT IN between runs of vblank run: save.sav in the folder the
    # window keeps the game's states in (StateSlots.folder_name), as the desktop build keeps save.sav in
    # the game's folder. It holds the bytes of the game's save memory and nothing else, so a file of
    # any other size is another game's, or damaged.
    class SaveFile
      NAME = "save.sav"

      # A file that is there and is not as big as the game's save memory, said in plain words: the game
      # does not start, since carrying on would write over somebody's file.
      class NotThisGamesSave < StandardError; end

      # A save that cannot be written, in words for the player.
      class CannotWrite < StandardError; end

      def initialize(folder:)
        @path = File.join(folder, NAME)
      end

      attr_reader :path

      # The bytes the last run left (a String), or nil when there is no file: a new cartridge. Raises
      # NotThisGamesSave when the file is not +size+ bytes.
      def read(size)
        return nil unless File.file?(@path)

        bytes = File.binread(@path)
        return bytes if bytes.bytesize == size

        raise NotThisGamesSave, "The file at #{@path} is not a save of this game, whose save is #{size} bytes. " \
                                "Move the file away, and the game starts a new one."
      end

      # +bytes+ written to a new file beside the save, which then takes its place, so a run stopped part
      # way through leaves the old file whole. Raises CannotWrite, in words for the player.
      def write(bytes)
        writing = "#{@path}.writing"
        File.binwrite(writing, bytes)
        File.rename(writing, @path)
      rescue SystemCallError => e
        raise CannotWrite, "The save cannot be written to #{@path} (#{e.message})."
      end
    end
  end
end
