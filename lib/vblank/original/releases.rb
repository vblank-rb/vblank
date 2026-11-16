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
      #
      # A COPY NO RELEASE HAS THE DIGEST OF is changed, damaged or cut short. Two things say more
      # about it, where the caller has them. +size+, the copy's length: when it is no length a
      # release is listed with, the refusal says so (size_refusal refuses such a copy unread only
      # when every release has a size). And the block, asked only here, gives the name of the
      # release the copy says it is (read from its header, say) or nil: a damaged copy of that
      # release is then refused naming it, and one that is the wrong length for it, with both
      # lengths. A shell asks with neither, since each of its releases has a size.
      def digest_refusal(named, sha1, md5: nil, size: nil)
        release = with_sha1(sha1)
        return nil if release&.read
        return unread_release_message(named, release) if release

        by_md5 = md5 && @list.find { |known| known.md5 == md5 }
        return unread_release_message(named, by_md5) if by_md5 && !by_md5.read

        claimed = block_given? ? yield : nil
        return claimed_release_refusal(named, claimed, sha1, size) if claimed

        unknown_release_message(named, sha1) + unknown_length_words(size).to_s
      end

      # Why a copy +named+ of +size+ bytes that says it is the release called +claimed+ (as
      # digest_refusal's block gives it) is refused for its length, or nil when that release has no
      # size or the copy is its length. A copy refused by size_refusal is named by this where it can be.
      def claimed_size_refusal(named, claimed, size)
        release = @list.find { |known| known.name == claimed }
        return nil if release.nil? || release.size.nil? || release.size == size

        claimed_length_message(named, release, size)
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

        one_file_message(named)
      end

      # Why a folder +named+ that holds the files +names+ is refused when it holds no release whole.
      def missing_files_refusal(named, names)
        return folder_message(named) if readable.none?(&:several_files?)

        lacking = readable.select(&:several_files?).map do |release|
          release_lacks_message(release.name, release.files.map(&:name).reject { |file_name| file_in(names, file_name) }.join(MISSING_JOIN))
        end
        lacking_message(named, lacking.join(LACKING_JOIN))
      end

      # How the lacking releases are joined in a refusal of a folder, and the names a release lacks.
      LACKING_JOIN = "; "
      MISSING_JOIN = ", "

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

          return wrong_file_message(File.join(named, file.name), release.name, file, measured.size, measured.sha1)
        end
        nil
      end

      # The refusals as sentences for a runtime that is not Ruby to fill in (a shell's,
      # Original::ShellFacts), the same sentences as the methods above give, with {named} for the
      # file or folder, {size} for its size and {sha1} for its SHA-1:
      #
      # - +wrong_size+, +unknown+, and +unread+ by the name of each release the game knows and does
      #   not read: a copy that is one file;
      # - +one_file+ ("" unless every release the game reads is several files) and +folder+ ("" unless
      #   none is): a copy of the wrong shape;
      # - +lacking+, a folder that holds no release whole, {lacking} being +release_lacks+ for each
      #   release the game reads that is several files ({release} its name, {missing} the files the
      #   folder lacks, joined with +missing_join+), joined with +lacking_join+;
      # - +wrong_file+, a file of the folder that is not the release's, {named} being the folder and
      #   the file's name joined, {release} the release's name, and {want_size} and {want_sha1} the
      #   file's as the release has it.
      Words = Data.define(:wrong_size, :unknown, :unread, :one_file, :folder, :lacking, :release_lacks, :lacking_join,
                          :missing_join, :wrong_file)

      # This game's Words.
      def words
        Words.new(wrong_size: wrong_size_message("{named}", "{size}"), unknown: unknown_release_message("{named}", "{sha1}"),
                  unread: @list.reject(&:read).to_h { |release| [release.name, unread_release_message("{named}", release)] },
                  one_file: one_file_refusal("{named}").to_s,
                  folder: readable.none?(&:several_files?) ? folder_message("{named}") : "",
                  lacking: lacking_message("{named}", "{lacking}"), release_lacks: release_lacks_message("{release}", "{missing}"),
                  lacking_join: LACKING_JOIN, missing_join: MISSING_JOIN,
                  wrong_file: wrong_file_message("{named}", "{release}", ReleaseFile.new(name: nil, sha1: "{want_sha1}", size: "{want_size}"),
                                                 "{size}", "{sha1}"))
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

      def claimed_release_refusal(named, claimed, sha1, size)
        claimed_size_refusal(named, claimed, size) || damaged_release_message(named, claimed, sha1)
      end

      # The sentence that tells a copy its length, when releases have sizes and none is its.
      def unknown_length_words(size)
        sized = @list.reject { |release| release.size.nil? }
        return nil if size.nil? || sized.empty? || sized.any? { |release| release.size == size }

        lengths = sized.map { |release| "#{release.size} bytes for the #{release.name} release" }.join(", or ")
        " It is #{size} bytes. A complete copy is #{lengths}."
      end

      def claimed_length_message(named, release, size)
        "#{named} is the #{release.name} release of #{title}, but it is #{size} bytes. A complete copy of that release " \
          "is #{release.size} bytes. Name a complete copy of #{title}."
      end

      def damaged_release_message(named, claimed, sha1)
        release = @list.find { |known| known.name == claimed && known.sha1 }
        wanted = release ? " A complete copy of that release has SHA-1 #{release.sha1}." : ""
        "#{named} is the #{claimed} release of #{title}, but it is changed or damaged. Its SHA-1 is #{sha1}.#{wanted} " \
          "This game reads #{readable_words}. Name a copy of one of these."
      end

      def one_file_message(named) = "#{named} is one file. A copy of #{title} is a folder that holds #{readable_words}. Name that folder."

      def folder_message(named) = "#{named} is a folder. A copy of #{title} is one file. Name that file."

      def lacking_message(named, lacking)
        "#{named} does not hold a whole release of #{title}: #{lacking}. Name the folder that holds every file of one release."
      end

      def release_lacks_message(release_name, missing) = "the #{release_name} release lacks #{missing}"

      def wrong_file_message(named, release_name, file, size, sha1)
        "#{named} is not the file of the #{release_name} release of #{title}. It must be #{file.size} bytes with SHA-1 " \
          "#{file.sha1}. It is #{size} bytes with SHA-1 #{sha1}. A changed or damaged file has a different SHA-1. Name a " \
          "folder that holds the files as the release has them."
      end

      def unread_release_message(named, release)
        "#{named} is the #{release.name} release of #{title}. This game does not read that release. " \
          "It reads #{readable_words}. Name a copy of one of these."
      end
    end
  end
end
