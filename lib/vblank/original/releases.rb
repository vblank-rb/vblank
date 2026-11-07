# frozen_string_literal: true

module VBlank
  module Original
    # ONE RELEASE OF THE ORIGINAL, as a decompilation's versions file lists it: its name, its SHA-1,
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

    # THE RELEASES A GAME KNOWS, AND THE WORDS FOR A COPY THAT IS NONE OF THEM. Game asks these of a
    # copy named on a build machine; a shell (Shell) asks the same of the file a player picks, so a
    # wrong copy is refused in the same words on both. Nothing here reads a file or raises: each
    # question is answered from a size or a digest, and a refusal is the sentence a person is shown, or nil.
    #
    # This file needs nothing else of the library, so a game written out as one Ruby file carries it
    # as it is (Backends::Ruby#script).
    class Releases
      attr_reader :title, :list

      # +title+ is what the game is called in a message; +list+ is each Release.
      def initialize(title:, list:)
        @title = title
        @list = list
      end

      # The releases the game reads.
      def readable = @list.select(&:read)

      # The release whose SHA-1 is +sha1+, read or not, or nil.
      def with_sha1(sha1) = @list.find { |known| known.sha1 == sha1 }

      # Why a copy +named+ (a path, or what a player picked) of +size+ bytes is refused unread, or nil
      # when a release is that size, or a release's size is not known. Most wrong copies are another
      # game, or a download cut short, and this refuses those at once. One the length of a release the game
      # does not read goes on, so that the release can be named.
      def size_refusal(named, size)
        sizes = @list.map(&:size)
        return nil if sizes.include?(nil) || sizes.include?(size)

        wrong_size_message(named, size)
      end

      # Why a copy +named+ whose SHA-1 is +sha1+ is refused, or nil when it is a release the game
      # reads. +md5+, when known, names a release listed by its MD5 alone.
      def digest_refusal(named, sha1, md5: nil)
        release = with_sha1(sha1)
        return nil if release&.read
        return unread_release_message(named, release) if release

        by_md5 = md5 && @list.find { |known| known.md5 == md5 }
        return unread_release_message(named, by_md5) if by_md5 && !by_md5.read

        unknown_release_message(named, sha1)
      end

      # The refusals as sentences with {named} for the file, {size} for its size and {sha1} for its
      # SHA-1 (Words), for a runtime that is not Ruby to fill in (a shell's, Original::ShellFacts):
      # the same sentences as the two methods above give.
      Words = Data.define(:wrong_size, :unknown, :unread)

      # This game's Words. +unread+ holds a sentence for each release the game knows and does not
      # read, by the release's name.
      def words
        Words.new(wrong_size: wrong_size_message("{named}", "{size}"), unknown: unknown_release_message("{named}", "{sha1}"),
                  unread: @list.reject(&:read).to_h { |release| [release.name, unread_release_message("{named}", release)] })
      end

      private

      def readable_words = readable.map { |release| "#{release.name} (SHA-1 #{release.sha1})" }.join(", ")

      def wrong_size_message(named, size)
        "#{named} is #{size} bytes. A copy of #{title} is #{readable.map(&:size).uniq.join(' or ')} bytes. " \
          "Name a complete copy of #{title}."
      end

      def unknown_release_message(named, sha1)
        "#{named} is not a release of #{title} that this game knows. Its SHA-1 is #{sha1}. A changed or " \
          "damaged copy has a different SHA-1. This game reads #{readable_words}. Name a copy of one of these."
      end

      def unread_release_message(named, release)
        "#{named} is the #{release.name} release of #{title}. This game does not read that release. " \
          "It reads #{readable_words}. Name a copy of one of these."
      end
    end
  end
end
