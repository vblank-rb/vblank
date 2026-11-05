# frozen_string_literal: true

require "digest"
require "yaml"

module VBlank
  module Original
    # SOMETHING IS WRONG WITH THE PLAYER'S COPY OF THE ORIGINAL, or nothing says where it is. The
    # message says what to set, so a caller that turns this into words for a person rescues this
    # one class.
    class CopyError < StandardError; end

    # NOTHING SAYS WHERE THE COPY IS: neither the setting nor the settings file names one. A fresh
    # clone of a game is like this, so a test skips (Testing#original_copy) and a build can carry on
    # without the original's data. Every other CopyError is a mistake to fix.
    class NotSet < CopyError; end

    # A COPY WAS NAMED AND CANNOT BE USED: nothing is there, it is the wrong length, its bytes are
    # no release the game knows, it is a release the game does not read, the game's probe refused
    # it, or the settings file that names it cannot be read.
    class WrongCopy < CopyError; end

    # THE PLAYER'S COPY, ACCEPTED: where it is and the name of its release.
    Copy = Data.define(:path, :release)

    # ONE RELEASE OF THE ORIGINAL, as a decompilation's versions file says it: its name, its SHA-1,
    # and if known its MD5, its size in bytes, and whether the game reads it. A release with an MD5
    # and no SHA-1 is one a person might have, and can be named, but is never read.
    Release = Data.define(:name, :sha1, :md5, :size, :read) do
      # A release from one entry of a versions file (string or symbol keys): sha1, md5, size, and
      # supported, false for a release the game knows and does not read.
      def self.from(name, facts)
        facts = facts.transform_keys(&:to_s)
        new(name: name.to_s, sha1: facts["sha1"], md5: facts["md5"], size: facts["size"],
            read: facts["supported"] != false && !facts["sha1"].nil?)
      end
    end

    # WHAT A GAME MADE FROM AN ORIGINAL SAYS ABOUT ITS COPY, and the one way to ask for it.
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
    #   key:            the key in that file ("rom" unless said; "data" for a folder of files, say)
    #   not_set_help:   words of the game's own added to the message when nothing is set: what the
    #                   copy must hold, say
    #   env:            where the setting is looked up (ENV unless said; a test hands its own)
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
    class Game
      # Where the copy was named: the path, and the setting or settings file that named it.
      Named = Data.define(:path, :named_in)

      attr_reader :title, :setting, :settings_file, :key

      def initialize(title:, setting:, settings_file:, key: "rom", releases: nil, probe: nil, not_set_help: nil, env: ENV)
        raise ArgumentError, "#{title}: name releases: or probe:, one of the two" unless releases.nil? ^ probe.nil?

        @title = title
        @setting = setting
        @settings_file = File.expand_path(settings_file)
        @key = key
        @releases = releases && release_list(releases)
        @probe = probe
        @not_set_help = not_set_help
        @env = env
      end

      # The accepted copy. NotSet when nothing says where one is, WrongCopy when the one named
      # cannot be used.
      def copy
        named = named_copy
        raise NotSet, not_set_message if named.nil?
        raise WrongCopy, "#{named.named_in} names #{named.path}. Nothing is there. Correct the path to your copy of #{title}." unless File.exist?(named.path)

        Copy.new(path: named.path, release: @probe ? probed_release(named.path) : release_by_digest(named.path))
      end

      # The accepted copy, or nil when nothing says where one is. A copy that is named and wrong
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

      # Where the setting or the settings file names the copy, or nil when neither does.
      def named_copy
        from_env = @env[setting].to_s
        return Named.new(path: File.expand_path(from_env), named_in: setting) unless from_env.empty?
        return nil unless File.file?(settings_file)

        named = settings_value.to_s
        named.empty? ? nil : Named.new(path: File.expand_path(named, File.dirname(settings_file)), named_in: settings_file)
      end

      def settings_value
        loaded = YAML.safe_load_file(settings_file)
        loaded.is_a?(Hash) ? loaded[key] : nil
      rescue Psych::Exception => e
        raise WrongCopy, "#{settings_file} is not YAML that can be read: #{e.message}. Correct the file. It must hold a line like \"#{key}: /path/to/your/copy\"."
      end

      def probed_release(path)
        @probe.call(path) || raise(WrongCopy, "#{path} is not a copy of #{title} that this game can read. Name a different copy.")
      end

      def release_by_digest(path)
        raise WrongCopy, "#{path} is a folder. Name the file of your copy of #{title}." unless File.file?(path)

        refuse_unknown_length!(path)
        sha1 = Digest::SHA1.file(path).hexdigest
        release = @releases.find { |known| known.sha1 == sha1 }
        return release.name if release&.read
        raise WrongCopy, unread_release_message(path, release) if release

        raise WrongCopy, unknown_bytes_message(path, sha1)
      end

      # A copy no known release is the length of is refused without reading it: most wrong copies are
      # another game, or a download cut short, and this says so at once. One the length of a release
      # the game does not read goes on, so that the release can be named.
      def refuse_unknown_length!(path)
        sizes = @releases.map(&:size)
        return if sizes.include?(nil) || sizes.include?(File.size(path))

        raise WrongCopy, "#{path} is #{File.size(path)} bytes. A copy of #{title} is #{readable_releases.map(&:size).uniq.join(' or ')} " \
                         "bytes. Name a complete copy of #{title}."
      end

      def readable_releases = @releases.select(&:read)

      def readable_releases_words = readable_releases.map { |release| "#{release.name} (SHA-1 #{release.sha1})" }.join(", ")

      def unknown_bytes_message(path, sha1)
        md5 = Digest::MD5.file(path).hexdigest
        named = @releases.find { |known| known.md5 == md5 }
        return unread_release_message(path, named) if named && !named.read

        "#{path} is not a release of #{title} that this game knows. Its SHA-1 is #{sha1}. A changed or " \
          "damaged copy has a different SHA-1. This game reads #{readable_releases_words}. Name a copy of one of these."
      end

      def unread_release_message(path, release)
        "#{path} is the #{release.name} release of #{title}. This game does not read that release. " \
          "It reads #{readable_releases_words}. Name a copy of one of these."
      end

      def not_set_message
        example = settings_file.sub(/\.ya?ml\z/, ".example.yml")
        file_step = if File.file?(example)
                      "Or copy #{example} to #{settings_file}. Then set #{key}: in it to the path of your copy."
                    else
                      "Or make #{settings_file} with the line \"#{key}: /path/to/your/copy\"."
                    end
        ["This needs your copy of #{title}. No setting and no settings file names it.",
         "The copy is not in the repository, because it is not free to give away.",
         "Set #{setting} to the path of your copy.", file_step, @not_set_help].compact.join(" ")
      end
    end
  end
end
