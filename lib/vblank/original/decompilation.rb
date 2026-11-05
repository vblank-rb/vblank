# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module VBlank
  module Original
    # THE DECOMPILATION WOULD NOT BUILD, or built something other than the player's copy, or is not at
    # its pin. Nothing was harvested, and the message says what to do.
    class HarvestRefused < StandardError; end

    # A DECOMPILATION BUILT, PROVEN TO BE THE PLAYER'S COPY, AND ONLY THEN READ.
    #
    # A port takes its symbols, its RAM labels and where each asset lies from a decompilation of the
    # original. Those are worth having only if they are the game's, and a decompilation is somebody's
    # reading of it, wrong in places nobody has looked. So nothing is taken from one that has not
    # been shown to assemble to the copy the player has:
    #
    #   decomp = VBlank::Original::Decompilation.new(checkout: ORIGINAL.path(:checkout), pin: "0a6f6dc",
    #                                               command: [ORIGINAL.path(:assembler), "-o", "rocket.gbc", "main.asm"],
    #                                               output: "rocket.gbc")
    #   decomp.harvest(ORIGINAL.copy) do |built|
    #     symbols = File.read(built.path("rocket.sym"))       # the assembler's own files
    #     built.extent("gfx/ship.2bpp", at: 0x4000)             # where an asset lies, proven
    #   end
    #
    # 1. The checkout must be at its pin (seven hex digits or more of the commit) with no tracked file
    #    edited: a different commit is a different answer to every question asked of it.
    # 2. The pinned commit is copied into a folder of its own (`git archive`), so the checkout is
    #    never written to, and removed afterwards. A commit leaves out what git does not hold (a
    #    submodule, a file kept out by .gitignore); +extra_files+ names files of the checkout's to
    #    copy in beside it, from the checkout as it is.
    # 3. The game's command builds it there, with +env+ added to the environment (a PATH that reaches
    #    the assembler, say).
    # 4. The file it builds (+output+), after +fix+ if the game gives one (a header field an
    #    assembler cannot know, which the decompilation's own build script fills in), must be the
    #    player's copy byte for byte. Otherwise this stops, saying how many bytes differ and where the
    #    first is, and the block never runs.
    #
    # WHAT THE GAME SUPPLIES: the checkout, its pin, the command and the file it builds, and the
    # block that reads the build: its label parsers and its output formats are the game's own, and so
    # is any check that two assets do not claim the same bytes. The checkout and the assembler are
    # found as the copy is, by Game#path, and the copy is the accepted Copy (or its path).
    #
    # It is in VBlank, beside the copy it proves itself against, rather than in a gem of its own: it
    # is a few dozen lines a port cannot be trusted without, and it needs nothing VBlank does not.
    class Decompilation
      # An asset the build pulled in, proven to lie in the copy where the build put it: its offset,
      # length and SHA-1.
      Extent = Data.define(:source, :offset, :length, :sha1)

      # How much of the build and the copy is compared at a time.
      COMPARED_BYTES = 65_536
      # The fewest hex digits of a commit a pin may be: fewer can match another commit.
      SHORTEST_PIN = 7
      PIN = Ractor.make_shareable(/\A\h{#{SHORTEST_PIN},40}\z/)

      # The decompilation built in a folder of its own, for the harvest block to read: the folder,
      # what the command printed, and the copy's bytes, which the build has been proven to be.
      Build = Data.define(:folder, :log, :bytes) do
        # The path of +file+ in the build's folder.
        def path(file) = File.join(folder, file)

        # Where +source+ (a file of the build's folder) lies in the copy, at +at+ (a file offset):
        # refused unless the copy holds that file's bytes there.
        def extent(source, at:)
          data = File.binread(path(source))
          unless at >= 0 && !data.empty? && bytes.byteslice(at, data.bytesize) == data
            raise HarvestRefused, "#{source} is not in the copy at #{format('0x%X', at)}. The build placed it somewhere " \
                                  "else, or the offset is wrong. Correct the offset the harvest gives for it."
          end

          Extent.new(source: source, offset: at, length: data.bytesize, sha1: Digest::SHA1.hexdigest(data))
        end
      end

      def initialize(checkout:, pin:, command:, output:, fix: nil, env: {}, extra_files: [])
        unless pin.to_s.match?(PIN)
          raise ArgumentError, "The pin #{pin.inspect} is not a commit. Give #{SHORTEST_PIN} or more hex digits of the commit."
        end

        @checkout = File.expand_path(checkout)
        @pin = pin.downcase
        @command = command
        @output = output
        @fix = fix
        @env = env
        @extra_files = extra_files
      end

      # Build the decompilation, prove it is +copy+ (an accepted Copy, or a path), and hand the Build to
      # the block. What the block gives back is given back. HarvestRefused when any step fails.
      def harvest(copy)
        refuse_off_pin!
        wanted = File.binread(copy.respond_to?(:path) ? copy.path : copy)
        Dir.mktmpdir("vblank-harvest") do |folder|
          unpack_pinned_commit(folder)
          copy_extra_files(folder)
          log = run_build(folder)
          refuse_different_copy!(built_bytes(folder, log), wanted)
          yield Build.new(folder: folder, log: log, bytes: wanted)
        end
      end

      private

      def git(*arguments)
        out, error, status = Open3.capture3("git", "-C", @checkout, *arguments, binmode: true)
        return out if status.success?

        raise HarvestRefused, "git #{arguments.first} did not work in #{@checkout}: #{error.strip}. " \
                              "The decompilation must be a git checkout there."
      end

      def refuse_off_pin!
        head = git("rev-parse", "HEAD").strip
        unless head.start_with?(@pin)
          raise HarvestRefused, "The decompilation in #{@checkout} is at #{head[0, 12]}, and the harvest is pinned to #{@pin}. " \
                                "Run: git -C #{@checkout} checkout #{@pin}"
        end
        return if git("status", "--porcelain", "--untracked-files=no").strip.empty?

        raise HarvestRefused, "The decompilation in #{@checkout} has edited files, so it is not #{@pin}. " \
                              "Run: git -C #{@checkout} status"
      end

      # The pinned commit's files, unpacked into +folder+: git archive's output fed to tar as it comes.
      def unpack_pinned_commit(folder)
        statuses = Open3.pipeline(["git", "-C", @checkout, "archive", "--format=tar", @pin], ["tar", "-x", "-C", folder],
                                  err: File::NULL)
        return if statuses.all?(&:success?)

        raise HarvestRefused, "The pinned commit could not be unpacked from #{@checkout}. Check that git and tar are installed."
      end

      def copy_extra_files(folder)
        @extra_files.each do |file|
          source = File.join(@checkout, file)
          raise HarvestRefused, "#{source} is not there, and the build needs it. Put it in the checkout." unless File.file?(source)

          FileUtils.mkdir_p(File.dirname(File.join(folder, file)))
          FileUtils.cp(source, File.join(folder, file))
        end
      end

      def run_build(folder)
        log, status = Open3.capture2e(@env, *@command, chdir: folder)
        return log if status.success?

        raise HarvestRefused, "#{@command.join(' ')} did not build the decompilation. It said, at the end:\n#{log.lines.last(20).join}"
      end

      def built_bytes(folder, log)
        built = File.join(folder, @output)
        raise HarvestRefused, "The build made no #{@output}. It said, at the end:\n#{log.lines.last(12).join}" unless File.file?(built)

        bytes = File.binread(built)
        return bytes unless @fix

        fixed = @fix.call(bytes)
        raise HarvestRefused, "The fix: given to the harvest gave back #{fixed.class}, not the bytes. It must give back a String." unless fixed.is_a?(String)

        fixed
      end

      def refuse_different_copy!(built, copy)
        return if built == copy

        if built.bytesize != copy.bytesize
          raise HarvestRefused, "The decompilation built #{built.bytesize} bytes, and the copy is #{copy.bytesize}. " \
                                "Nothing was harvested. The copy must be the release that the pin builds."
        end

        first, differing = differing_bytes(built, copy)
        raise HarvestRefused, "The decompilation does not build the copy: #{differing} bytes differ, the first at " \
                              "#{format('0x%X', first)}. Nothing was harvested."
      end

      # Where two strings of one length first differ, and in how many bytes: compared a piece at a
      # time, and a byte at a time only inside a piece that differs.
      def differing_bytes(built, copy)
        first = nil
        differing = 0
        (0...built.bytesize).step(COMPARED_BYTES) do |start|
          next if built.byteslice(start, COMPARED_BYTES) == copy.byteslice(start, COMPARED_BYTES)

          (start...[start + COMPARED_BYTES, built.bytesize].min).each do |at|
            next if built.getbyte(at) == copy.getbyte(at)

            first ||= at
            differing += 1
          end
        end
        [first, differing]
      end
    end
  end
end
