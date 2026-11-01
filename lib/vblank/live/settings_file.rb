# frozen_string_literal: true

module VBlank
  module Live
    # WHERE A PLAYER'S SETTINGS ARE KEPT (Settings says what is in them), found as the desktop build
    # finds them, so the two share them: settings.txt in the folder the operating system keeps for
    # "vblank" and each person — one folder every game shares, "(all games)", and one for each
    # game, named from its title. The shared file is read first; a game that has a file of its own
    # has that read over it, and then keeps only what that file says and what changes while it
    # plays, so a change to the shared file still reaches it. Changes are written where the player
    # last looked: the game's own file when it has one, the shared one when not.
    #
    # A file named for the play (--settings-file) is the only one there is, and holds every setting.
    # A folder named for the play (--config-dir) takes the place of the usual one.
    class SettingsFile
      SHARED_FOLDER = "(all games)"
      NAME = "settings.txt"

      # The file being written to, or nil when there is none to write.
      attr_reader :path

      # +title+, the game's; +asked+, the one file to use, or nil for the usual ones; +folder_of+,
      # given a folder's name, the path of that folder in the operating system's place for vblank
      # (made if it is not there), or nil when it cannot be made.
      def initialize(title:, folder_of:, asked: nil)
        @title = title
        @folder_of = folder_of
        @asked = asked
        @own_only = false
      end

      # The settings in the file or files, read over +settings+: gives what could not be used, a
      # sentence to a line, each file's sentences under its name. A file that is not there is no
      # problem: a player who has never changed anything has none.
      def load(settings)
        said = []
        if @asked
          @path = @asked
          read(@asked, settings, said)
        else
          shared = file_in(SHARED_FOLDER)
          own = file_in(self.class.folder_named(@title))
          read(shared, settings, said) if shared
          if own && File.exist?(own)
            settings.mark_inherited
            read(own, settings, said)
            @own_only = true
          end
          @path = @own_only ? own : shared
        end
        said
      end

      # The settings written to the file, as the save is: to a new file beside it, which then takes
      # its place, so a write cut short never leaves half a file. Gives an error message when it
      # could not be written, or nil.
      def write(settings)
        if @path
          writing = "#{@path}.writing"
          File.binwrite(writing, settings.text(own_only: @own_only)) # its own line endings, on Windows too
          File.rename(writing, @path)
        end
        settings.mark_written
        nil
      rescue SystemCallError => e
        "#{@title} cannot write its settings to #{@path} (#{e.message})"
      end

      # The folder that holds the settings folders, or nil for leaving it to the operating system's
      # own place: the one the player named, or vblank's folder in $XDG_CONFIG_HOME (+xdg+), which
      # must start from the root to count, or on Linux in the person's .config (+home+). This is
      # rg_settings_root.h's rule, held to the same table, since the two share these files.
      def self.root(config_dir:, xdg:, home:, linux:)
        return config_dir if config_dir && !config_dir.empty?
        return File.join(xdg, "vblank") if xdg&.start_with?("/")

        File.join(home, ".config", "vblank") if linux && home && !home.empty?
      end

      # A game's folder: its title, with anything but a letter, a digit or a space made a _, and
      # "game" for a title with nothing left.
      def self.folder_named(title)
        name = title.to_s.gsub(/[^A-Za-z0-9 ]/, "_")[0, 63]
        name.empty? ? "game" : name
      end

      private

      def file_in(folder)
        base = @folder_of.call(folder) or return nil
        File.join(base, NAME)
      end

      def read(path, settings, said)
        return unless File.exist?(path)

        problems = settings.read(File.read(path, encoding: Encoding::UTF_8))
        said.concat(["#{path}:", *problems]) unless problems.empty?
      rescue SystemCallError => e
        said << "The window cannot read #{path} (#{e.message}), so the settings are as they start."
      end
    end
  end
end
