# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module VBlank
  module Live
    # THE GAMES vblank run HAS WRITTEN OUT, KEPT TO BE PLAYED AGAIN. A big game takes many seconds to
    # build and a fraction of one to play from its written file, so the file a helper wrote
    # (BuildHelper) is kept, with a record of everything its build read (BuildInputs), and the next
    # launch plays it with no build at all while the record still holds.
    #
    # A KEPT GAME IS CURRENT while it was built from the same game file, launched from the same
    # working folder, for the same console and --set values, by the same VBlank and gems
    # (#library_key) on the same Ruby; everything the build read is as it was; and the written game
    # is the one its build kept (its digest is in the record). Anything else builds again, and the
    # new build takes its place. The record is written by the build that did the reading, after
    # the game is written, so a build that stopped part way leaves nothing current.
    #
    # WHERE: one folder for each game file, working folder, console and set of settings, under the
    # root (#root): the folder VBLANK_WRITTEN_GAMES names, else the computer's own place for files
    # a program can make again (~/Library/Caches/vblank/written-games on a Mac,
    # $XDG_CACHE_HOME/vblank/written-games or ~/.cache/vblank/written-games elsewhere). A written
    # game can hold an original's data, as a shell's pack folder does, so each game's folder and
    # its files are its owner's alone (0700 and 0600), and so is the root when this makes it. A
    # kept game anyone else could have changed is never played.
    class WrittenGames
      FORMAT = 2 # The record's own layout; a record of another is not read

      FOLDER_MODE = 0o700
      FILE_MODE = 0o600
      OTHERS_WRITE = 0o022 # The group's and everyone's write bits

      # What a build is by the library: the digest of every file of VBlank's library, and every gem
      # loaded, each "name version".
      LibraryKey = Data.define(:digest, :gems) do
        def to_plain = { "digest" => digest, "gems" => gems }
      end

      # The root written games are kept under, as #initialize takes it.
      def self.root(env: ENV, home: Dir.home, mac: RUBY_PLATFORM.include?("darwin"))
        return env["VBLANK_WRITTEN_GAMES"] if env["VBLANK_WRITTEN_GAMES"].to_s != ""

        caches = if mac then File.join(home, "Library", "Caches")
                 elsif env["XDG_CACHE_HOME"].to_s != "" then env["XDG_CACHE_HOME"]
                 else File.join(home, ".cache")
                 end
        File.join(caches, "vblank", "written-games")
      end

      # The LibraryKey of this process: worked out once by the command and handed to its helper.
      def self.library_key = LibraryKey.new(digest: library_digest, gems: Gem.loaded_specs.values.map { |spec| "#{spec.name} #{spec.version}" }.sort)

      # A digest of every file of the library under +lib+, by its place and contents: a build by
      # another VBlank is never taken for this one's.
      def self.library_digest(lib = VBlank.root.join("lib").to_s)
        Dir.glob(File.join(lib, "**", "*")).select { |path| File.file?(path) }.sort
           .each_with_object(Digest::SHA256.new) { |path, digest| digest << path.delete_prefix(lib) << "\0" << File.binread(path) }
           .hexdigest
      end

      def initialize(root) = @root = root

      # The place a build of the game in +game_file+, launched from +working_folder+, for +console+,
      # told +settings+, is kept.
      def slot(game_file:, console:, settings:, working_folder: Dir.pwd)
        game_file = File.expand_path(game_file)
        identity = JSON.generate([game_file, File.expand_path(working_folder), console.to_s, settings.sort.to_h])
        name = "#{File.basename(game_file, '.rb').gsub(/[^A-Za-z0-9_-]/, '_')}-#{Digest::SHA256.hexdigest(identity)[0, 16]}"
        Slot.new(File.join(@root, name))
      end

      # ONE KEPT GAME: its folder holds the written game (game.rb) and the record of its build
      # (record.json), the record written last.
      class Slot
        attr_reader :folder

        def initialize(folder) = @folder = folder

        def script_path = File.join(@folder, "game.rb")
        def record_path = File.join(@folder, "record.json")

        # Where this process's build writes the game before it is kept (#keep): a name of its own, so
        # two builds at once never write into one file.
        def writing_path = File.join(@folder, "game.rb.#{Process.pid}.writing")

        # Whether the game kept here can be played as it is: built for +console+ and +settings+ by
        # the library whose LibraryKey is +library+, on this Ruby, from everything as it is now; the
        # very file its build kept; and no one else able to have changed it. With +match+, it must
        # hold what a match needs to know of the game too (Ruby#build_script's +match+), which a
        # build writes in only when asked.
        def current?(console:, settings:, library:, match: false)
          return false unless File.file?(script_path) && File.file?(record_path) && owners_alone?

          record = JSON.parse(File.read(record_path))
          (!match || record["match"] == true) &&
            record["format"] == FORMAT && record["console"] == console.to_s && record["settings"] == plain_settings(settings) &&
            record["ruby"] == RUBY_VERSION && record["library"] == library.to_plain &&
            record["game"] == Digest::SHA256.file(script_path).hexdigest &&
            BuildInputs.from_plain(record.fetch("inputs")).current?
        rescue JSON::ParserError, KeyError
          false
        end

        # Ready for a build: the folder made, its owner's alone (the root too, when this makes it),
        # and the record of the last build gone, so nothing here is current until the new build is
        # kept.
        #
        # A game left half written by a build whose process has gone is taken away; one another
        # build is writing now is left alone.
        def prepare
          FileUtils.mkdir_p(@folder, mode: FOLDER_MODE)
          File.chmod(FOLDER_MODE, @folder)
          FileUtils.rm_f(record_path)
          Dir.glob(File.join(@folder, "*.writing")).each do |left|
            FileUtils.rm_f(left) unless writer_alive?(left[/\.(\d+)\.writing\z/, 1].to_i)
          end
        end

        # The game this process's build wrote to #writing_path kept, with what the build read
        # (+inputs+, a BuildInputs) and what it was built for; +match+ when the game holds what a
        # match needs to know of it.
        def keep(inputs, console:, settings:, library:, match: false)
          File.chmod(FILE_MODE, writing_path)
          game = Digest::SHA256.file(writing_path).hexdigest
          File.rename(writing_path, script_path)
          record = { "format" => FORMAT, "console" => console.to_s, "settings" => plain_settings(settings),
                     "ruby" => RUBY_VERSION, "library" => library.to_plain, "game" => game, "match" => match,
                     "inputs" => inputs.to_plain }
          writing = "#{record_path}.#{Process.pid}.writing"
          File.open(writing, "w", FILE_MODE) { |file| file.write(JSON.generate(record)) }
          File.rename(writing, record_path)
        end

        private

        def plain_settings(settings) = settings.to_h { |name, value| [name.to_s, value.to_s] }.sort.to_h

        # Whether the process numbered +pid+ is running (0 for a name with no number: not running).
        def writer_alive?(pid)
          return false unless pid.positive?

          Process.kill(0, pid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true # running, as another user
        end

        # Whether the folder and the game are this user's, and no one else can write to them.
        def owners_alone?
          [@folder, script_path].all? do |path|
            stat = File.stat(path)
            stat.owned? && (stat.mode & OTHERS_WRITE).zero?
          end
        end
      end
    end
  end
end
