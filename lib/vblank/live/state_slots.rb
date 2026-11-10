# frozen_string_literal: true

module VBlank
  module Live
    # THE PLACES A GAME'S SAVE STATES ARE KEPT IN, as the window's menu shows them: the quick one and
    # slots 1 to 10, a file each in one folder (state-quick, state-1 ... state-10). The desktop build
    # keeps the same files the same way (rg_sdl.c), so a state saved there is in the menu here.
    #
    # The folder is named from the game's title and its code (+folder_name+), so two games with one
    # title do not write over each other's states. A state in a slot that a rebuilt game cannot read
    # is not hidden: the runtime refuses it in plain words when it is loaded.
    class StateSlots
      QUICK_FILE = "state-quick"

      # The folder's name for a game: the title, with each character a folder's name cannot hold
      # (anything but a letter, a digit or a space) written as an underscore, then the game's code.
      # rg_sdl.c's name_state_folder does the same.
      def self.folder_name(title:, code:)
        name = title.to_s.gsub(/[^A-Za-z0-9 ]/, "_")
        name = "game" if name.empty?
        "#{name} #{code}"
      end

      # What the menu says for a slot that holds nothing.
      EMPTY = "Empty"

      # A state that cannot be written, in words for the player.
      class CannotWrite < StandardError; end

      def initialize(folder:)
        @folder = folder
      end

      # Words for slot +slot+: "Empty", or the day and minute the state in it was taken, as the
      # computer's clock then read.
      def text_for(slot)
        path = path_of(slot)
        return EMPTY unless File.file?(path)

        File.mtime(path).strftime("%Y-%m-%d %H:%M")
      end

      # Keeps +text+ (a state) in +slot+: written to a new file beside it, which then takes its
      # place, so a state that cannot be written leaves the one before whole. Raises CannotWrite, in
      # words for the player, when the file cannot be written.
      def write(slot, text)
        path = path_of(slot)
        writing = "#{path}.writing"
        File.binwrite(writing, text)
        File.rename(writing, path)
      rescue SystemCallError => e
        raise CannotWrite, "The state cannot be written to #{path} (#{e.message})."
      end

      # The state in +slot+, or nil when it holds none.
      def read(slot)
        path = path_of(slot)
        File.binread(path) if File.file?(path)
      rescue SystemCallError
        nil
      end

      private

      def path_of(slot) = File.join(@folder, slot.zero? ? QUICK_FILE : "state-#{slot}")
    end
  end
end
