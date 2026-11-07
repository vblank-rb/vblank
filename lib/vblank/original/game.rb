# frozen_string_literal: true

require "digest"
require "yaml"

module VBlank
  module Original
    # SOMETHING IS WRONG WITH THE PLAYER'S COPY OF THE ORIGINAL, or nothing sets where it is. The
    # message says what to set, so a caller that turns this into words for a person rescues this
    # one class.
    class CopyError < StandardError; end

    # NOTHING NAMES WHERE THE COPY IS: neither the setting nor the settings file names one. A fresh
    # clone of a game is like this. A build can carry on without the original's data; a test stops,
    # saying what to set (Testing#original_copy). Every other CopyError is a mistake to fix.
    class NotSet < CopyError; end

    # A COPY WAS NAMED AND CANNOT BE USED: nothing is there, it is the wrong length, its bytes are
    # no release the game knows, it is a release the game does not read, the game's probe refused
    # it, or the settings file that names it cannot be read.
    class WrongCopy < CopyError; end

    # ANOTHER PATH A GAME NAMES WAS NAMED AND CANNOT BE USED (Game#path): nothing is there, a file is
    # there where a folder is wanted or a folder where a file is, or the settings file that names it
    # cannot be read.
    class WrongPath < CopyError; end

    # A SHELL IS BUILT WITH NO COPY ON THE MACHINE, so a port whose code depends on what the copy
    # holds cannot be built as one. While the block runs, every Game answers NotSet whatever names a
    # copy (Shell.build turns that into the words naming the line that asked). Kept per Ractor, as
    # each core builds its own games.
    def self.without_copies
      before = Ractor.current[:vblank_copies_hidden]
      Ractor.current[:vblank_copies_hidden] = true
      yield
    ensure
      Ractor.current[:vblank_copies_hidden] = before
    end

    # Whether a shell is being built here now (Original.without_copies).
    def self.copies_hidden? = Ractor.current[:vblank_copies_hidden] == true

    # WHAT AN ORIGINAL FROM A COMPUTER NAMES AS ITS PLATFORM. Every other platform is a console's
    # name (Console::KITS), whose layouts its data is kept in (Slot).
    COMPUTER = :pc

    # The platform +platform+ names, as a Symbol: a console's name, or COMPUTER. Any other is refused.
    def self.platform_named(platform)
      named = platform.to_s.to_sym
      return named if named == COMPUTER || Console::KITS.key?(named)

      known = [*Console::KITS.keys, COMPUTER].map(&:inspect)
      raise ArgumentError, "The original names platform: #{platform.inspect}. An original is from #{known[..-2].join(', ')} " \
                           "or #{known.last}. Name the console it is for, or :#{COMPUTER} for a computer game."
    end

    # THE PLAYER'S COPY, ACCEPTED: where it is, the name of its release, its SHA-1 (nil for a
    # folder accepted by a probe, which has no one hash), and the platform of the original it is a
    # copy of (Game#platform).
    Copy = Data.define(:path, :release, :sha1, :platform) do
      def initialize(path:, release:, sha1:, platform: :gba) = super(path:, release:, sha1:, platform: Original.platform_named(platform))
    end

    # HOW ANOTHER PATH ON THIS MACHINE IS FOUND, the way the copy is: its environment variable, its
    # key in the settings file, whether it is a folder, and what it is, in words for a message
    # ("a checkout of the disassembly").
    PathSetting = Data.define(:setting, :key, :folder, :what) do
      def self.from(entry)
        entry = entry.transform_keys(&:to_sym)
        new(setting: entry.fetch(:setting), key: entry.fetch(:key).to_s, folder: entry.fetch(:folder, false), what: entry.fetch(:what))
      end

      def kind_words = folder ? "a folder" : "a file"
    end

    # WHAT A GAME MADE FROM AN ORIGINAL DECLARES ABOUT ITS COPY, and the one way to ask for it.
    #
    # No game made from a retail original may ship that original, so each one reads the copy the
    # player already owns. Every such game has to answer the same three questions before it reads a
    # byte: where is the copy, is it the right one, and what does a person do when it is not. A
    # wrong copy is the worst kind of mistake here, because it does not fail: it builds plausible
    # wrong pictures far downstream. So it is refused at the door, by name.
    #
    # WHAT THE GAME SUPPLIES:
    #
    #   title:          what to call the game in a message ("Space Pinball")
    #   setting:        the environment variable that names the copy (SPACE_PINBALL_ROM); it wins.
    #                   A relative path there is read from the folder the program runs in.
    #   settings_file:  the game's own YAML file, kept out of git, that names it as well. A relative
    #                   path in it is read from the file's folder. A committed file beside it, the
    #                   same name ending .example.yml, is the template the message points at.
    #   key:            the key in that file ("rom" unless set; "data" for a folder of files, say)
    #   not_set_help:   words of the game's own added to the message when nothing is set: what the
    #                   copy must hold, say
    #   env:            where the setting is looked up (ENV unless set; a test hands its own)
    #   platform:       the console the original is for (:gba unless set; :gbc, :snes, :genesis), whose
    #                   layouts a data pack's slots are read in, or :pc for a computer game (Slot)
    #
    # and one of two ways to accept the copy:
    #
    #   releases:   by digest. A decompilation's versions table as it is read from its file: each
    #               release by name ({"US" => {"sha1" => "9402...", "size" => 1048576}}), or a list
    #               of entries that name themselves ([{"name" => "USA", "sha1" => ...}]). Each has a
    #               SHA-1, and may have an MD5, a size, and "supported" => false for a release the
    #               game knows and does not read. A copy no release is the length of is refused
    #               unread. A copy of a release the game does not read is refused naming it.
    #   probe:      by its contents, for a copy that is a folder of files or has no one digest. It is
    #               called with the path and returns the release's name, or nil to refuse the copy.
    #               It may raise WrongCopy itself to say more.
    #
    # and, for a game that needs more of this machine than its copy (a decompilation's checkout and
    # the assembler that builds it, say), +paths+: each by a name of the game's choosing, with its
    # setting, its key in the same settings file, whether it is a folder, and what it is in words:
    #
    #   paths: { checkout: { setting: "ROCKET_DISASSEMBLY", key: "disassembly", folder: true,
    #                        what: "a checkout of the disassembly" } }
    #
    # Each is found by #path under the same rules as the copy and refused in the same kinds of error.
    class Game
      # Where a path was named: the path, and the setting or settings file that named it.
      Named = Data.define(:path, :named_in)

      attr_reader :title, :setting, :settings_file, :key

      # The platform the original is for: a console's name (:gba, :gbc, :snes, :genesis), whose
      # layouts its data is kept in, or COMPUTER. The Advance unless the game names another.
      attr_reader :platform

      def initialize(title:, setting:, settings_file:, key: "rom", releases: nil, probe: nil, not_set_help: nil, paths: {},
                     env: ENV, platform: :gba)
        raise ArgumentError, "#{title}: name releases: or probe:, one of the two" unless releases.nil? ^ probe.nil?

        @platform = Original.platform_named(platform)
        @title = title
        @setting = setting
        @settings_file = File.expand_path(settings_file)
        @key = key
        @releases = releases && Releases.new(title: title, list: release_list(releases))
        @probe = probe
        @not_set_help = not_set_help
        @paths = paths.to_h { |name, entry| [name.to_sym, PathSetting.from(entry)] }
        @env = env
      end

      # The releases the game knows (Releases), or nil for a game that accepts its copy by a probe.
      attr_reader :releases

      # The accepted copy. NotSet when nothing names where one is, WrongCopy when the one named
      # cannot be used. Inside Original.without_copies it is NotSet whatever is set (a shell build).
      def copy
        raise NotSet, copies_hidden_message if Original.copies_hidden?

        named = named_path(setting, key, WrongCopy)
        raise NotSet, not_set_message if named.nil?
        raise WrongCopy, "#{named.named_in} names #{named.path}. Nothing is there. Correct the path to your copy of #{title}." unless File.exist?(named.path)
        return probed_copy(named.path) if @probe

        release, sha1 = release_by_digest(named.path)
        Copy.new(path: named.path, release: release, sha1: sha1, platform: platform)
      end

      # The path the game names +name+ (one of +paths+), found as the copy is. NotSet when nothing
      # sets where it is, WrongPath when what is named is not there or is not the kind it must be.
      def path(name)
        entry = @paths.fetch(name.to_sym) { refuse_unknown_path_name!(name) }
        raise NotSet, copies_hidden_message if Original.copies_hidden?

        named = named_path(entry.setting, entry.key, WrongPath)
        raise NotSet, path_not_set_message(entry) if named.nil?

        refuse_wrong_kind!(named, entry)
        named.path
      end

      # The accepted copy, or nil when nothing names where one is. A copy that is named and wrong
      # raises WrongCopy all the same: that is a mistake to fix, not a machine without the game.
      def copy_if_set
        copy
      rescue NotSet
        nil
      end

      private

      def release_list(releases)
        listed = releases.is_a?(Hash) ? releases.map { |name, facts| Release.from(name, facts) } : releases.map { |facts| Release.from(facts.transform_keys(&:to_s).fetch("name"), facts) }
        raise ArgumentError, "#{title}: releases: names no release that the game reads" if listed.none?(&:read)

        listed
      end

      # Where +setting+ or the settings file's +key+ names a path, or nil when neither does. A settings
      # file that cannot be read is refused as +error+.
      def named_path(setting, key, error)
        from_env = @env[setting].to_s
        return Named.new(path: File.expand_path(from_env), named_in: setting) unless from_env.empty?
        return nil unless File.file?(settings_file)

        named = settings_value(key, error).to_s
        named.empty? ? nil : Named.new(path: File.expand_path(named, File.dirname(settings_file)), named_in: settings_file)
      end

      def settings_value(key, error)
        loaded = YAML.safe_load_file(settings_file)
        loaded.is_a?(Hash) ? loaded[key] : nil
      rescue Psych::Exception => e
        raise error, "#{settings_file} is not YAML that can be read: #{e.message}. Correct the file. " \
                     "It must hold lines like \"#{key}: /path/to/it\"."
      end

      def refuse_unknown_path_name!(name)
        named = @paths.empty? ? "It names no other paths." : "It names #{@paths.keys.map(&:inspect).join(', ')}."
        raise ArgumentError, "#{title} names no path #{name.inspect}. #{named}"
      end

      def refuse_wrong_kind!(named, entry)
        there = entry.folder ? File.directory?(named.path) : File.file?(named.path)
        return if there

        found = File.exist?(named.path) ? "That is not #{entry.kind_words}." : "Nothing is there."
        raise WrongPath, "#{named.named_in} names #{named.path} as #{entry.what}. #{found} It must be #{entry.kind_words}. " \
                         "Correct the path."
      end

      def path_not_set_message(entry)
        ["This needs #{entry.what}. No setting and no settings file names it.",
         "Set #{entry.setting} to its path.", file_step(entry.key, "its path")].join(" ")
      end

      # What to write in the settings file to name a path: from its template beside it, if there is one.
      def file_step(key, what)
        example = settings_file.sub(/\.ya?ml\z/, ".example.yml")
        return "Or copy #{example} to #{settings_file}. Then set #{key}: in it to #{what}." if File.file?(example)

        "Or make #{settings_file} with the line \"#{key}: /path/to/it\"."
      end

      # A copy accepted by the game's probe, hashed when it is one file.
      def probed_copy(path)
        release = @probe.call(path) || raise(WrongCopy, "#{path} is not a copy of #{title} that this game can read. Name a different copy.")
        Copy.new(path: path, release: release, sha1: File.file?(path) ? Digest::SHA1.file(path).hexdigest : nil, platform: platform)
      end

      # The release the copy at +path+ is, by its length and then its SHA-1 (Releases has the words
      # for a copy that is none the game reads), and that SHA-1.
      def release_by_digest(path)
        raise WrongCopy, "#{path} is a folder. Name the file of your copy of #{title}." unless File.file?(path)

        refusal = @releases.size_refusal(path, File.size(path))
        raise WrongCopy, refusal if refusal

        sha1 = Digest::SHA1.file(path).hexdigest
        refusal = @releases.digest_refusal(path, sha1, md5: (Digest::MD5.file(path).hexdigest unless @releases.with_sha1(sha1)))
        raise WrongCopy, refusal if refusal

        [@releases.with_sha1(sha1).name, sha1]
      end

      def copies_hidden_message
        "This build is a shell, which holds none of #{title}'s data, so it reads no copy of #{title} and no file " \
          "made from one."
      end

      def not_set_message
        ["This needs your copy of #{title}. No setting and no settings file names it.",
         "The copy is not in the repository, because it is not free to give away.",
         "Set #{setting} to the path of your copy.", file_step(key, "the path of your copy"), @not_set_help].compact.join(" ")
      end
    end
  end
end
