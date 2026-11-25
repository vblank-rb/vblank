# frozen_string_literal: true

require "digest"
require "fileutils"

module VBlank
  module Cartridge
    # Keeps the rewritten text of VBlank's own game-code files on disk, so a start of the library
    # reads it back instead of rewriting 40-odd files with Prism every time (VBlank.require_game_file).
    #
    # ### What is kept
    #
    # The rewritten Ruby text, not compiled instructions. A measured start spent most of its time in
    # the rewrite and a small part compiling, so keeping the text gets most of the gain. Compiled
    # instructions (RubyVM::InstructionSequence#to_binary) would save the rest, but they are tied to
    # the exact Ruby build and need their own checks for paths and line numbers. Text is plain, and
    # Ruby still compiles it under the file's own path, so errors and backtraces name the real file.
    #
    # ### The key
    #
    # A digest of the file's contents and path, the source of the rewriter (every
    # `dsl/plain_ruby*.rb`), Prism's version, VBlank's version, and Ruby's version and platform. Any
    # change makes a different entry, and the old one is never read again.
    #
    # ### Where it lives and how it is switched off
    #
    # `$VBLANK_CACHE_DIR` if set and not empty, else `$XDG_CACHE_HOME/vblank`, else `~/.cache/vblank`,
    # in a `game_files` folder. It is outside the repository and the installed gem, which may be
    # read-only. A folder that cannot be made or written means no cache, silently. An entry that
    # cannot be read back whole is ignored and written again. `VBLANK_NO_CACHE=1` turns it off, for
    # debugging the rewriter.
    #
    # Must stay on the main Ractor: the library loads there, and the files are a Ractor-shared
    # store, so VBlank.require_game_file skips this class anywhere else.
    #--
    # An entry ends with a line holding the digest of the text before it. A trailing comment keeps the
    # magic comment on the first line and every line number as it was. Writes go to a temporary file in
    # the same folder and are renamed into place, since several processes (the native run's) may write
    # the same entry at once.
    #++
    class GameFileCache
      TRAILER = "\n#vblank-cache "

      # The cache this process uses, or nil when it is switched off or has no folder to use.
      def self.for_this_process(env: ENV)
        return nil if env["VBLANK_NO_CACHE"] == "1"

        xdg = env["XDG_CACHE_HOME"].to_s
        root = [env["VBLANK_CACHE_DIR"].to_s, xdg.empty? ? "" : File.join(xdg, "vblank"), home_cache_folder(env)]
               .find { |dir| !dir.empty? }
        root && new(File.join(root, "game_files"))
      end

      # Empty where the person has no home folder to put one in.
      def self.home_cache_folder(env)
        home = env["HOME"].to_s
        home.empty? ? "" : File.join(home, ".cache", "vblank")
      end
      private_class_method :home_cache_folder

      attr_reader :folder

      def initialize(folder)
        @folder = folder
      end

      # The rewritten text of +path+: the entry if it is whole, else what the block returns, which
      # is then kept.
      def rewritten(path)
        entry = File.join(folder, "#{key(path)}.rb")
        kept = read_whole(entry)
        return kept if kept

        text = yield
        write_atomically(entry, text)
        text
      end

      private

      def key(path)
        Digest::SHA256.hexdigest([File.expand_path(path), File.binread(path), rewriter_digest, Prism::VERSION,
                                  VBlank::VERSION, RUBY_VERSION, RUBY_PLATFORM].join("\0"))
      end

      def rewriter_digest
        @rewriter_digest ||= Digest::SHA256.hexdigest(
          Dir[File.join(__dir__, "..", "dsl", "plain_ruby*.rb")].sort.map { |file| File.binread(file) }.join("\0")
        )
      end

      def read_whole(entry)
        content = File.binread(entry)
        text, digest = content.split(TRAILER, 2)
        return nil unless digest && digest.chomp == Digest::SHA256.hexdigest(text)

        text.force_encoding(Encoding::UTF_8)
      rescue SystemCallError, IOError
        nil
      end

      def write_atomically(entry, text)
        FileUtils.mkdir_p(folder)
        temporary = "#{entry}.#{Process.pid}.#{rand(1 << 32)}.tmp"
        File.binwrite(temporary, "#{text}#{TRAILER}#{Digest::SHA256.hexdigest(text.b)}\n")
        File.rename(temporary, entry)
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
