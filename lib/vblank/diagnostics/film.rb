# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Diagnostics
    # A FILM OF A RUNNING CARTRIDGE, or of two side by side, as an MP4 a person can watch without
    # running anything: the same moment played on each, a frame at a time with the same buttons,
    # and every frame of the parts asked for put next to each other. What a test holds frame by
    # frame, shown. Two builds of one game, or a game beside the cartridge it is a copy of, are
    # the usual pair; one side alone is a film of one game.
    #
    #   VBlank::Diagnostics::Film.make("door.mp4",
    #     sides: { "ours" => -> { Verifier.new(ours, frames: 0) }, "reference" => -> { Verifier.new(theirs, frames: 0) } },
    #     parts: [1..90, 200..240],
    #     keys: ->(frame) { :left if frame < 60 })
    #
    # A SIDE IS OPENED BY A CALLABLE, the side's label its key, and the callable answers a running
    # cartridge whose NEXT frame is the film's first: a Verifier told to play no frames, or one a
    # playthrough left standing at the moment worth filming. Film asks two things of it, and any
    # object that answers them can be filmed (an emulator of a game's own, say):
    #
    #   step(1, keys: mask)   play one frame with these buttons down (IR::Buttons.mask, a bit each)
    #   screenshot(path)      write the picture now on screen to +path+, a .png
    #
    # and closes it when its frames are taken, if it answers `close`. The sides are played one
    # after another, so only one is ever running.
    #
    # PARTS are ranges of frames to show, counted from one. Every frame up to the last one shown
    # is played, shown or not, so a part late in a long run costs the frames before it. The last
    # frame of each part is held a little under a second, so the jump to the next part is seen,
    # and the film's last frame is held until the film is at least three seconds long.
    #
    # KEYS answers the buttons held on a frame: a button's name, a list of them, or nil.
    #
    # It needs ImageMagick, which puts each pair of pictures together and writes the labels, and
    # ffmpeg, which makes the MP4. Both are looked for before any frame is played.
    class Film
      # The console shows sixty frames a second, and the MP4 plays them so.
      FRAME_RATE = 60

      PART_END_HOLD_SECONDS = 0.8
      SHORTEST_FILM_SECONDS = 3

      # Each picture is shown at twice the console's size unless +scale:+ says otherwise: at its
      # own size a frame is a postage stamp on a computer's screen. The MP4's way of keeping colour
      # needs an even width and height, which every console's screen has, and so has any whole
      # number of times it.
      PICTURE_SCALE = 2

      # The strip above the pictures: how tall, its colour, and the size of its writing.
      LABEL_STRIP_HEIGHT = 28
      LABEL_STRIP_COLOR = "#202020"
      LABEL_POINT_SIZE = 18
      # Where a side's label is written: its left edge and the line its letters stand on, so
      # every label stands on the same line whatever letters it has. The frame's number is set in
      # from the strip's top right corner.
      LABEL_BASELINE = "+12+20"
      FRAME_NUMBER_MARGIN = "+12+4"

      # The labels are written in the first of these that the computer has, and in ImageMagick's
      # own letters where it has none: a Mac's, then the one most Linux machines carry.
      LABEL_FONT_PATHS = ["/System/Library/Fonts/Supplemental/Arial.ttf",
                          "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"].freeze

      # A program Film runs, by the name a person knows it by: the commands that are it (ImageMagick
      # 7 is `magick`; 6, which Linux machines still ship, is `convert`) and the package to install.
      Tool = Data.define(:name, :commands, :package)
      IMAGEMAGICK = Tool.new(name: "ImageMagick", commands: %w[magick convert].freeze, package: "imagemagick")
      FFMPEG = Tool.new(name: "ffmpeg", commands: %w[ffmpeg].freeze, package: "ffmpeg")

      # Raised before any frame is played, when ImageMagick or ffmpeg is not installed.
      class MissingTool < StandardError; end

      # Make the film and write it to +path+, which is handed back. +search_path+ is where the
      # programs are looked for, the folders of a PATH; left out, it is this process's.
      # +scale+ is how many times the console's size each picture is shown at.
      def self.make(path, sides:, parts:, keys: ->(_frame) {}, scale: PICTURE_SCALE, search_path: ENV.fetch("PATH", ""))
        new(sides: sides, parts: parts, keys: keys, scale: scale, search_path: search_path).write(path)
      end

      def initialize(sides:, parts:, keys:, scale:, search_path:)
        refuse_bad_sides!(sides)
        refuse_bad_parts!(parts)
        refuse_bad_scale!(scale)
        @sides = sides.transform_keys(&:to_s)
        @parts = parts
        @keys = keys
        @scale = scale
        @commands = find_commands!([IMAGEMAGICK, FFMPEG], search_path)
      end

      # Play every side, put the pictures together and write the MP4 to +path+, handed back.
      def write(path)
        shown = @parts.flat_map(&:to_a)
        Dir.mktmpdir("film-") do |dir|
          @sides.each_value.with_index do |opener, side|
            screenshot_side(opener, shown, File.join(dir, side.to_s))
          end
          pictures = shown.map { |frame| compose_frame(dir, frame) }
          FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
          encode_mp4(pictures, hold_lengths(shown), dir, path)
        end
        path
      end

      private

      # Every frame up to the last shown, with its buttons, and a picture of each one shown.
      def screenshot_side(opener, shown, into)
        FileUtils.mkdir_p(into)
        wanted = shown.to_set
        running = opener.call
        (1..shown.max).each do |frame|
          running.step(1, keys: IR::Buttons.mask(@keys.call(frame)))
          running.screenshot(picture_path(into, frame)) if wanted.include?(frame)
        end
      ensure
        running.close if running.respond_to?(:close)
      end

      def picture_path(dir, frame) = File.join(dir, format("%05d.png", frame))

      # The pictures of +frame+ side by side, each doubled under a strip with its label, and the
      # frame's number at the right of the strip. +repage drops the canvas the join leaves
      # behind, which players otherwise clip each frame to.
      def compose_frame(dir, frame)
        out = File.join(dir, format("film_%05d.png", frame))
        labelled = @sides.keys.each_with_index.flat_map do |label, side|
          ["(", picture_path(File.join(dir, side.to_s), frame), "-scale", "#{@scale * 100}%",
           "-background", LABEL_STRIP_COLOR, "-gravity", "north", "-splice", "0x#{LABEL_STRIP_HEIGHT}",
           "+gravity", "-annotate", LABEL_BASELINE, literal_text(label), ")"]
        end
        system(@commands.fetch(IMAGEMAGICK), *label_settings, *labelled, "+append", "+repage",
               "-gravity", "northeast", "-annotate", FRAME_NUMBER_MARGIN, "frame #{frame}", out, exception: true)
        out
      end

      # +text+ as ImageMagick writes it word for word. -annotate reads `%` as the start of a
      # setting to fill in ("%w" is the picture's width) and a leading `@` as a file to read the
      # words from, so a label of "50% speed" or "@home" would come out as something else.
      def literal_text(text)
        escaped = text.to_s.gsub("%", "%%")
        escaped.start_with?("@") ? "\\#{escaped}" : escaped
      end

      # How every label is written: white, in the first font the computer has.
      def label_settings
        font = LABEL_FONT_PATHS.find { |path| File.exist?(path) }
        ["-fill", "white", "-pointsize", LABEL_POINT_SIZE.to_s, *(font ? ["-font", font] : [])]
      end

      # How many of the MP4's frames each shown frame is held for: one, and longer on each part's
      # last, with the film's last frame held until the film is long enough.
      def hold_lengths(shown)
        part_end = (PART_END_HOLD_SECONDS * FRAME_RATE).round
        ends = @parts.map(&:max) # max, not last: 1...10 ends on 9
        held = shown.map { |frame| ends.include?(frame) ? part_end : 1 }
        held[-1] += [(SHORTEST_FILM_SECONDS * FRAME_RATE) - held.sum, 0].max
        held
      end

      # The MP4 at the console's own rate, each held picture repeated for as long as it is held:
      # a numbered link to it for each frame of the film, which ffmpeg reads as a run of pictures.
      def encode_mp4(pictures, holds, dir, out)
        reel = File.join(dir, "reel")
        FileUtils.mkdir_p(reel)
        at = 0
        pictures.zip(holds).each do |picture, held|
          held.times { FileUtils.ln_s(picture, File.join(reel, format("%06d.png", at += 1))) }
        end
        system(@commands.fetch(FFMPEG), "-y", "-loglevel", "error", "-framerate", FRAME_RATE.to_s,
               "-i", File.join(reel, "%06d.png"), "-pix_fmt", "yuv420p", "-c:v", "libx264", out, exception: true)
      end

      # Each tool's command, found in +search_path+, or MissingTool naming every one not found.
      def find_commands!(tools, search_path)
        folders = search_path.split(File::PATH_SEPARATOR).reject(&:empty?)
        found = tools.to_h do |tool|
          [tool, tool.commands.lazy.map { |command| find_command(folders, command) }.find(&:itself)]
        end
        missing = found.select { |_, command| command.nil? }.keys
        raise MissingTool, missing_tools_message(missing) unless missing.empty?

        found
      end

      def find_command(folders, command)
        folders.map { |folder| File.join(folder, command) }.find { |path| File.file?(path) && File.executable?(path) }
      end

      def missing_tools_message(missing)
        names = missing.map(&:name).join(" and ")
        them = missing.size == 1 ? "it" : "them"
        installs = missing.map do |tool|
          "To install #{tool.name} on a Mac, run `brew install #{tool.package}`. " \
            "To install #{tool.name} on Linux, run `sudo apt install #{tool.package}`."
        end
        "A film needs #{names}. This computer does not have #{them}. #{installs.join(' ')} Then make the film again."
      end

      def refuse_bad_sides!(sides)
        return if sides.is_a?(Hash) && !sides.empty? && sides.each_value.all? { |opener| opener.respond_to?(:call) }

        raise ArgumentError, "`sides:` was #{sides.inspect}. Give a Hash of one side or more. Each key is the " \
                             "label of the side, and each value is a lambda that opens the cartridge: " \
                             "`sides: { \"ours\" => -> { Verifier.new(rom, frames: 0) } }`."
      end

      def refuse_bad_scale!(scale)
        return if scale.is_a?(Integer) && scale.positive?

        raise ArgumentError, "`scale:` was #{scale.inspect}. Give a whole number, 1 or more: `scale: 3` shows each " \
                             "picture at three times the size of the console's screen."
      end

      def refuse_bad_parts!(parts)
        good = parts.is_a?(Array) && !parts.empty? && parts.all? do |part|
          part.is_a?(Range) && part.begin.is_a?(Integer) && part.end.is_a?(Integer) && part.begin >= 1 && part.any?
        end
        return if good

        raise ArgumentError, "`parts:` was #{parts.inspect}. Give a list of frame ranges, counted from 1: " \
                             "`parts: [1..90, 200..240]`. Each range must hold one frame or more."
      end
    end
  end
end
