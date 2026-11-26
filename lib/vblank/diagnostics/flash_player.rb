# frozen_string_literal: true

require "open3"
require "tmpdir"

module VBlank
  module Diagnostics
    # Plays a Flash program (a .swf) in Ruffle with no window, a frame at a time, and gives back every
    # line it traced, in order. It runs the harness of ruby-flash-player/, which `rake
    # compile_flash_player` builds.
    #
    #   lines = FlashPlayer.play("game.swf", frames: 3, keys: [[2, :left, :down], [3, :left, :up]])
    #
    # A key is [frame, name, :down or :up] and is pressed just before that frame runs. Frames count
    # from 1.
    module FlashPlayer
      # Where the harness is built in a checkout, and the setting that points at one built elsewhere.
      HARNESS_PATH = File.join(File.expand_path("../../..", __dir__), "ruby-flash-player", "harness", "target", "release",
                               "flash_player_harness").freeze
      HARNESS_SETTING = "VBLANK_FLASH_HARNESS"

      # Raised when the harness is not built, or the movie could not be played.
      class Error < StandardError; end

      module_function

      # The harness to run: +given+, or the one the setting names, or the one a checkout builds. Fails, saying how to
      # build it, when there is none.
      def harness_path(given = nil)
        path = given || ENV.fetch(HARNESS_SETTING, HARNESS_PATH)
        return path if File.file?(path)

        raise Error, "The Flash player is not built: there is no program at #{path}. Build it with " \
                     "`rake compile_flash_player` (it needs Rust, and Ruffle's source: see ruby-flash-player/README.md), " \
                     "or set #{HARNESS_SETTING} to one built elsewhere."
      end

      # Plays +swf+ for +frames+ frames and gives back the lines it traced. +harness+ names a harness to
      # use in place of the one built (harness_path).
      def play(swf, frames:, keys: [], harness: nil)
        raise Error, "There is no program at #{swf}." unless File.file?(swf)

        Dir.mktmpdir("vblank-flash") do |dir|
          arguments = [harness_path(harness), swf, "--frames", frames.to_s]
          unless keys.empty?
            tape = File.join(dir, "keys.tape")
            File.write(tape, keys.map { |frame, name, direction| "#{frame} #{name} #{direction}\n" }.join)
            arguments += ["--tape", tape]
          end
          printed, complaints, status = Open3.capture3(*arguments)
          raise Error, "The Flash player stopped (#{status}):\n#{complaints}" unless status.success?

          printed.lines(chomp: true)
        end
      end
    end
  end
end
