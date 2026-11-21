# frozen_string_literal: true

require "English"
require "zlib"

module VBlank
  module Diagnostics
    class Film
      # One picture of a side, as Film keeps it between the side and the reel, a row at a time from
      # the top: +colours+, the console's 15-bit colours, where the side answered `screen_picture`;
      # else +rgb+, three bytes a pixel (red, green, blue, eight bits a channel), as ImageMagick read
      # the side's PNG.
      Shot = Data.define(:width, :height, :colours, :rgb) do
        # True when every pixel is the first one's colour.
        def one_color?
          return colours.all?(colours.first) if colours

          rgb == rgb.byteslice(0, 3) * (width * height)
        end

        # The same colour all over, +width+ by +height+: a blank picture made another size.
        def resized(width, height)
          count = width * height
          with(width: width, height: height, colours: colours && Array.new(count, colours.first),
               rgb: rgb && (rgb.byteslice(0, 3) * count))
        end

        # Its pixels three bytes each, each +scale+ times across: +wide+ answers a 15-bit colour's
        # bytes so (Film#wide_channels).
        def widened_rgb(scale, wide)
          return colours.map { |colour| wide[colour] }.join if colours
          return rgb if scale == 1

          rgb.unpack("a3" * (width * height)).map { |pixel| pixel * scale }.join
        end
      end

      # A side's picture as the reel wants it: each pixel +scale+ times across (the rows are repeated
      # +scale+ times down as the reel writes them), squeezed for the trip to the reel, which is
      # cheap where most of a picture is runs of one colour. Made where the side plays, so a side in
      # a process of its own does this work there.
      Widened = Data.define(:width, :height, :squeezed) do
        def self.from(shot, scale, wide)
          new(width: shot.width * scale, height: shot.height,
              squeezed: Zlib::Deflate.deflate(shot.widened_rgb(scale, wide), Zlib::BEST_SPEED))
        end

        def rows = Zlib::Inflate.inflate(squeezed)
      end

      # The film's pictures, put together in Ruby and handed to ffmpeg as they arrive. Film adds each
      # shown frame once every side has its picture (#add); the reel lays the pictures side by side,
      # each +scale+ times its size under a strip with its label, writes the frame's number at the
      # right of the strip, and hands the frame's pixels to one ffmpeg as they stand (raw video, three
      # bytes a pixel), repeated for as long as the frame is held. ffmpeg writes the MP4's pictures to
      # +out+. No picture is written to the disk on the way.
      #
      # The words are drawn once. ImageMagick draws each side's strip with its label, and the letters
      # of "frame " and each digit, when the first frame arrives (sizes are known then); every frame
      # after is those pieces put in place. A frame's number is its digits side by side, each as
      # ImageMagick draws it alone, so it can stand a pixel or so from where the whole number drawn at
      # once would.
      class Reel
        # +commands+ are Film's (ImageMagick's and ffmpeg's). +labels+ are the sides' labels, in
        # order. +holds+ is how many of the MP4's frames each frame added is held for, in the order
        # added.
        def initialize(commands:, labels:, scale:, holds:, out:)
          @commands = commands
          @labels = labels
          @scale = scale
          @holds = holds
          @out = out
          @added = 0
          @ffmpeg = nil
        end

        # The next frame of the film, +frame+, and each side's picture of it (Widened), in order.
        def add(frame, pictures)
          start(pictures) unless @ffmpeg
          picture = composed(frame, pictures)
          @holds.fetch(@added).times { @ffmpeg.write(picture) }
          @added += 1
        rescue Errno::EPIPE
          raise ArgumentError, FFMPEG_STOPPED
        end

        # The MP4's pictures written. Raises where ffmpeg could not write them.
        def finish
          return unless @ffmpeg

          @ffmpeg.close
          raise ArgumentError, FFMPEG_STOPPED unless $CHILD_STATUS.success?
        rescue Errno::EPIPE
          raise ArgumentError, FFMPEG_STOPPED
        end

        # A broken pipe to ffmpeg is ffmpeg stopped: what it said on its way out is above this.
        FFMPEG_STOPPED = "ffmpeg could not write the film's pictures. What ffmpeg printed above says why."

        # Stops where it stands, after a side went wrong: ffmpeg is stopped.
        def abandon
          return if @ffmpeg.nil? || @ffmpeg.closed?

          Process.kill(:KILL, @ffmpeg.pid)
          @ffmpeg.close
        rescue Errno::ESRCH, Errno::EPIPE, IOError
          nil # ffmpeg ended already
        end

        private

        # The film's size from the first frame's pictures, the words drawn, and ffmpeg started.
        def start(pictures)
          @widths = pictures.map(&:width)
          @picture_height = pictures.map(&:height).max * @scale
          @width = @widths.sum
          @strip = strip_rows
          @digits = ("0".."9").to_h { |digit| [digit, drawn_words(digit)] }
          @frame_word = drawn_words("frame ")
          @ffmpeg = IO.popen([@commands.fetch(FFMPEG), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                              "-s", "#{@width}x#{LABEL_STRIP_HEIGHT + @picture_height}", "-r", FRAME_RATE.to_s, "-i", "-",
                              "-pix_fmt", "yuv420p", "-c:v", "libx264", @out], "wb")
        end

        # One frame's pixels: the strip with the frame's number, then the pictures a row at a time,
        # each row +scale+ times. A side shorter than the tallest is filled below with the strip's colour.
        def composed(frame, pictures)
          sides = pictures.map(&:rows)
          rows = numbered_strip(frame)
          (0...@picture_height).each do |line|
            source = line / @scale
            rows << sides.zip(pictures, @widths).map do |all, picture, width|
              source < picture.height ? all.byteslice(source * width * 3, width * 3) : blank_row(width)
            end.join
          end
          rows.join
        end

        def blank_row(width) = strip_color * width

        def strip_color = @strip_color ||= [LABEL_STRIP_COLOR.delete_prefix("#")].pack("H6")

        # The strip's rows with "frame N" over its right end, FRAME_NUMBER_MARGIN in from the corner.
        def numbered_strip(frame)
          words = [@frame_word, *frame.to_s.chars.map { |digit| @digits.fetch(digit) }]
          height = [words.map(&:height).max, LABEL_STRIP_HEIGHT - number_top].min
          width = words.sum(&:width)
          left = @width - number_right - width
          @strip.each_with_index.map do |row, line|
            next row.dup unless line >= number_top && line < number_top + height

            drawn = words.map { |word| word.rgb.byteslice((line - number_top) * word.width * 3, word.width * 3) }.join
            row.byteslice(0, left * 3) + drawn + row.byteslice((left + width) * 3..)
          end
        end

        def number_right = FRAME_NUMBER_MARGIN[/\A\+(\d+)/, 1].to_i
        def number_top = FRAME_NUMBER_MARGIN[/\+(\d+)\z/, 1].to_i

        # The strip over every side, its label written on each, as rows of pixels.
        def strip_rows
          strips = @labels.zip(@widths).map do |label, width|
            ppm = imagemagick("-size", "#{width}x#{LABEL_STRIP_HEIGHT}", "xc:#{LABEL_STRIP_COLOR}", *label_settings,
                              "-annotate", LABEL_BASELINE, literal_text(label))
            ppm.rgb
          end
          (0...LABEL_STRIP_HEIGHT).map do |line|
            strips.zip(@widths).map { |rgb, width| rgb.byteslice(line * width * 3, width * 3) }.join
          end
        end

        # +text+ drawn alone on the strip's colour, as wide as ImageMagick sets it.
        def drawn_words(text)
          imagemagick("-background", LABEL_STRIP_COLOR, *label_settings, "label:#{literal_text(text)}")
        end

        # What ImageMagick makes of +arguments+, read back as a Shot.
        def imagemagick(*arguments)
          ppm = IO.popen([@commands.fetch(IMAGEMAGICK), *arguments, "-depth", "8", "ppm:-"], "rb", &:read)
          raise ArgumentError, "ImageMagick could not draw the film's words." unless $CHILD_STATUS.success?

          Film.shot_from_ppm(ppm)
        end

        # +text+ as ImageMagick writes it word for word. -annotate and label: read `%` as the start of
        # a setting to fill in ("%w" is the picture's width) and a leading `@` as a file to read the
        # words from, so a label of "50% speed" or "@home" would come out as something else.
        def literal_text(text)
          escaped = text.to_s.gsub("%", "%%")
          escaped.start_with?("@") ? "\\#{escaped}" : escaped
        end

        # How every word is written: white, in the first font the computer has.
        def label_settings
          font = LABEL_FONT_PATHS.find { |path| File.exist?(path) }
          ["-fill", "white", "-pointsize", LABEL_POINT_SIZE.to_s, *(font ? ["-font", font] : [])]
        end
      end
    end
  end
end
