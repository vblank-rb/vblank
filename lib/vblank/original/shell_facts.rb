# frozen_string_literal: true

module VBlank
  module Original
    # WHAT EVERY RUNTIME IS TOLD ABOUT A SHELL (Shell#facts), the one record the desktop program's
    # (Native::ShellData), the web page's (JS#build_shell_page) and the Ruby one's (Live::Shell, in
    # this process or written out as one file) are all made from. Every sentence a shell refuses a
    # file in is here, made once in Ruby, with {name} where a runtime fills in what only it knows
    # (rg_words_fill in C and JavaScript):
    #
    # - +title+, the game's; +folder+, the folder its pack is kept in (Shell.folder_name), and
    #   +pack_file+, the pack's name inside it;
    # - +releases_title+ and +releases+ (each a Release), the original's releases, and
    #   +release_words+ (Releases::Words), the sentences for a file that is none the game reads;
    # - +pack_before_sha1+ and +pack_after_sha1+, the pack's header before and after the 20 bytes
    #   of the copy's SHA-1;
    # - +pack_rules+ (IR::StartFile::Rules), the check that tells a pack for this build from any other;
    # - +menu+ (Menu), the menu's variable and what each number it is set to means;
    # - +unpacking+ (UnpackingNames), what an unpacking's answer is read from;
    # - +words+ (Words), the shell's own sentences.
    #
    # A game written out as one Ruby file carries this file as it is (Backends::Ruby#script), with
    # IR::StartFile and Releases, so it needs nothing else of the library.
    ShellFacts = Data.define(:title, :folder, :pack_file, :releases_title, :releases, :release_words, :pack_before_sha1,
                             :pack_after_sha1, :pack_rules, :menu, :unpacking, :words)

    class ShellFacts
      # The name of the file the pack is kept in, inside the game's folder.
      PACK_FILE = "data.pack"

      # One release of the original: its +name+, +sha1+ (40 lowercase hex digits), +size+ in bytes
      # (nil where not known), whether the game reads it (+read+), and +unpacking+, the number from 0
      # of the unpacking that reads it (Shell#unpackings), nil for a release the game does not read.
      # A release that is several files (Original::Release#files) has +files+, each a Hash of its
      # "name", "sha1" and "size", in the release's order; nil for a release that is one file.
      Release = Data.define(:name, :sha1, :size, :read, :unpacking, :files) do
        def initialize(name:, sha1:, size:, read:, unpacking:, files: nil) = super
      end

      # The variable the menu sets as it halts, and the number for each line chosen.
      Menu = Data.define(:choice_variable, :load_rom, :settings)

      # The names in an unpacking a shell reads its answer from (Original::Unpacking): the list of
      # the pack's bytes, and the variables set when it gets to its end and when something went wrong.
      UnpackingNames = Data.define(:bytes, :finished, :fault_kind)

      # The shell's sentences: for a kept pack it does not read (+kept_pack_refused+, {path} and
      # {refusal}), an unpacking that stopped part way (+unpacking_stopped+, {named} for the file and
      # {fault}), and a file that cannot be read (+unreadable+, {named} and {why}).
      Words = Data.define(:kept_pack_refused, :unpacking_stopped, :unreadable)

      def self.kept_pack_refused_message(title, path, refusal) = "#{path}: #{refusal} Load your copy of #{title} again to make it."

      def self.unpacking_stopped_message(named, fault)
        "#{named} is a copy this game reads, and its unpacking stopped part way (fault #{fault}). This is a fault in " \
          "the game. Tell its makers."
      end

      def self.unreadable_message(named, why) = "#{named} cannot be read (#{why})."

      # The Words of a game called +title+.
      def self.words_for(title)
        Words.new(kept_pack_refused: kept_pack_refused_message(title, "{path}", "{refusal}"),
                  unpacking_stopped: unpacking_stopped_message("{named}", "{fault}"),
                  unreadable: unreadable_message("{named}", "{why}"))
      end

      # The Releases a picked file is checked against in Ruby, whose sentences are +release_words+.
      def original_releases
        list = releases.map do |release|
          files = release.files&.map { |file| ReleaseFile.new(name: file.fetch("name"), sha1: file.fetch("sha1"), size: file.fetch("size")) }
          Original::Release.new(name: release.name, sha1: release.sha1, md5: nil, size: release.size, read: release.read, files: files)
        end
        Releases.new(title: releases_title, list: list)
      end

      # The release whose SHA-1 is +sha1+, or nil.
      def release_with_sha1(sha1) = releases.find { |release| release.sha1 == sha1 }

      # The pack file for a copy whose SHA-1 is +sha1+, holding +bytes+, what the unpacking wrote.
      def pack_for(sha1, bytes) = [pack_before_sha1, [sha1].pack("H*"), pack_after_sha1, bytes].join.b

      # The facts as plain data, Hashes with String keys, Arrays, Strings and Integers, for JSON:
      # what the web page's runtime reads, and what a Ruby script reads back with #from_plain. The
      # header's bytes are Arrays of numbers.
      def to_plain
        { "title" => title, "folder" => folder, "pack_file" => pack_file, "releases_title" => releases_title,
          "releases" => releases.map { |release| ShellFacts.plain_record(release) },
          "release_words" => ShellFacts.plain_record(release_words),
          "pack_before_sha1" => pack_before_sha1.bytes, "pack_after_sha1" => pack_after_sha1.bytes,
          "pack_rules" => { "numbers" => pack_rules.numbers, "words" => ShellFacts.plain_record(pack_rules.words) },
          "menu" => ShellFacts.plain_record(menu), "unpacking" => ShellFacts.plain_record(unpacking),
          "words" => ShellFacts.plain_record(words) }
      end

      # The facts #to_plain gave.
      def self.from_plain(plain)
        new(title: plain.fetch("title"), folder: plain.fetch("folder"), pack_file: plain.fetch("pack_file"),
            releases_title: plain.fetch("releases_title"),
            releases: plain.fetch("releases").map { |release| record(Release, release) },
            release_words: record(Releases::Words, plain.fetch("release_words")),
            pack_before_sha1: plain.fetch("pack_before_sha1").pack("C*"), pack_after_sha1: plain.fetch("pack_after_sha1").pack("C*"),
            pack_rules: IR::StartFile::Rules.new(numbers: plain.fetch("pack_rules").fetch("numbers"),
                                                 words: record(IR::StartFile::Words, plain.fetch("pack_rules").fetch("words"))),
            menu: record(Menu, plain.fetch("menu")), unpacking: record(UnpackingNames, plain.fetch("unpacking")),
            words: record(Words, plain.fetch("words")))
      end

      def self.plain_record(record) = record.to_h.transform_keys(&:to_s)

      def self.record(kind, plain) = kind.new(**plain.transform_keys(&:to_sym))
      private_class_method :record
    end
  end
end
