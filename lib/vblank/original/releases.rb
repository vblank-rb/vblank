# frozen_string_literal: true

require "digest"

module VBlank
  module Original
    # ONE FILE OF A RELEASE THAT IS SEVERAL FILES: its name as the original's disks spell it, its
    # SHA-1 and its size in bytes.
    ReleaseFile = Data.define(:name, :sha1, :size)

    # A file of a player's folder as it was measured: its size in bytes and its SHA-1.
    FileMeasure = Data.define(:size, :sha1)

    # What Releases#match_folder found: the release a folder is (nil when it holds none whole), the
    # name the folder spells each of its files with, by the name in the release, and why the folder is
    # refused, or nil.
    FolderMatch = Data.define(:release, :spelled, :refusal)

    # ONE RELEASE OF THE ORIGINAL, as a decompilation's versions file lists it: its name, its SHA-1,
    # and if known its MD5, its size in bytes, and whether the game reads it. A release with an MD5
    # and no SHA-1 is one a person might have, and can be named, but is never read.
    #
    # A RELEASE THAT IS SEVERAL FILES (a computer game's folder: Wolfenstein 3D's VSWAP.WL6,
    # GAMEMAPS.WL6 and the rest) lists them as +files+, each a ReleaseFile, and only those files are
    # read: whatever else is in the player's folder (a settings file the game rewrites, saves) is
    # left alone. The copy is those files joined one after another in the order listed, so an
    # unpacking still reads one copy of a known size (CopyReader#file finds one file in it). Its
    # +size+ is theirs added up, and its +sha1+, which a data pack's header holds, is the SHA-1 of
    # the list itself (Release.files_sha1), which every build works out without the copy.
    Release = Data.define(:name, :sha1, :md5, :size, :read, :files) do
      def initialize(name:, sha1:, md5:, size:, read:, files: nil) = super

      # A release from one entry of a versions file (string or symbol keys): sha1, md5, size, and
      # supported, false for a release the game knows and does not read; or files, each file's name
      # with its sha1 and size, for a release that is several files.
      def self.from(name, facts)
        facts = facts.transform_keys(&:to_s)
        return from_files(name, facts) if facts.key?("files")

        new(name: name.to_s, sha1: facts["sha1"], md5: facts["md5"], size: facts["size"],
            read: facts["supported"] != false && !facts["sha1"].nil?)
      end

      def self.from_files(name, facts)
        files = facts.fetch("files").map do |file_name, file|
          file = file.transform_keys(&:to_s)
          refuse_unsized_file!(name, file_name, file)
          ReleaseFile.new(name: file_name.to_s, sha1: file["sha1"].to_s.downcase, size: file["size"])
        end
        raise ArgumentError, "The #{name} release names no files. List each file it holds." if files.empty?

        new(name: name.to_s, sha1: files_sha1(files), md5: nil, size: files.sum(&:size), read: facts["supported"] != false,
            files: files)
      end

      def self.refuse_unsized_file!(name, file_name, file)
        return if file["sha1"].to_s.match?(/\A\h{40}\z/) && file["size"].is_a?(Integer) && file["size"].positive?

        raise ArgumentError, "File #{file_name} of the #{name} release needs its sha1 (40 hex digits) and its size in bytes."
      end

      # The SHA-1 of a release of +files+: of a line for each, its name, size and SHA-1, in order.
      def self.files_sha1(files) = Digest::SHA1.hexdigest(files.map { |file| "#{file.name} #{file.size} #{file.sha1}\n" }.join)

      # Whether this release is several files.
      def several_files? = !files.nil?

      # Where the file called +file_name+ (any case) starts in the copy, and the ReleaseFile; nil when
      # the release holds no such file.
      def file_place(file_name)
        start = 0
        files&.each do |file|
          return [start, file] if file.name.casecmp?(file_name.to_s)

          start += file.size
        end
        nil
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

      # A COPY THAT IS A FOLDER, for a game whose releases are several files. +names+ are the names
      # of the files in the folder. The release the folder holds is the first one the game reads
      # whose every file is there, matched without regard to case; nil when none is.
      def release_in_folder(names) = readable.select(&:several_files?).find { |release| release.files.all? { |file| file_in(names, file.name) } }

      # The name in +names+ that is +file_name+, without regard to case, or nil.
      def file_in(names, file_name) = names.find { |name| name.casecmp?(file_name) }

      # Why one file +named+ is refused when every release the game reads is several files, or nil.
      def one_file_refusal(named)
        return nil unless readable.all?(&:several_files?)

        "#{named} is one file. A copy of #{title} is a folder that holds #{readable_words}. Name that folder."
      end

      # Why a folder +named+ that holds the files +names+ is refused when it holds no release whole.
      def missing_files_refusal(named, names)
        return "#{named} is a folder. A copy of #{title} is one file. Name that file." if readable.none?(&:several_files?)

        lacking = readable.select(&:several_files?).map do |release|
          missing = release.files.map(&:name).reject { |file_name| file_in(names, file_name) }
          "the #{release.name} release lacks #{missing.join(', ')}"
        end
        "#{named} does not hold a whole release of #{title}: #{lacking.join('; ')}. Name the folder that holds " \
          "every file of one release."
      end

      # The release the folder +named+ is, from the names of the files it holds, each of its files
      # measured by the block, which is given a name as the folder spells it and gives back that
      # file's FileMeasure. Only the release's own files are measured. A FolderMatch: the release and
      # how the folder spells each of its files, or why the folder is refused.
      def match_folder(named, names)
        release = release_in_folder(names)
        return FolderMatch.new(release: nil, spelled: nil, refusal: missing_files_refusal(named, names)) unless release

        spelled = release.files.to_h { |file| [file.name, file_in(names, file.name)] }
        found = spelled.transform_values { |name| yield name }
        FolderMatch.new(release: release, spelled: spelled, refusal: files_refusal(named, release, found))
      end

      # Why the folder +named+ is refused as a copy of +release+, or nil when it is one: +found+ gives
      # each file's FileMeasure by its name in the release.
      def files_refusal(named, release, found)
        release.files.each do |file|
          measured = found.fetch(file.name)
          next if measured.size == file.size && measured.sha1 == file.sha1

          return "#{File.join(named, file.name)} is not the file of the #{release.name} release of #{title}. " \
                 "It must be #{file.size} bytes with SHA-1 #{file.sha1}. It is #{measured.size} bytes with SHA-1 " \
                 "#{measured.sha1}. A changed or damaged file has a different SHA-1. Name a folder that holds " \
                 "the files as the release has them."
        end
        nil
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

      def readable_words = readable.map { |release| "#{release.name} (#{release_words(release)})" }.join(", ")

      def release_words(release) = release.several_files? ? "a folder of #{release.files.map(&:name).join(', ')}" : "SHA-1 #{release.sha1}"

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
