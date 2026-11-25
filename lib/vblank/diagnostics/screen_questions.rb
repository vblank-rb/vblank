# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The questions asked of a whole screen, answered in Ruby, for a console whose emulator is not the
    # Advance's. The Advance's emulator answers them in its C extension (RubyGBAEmulator::Screen, see
    # Emulator.screen_questions), and this gives the same answers to the same questions, word for word
    # and number for number: the Genesis's, the Super Nintendo's and the PlayStation's emulators hand
    # their picture over in the same four bytes a pixel. A game for one of those has no use for the
    # Advance's emulator, and a `path:` source in its Gemfile never builds that emulator's extension, so
    # its picture is never asked through that extension (Console::Kit#screen_questions).
    #
    # A screen is four bytes a pixel, red, green, blue and a byte of nothing, a row at a time from the
    # top. Every answer is at five bits a channel, the precision a console shows, unless it says
    # otherwise: the top five bits of each byte.
    #
    # It is slower than the C, and is written so the common case costs little. Two screens of the same
    # bytes are known to be one picture in one comparison of the strings, which is nearly every frame of
    # two cartridges that agree, and a row of the same bytes holds no difference.
    module ScreenQuestions
      module_function

      BYTES_PER_PIXEL = 4
      BITS_SHOWN = 0x00F8F8F8 # The top five bits of red, green and blue
      BITS_HELD = 0x00FFFFFF  # All eight bits of red, green and blue

      # How many bytes of two screens #same? holds side by side at once: a stretch of the same bytes
      # is passed over without a number made for any pixel in it.
      STRETCH_BYTES = 64 * BYTES_PER_PIXEL

      # The screen as the console's 15-bit colours, two bytes a pixel, low byte first.
      def colors(screen) = color_list(screen).pack("v*")

      # The same colours as a list of numbers, one for each pixel.
      def color_list(screen) = pixels_of(screen).map { |px| console_color(px) }

      # The one colour every pixel is, or nil when there is more than one: the console's 15-bit colour
      # at five bits, and the number the emulator holds, red in the low byte, at eight.
      def only_color(screen, bits = 5)
        looked_at = bits_looked_at(bits)
        pixels = pixels_of(screen)
        first = pixels.first or return nil
        return nil if pixels.any? { |px| (px ^ first) & looked_at != 0 }

        bits == 5 ? console_color(first) : first & BITS_HELD
      end

      # Whether two screens are the same picture: every pixel the same five bits of each channel.
      def same?(one, other)
        pair_pixel_count(one, other)
        return true if one == other

        (0...one.bytesize).step(STRETCH_BYTES).all? do |start|
          next true if one.byteslice(start, STRETCH_BYTES) == other.byteslice(start, STRETCH_BYTES)

          one.byteslice(start, STRETCH_BYTES).unpack("V*").zip(other.byteslice(start, STRETCH_BYTES).unpack("V*"))
             .none? { |a, b| (a ^ b) & BITS_SHOWN != 0 }
        end
      end

      # The screen again, with every pixel of the colour most of it is made black, every byte nought.
      # When two colours are as common, the one that got there first is taken out, as the C does.
      def without_commonest_color(screen)
        colors = color_list(screen)
        return screen.b.freeze if colors.empty?

        commonest = commonest_color(colors)
        nought = "\0".b * BYTES_PER_PIXEL
        copy = screen.b
        colors.each_with_index do |color, at|
          copy[at * BYTES_PER_PIXEL, BYTES_PER_PIXEL] = nought if color == commonest
        end
        copy.freeze
      end

      # How two screens differ, as { count:, box:, at:, colors: }, or nil when they are one picture.
      # +width+ is how many pixels make a row; +looked_at+ a string of a byte a pixel, nought for one
      # left out.
      def difference(one, other, width, looked_at = nil)
        count = pair_pixel_count(one, other)
        refuse_wrong_width!(width, count)
        refuse_wrong_looked_at!(looked_at, count)

        found = rows_differing(one, other, width, looked_at)
        return nil if found.count.zero?

        first = found.first
        { count: found.count, box: [found.left, found.top, found.right - found.left + 1, found.bottom - found.top + 1],
          at: [first % width, first / width],
          colors: [console_color(pixel_at(one, first)), console_color(pixel_at(other, first))] }
      end

      # The red, green and blue of every pixel added up: each 0 to 31 at five bits, 0 to 255 at eight.
      def brightness(screen, bits = 5)
        bits_looked_at(bits)
        if bits == 5
          pixels_of(screen).sum { |px| ((px >> 3) & 0x1F) + ((px >> 11) & 0x1F) + ((px >> 19) & 0x1F) }
        else
          pixels_of(screen).sum { |px| (px & 0xFF) + ((px >> 8) & 0xFF) + ((px >> 16) & 0xFF) }
        end
      end

      # The console's own 15-bit colour for one pixel: red in the low five bits, then green, then blue.
      def console_color(px) = ((px >> 3) & 0x001F) | ((px >> 6) & 0x03E0) | ((px >> 9) & 0x7C00)

      # Every pixel of +screen+ as a number, red in the low byte.
      def pixels_of(screen)
        pixel_count(screen)
        screen.unpack("V*")
      end

      def pixel_at(screen, at) = screen.unpack1("V", offset: at * BYTES_PER_PIXEL)

      def pixel_count(screen)
        length = screen.bytesize
        unless (length % BYTES_PER_PIXEL).zero?
          raise ArgumentError, "A screen holds #{BYTES_PER_PIXEL} bytes for each pixel. This one holds #{length} bytes, " \
                               "which is not a whole number of pixels. Give the screen as the emulator hands it over " \
                               "(`frame_buffer`)."
        end

        length / BYTES_PER_PIXEL
      end

      def pair_pixel_count(one, other)
        count = pixel_count(one)
        other_count = pixel_count(other)
        unless count == other_count
          raise ArgumentError, "Two screens must hold the same number of pixels to be compared. These hold #{count} and " \
                               "#{other_count}. Give two screens as the emulator hands them over (`frame_buffer`), from " \
                               "cartridges of one kind of console."
        end

        count
      end

      # The mask of the bits a question looks at, for 5 or 8 bits a channel.
      def bits_looked_at(bits)
        return BITS_SHOWN if bits == 5
        return BITS_HELD if bits == 8

        raise ArgumentError, "The bits of a channel must be 5 or 8. They were #{bits}. Give 5 for the colours a console " \
                             "shows, or 8 for the colours as the emulator holds them."
      end

      def refuse_wrong_width!(width, count)
        return if width.positive? && (count % width).zero?

        raise ArgumentError, "The width must be how many pixels are in one row of the screen. It was #{width}, and these " \
                             "screens hold #{count} pixels, which is not a whole number of rows that wide. Give the width " \
                             "of the screen, which is 240 for a Game Boy Advance."
      end

      def refuse_wrong_looked_at!(looked_at, count)
        return if looked_at.nil? || looked_at.bytesize == count

        raise ArgumentError, "What is looked at must hold one byte for each pixel. It holds #{looked_at.bytesize} bytes, " \
                             "and these screens hold #{count} pixels. Give a string of #{count} bytes: 0 for a pixel to " \
                             "leave out, and 1 for a pixel to look at."
      end

      # How many pixels differ, the first of them, and the columns and rows they lie between.
      Differing = Data.define(:count, :first, :left, :right, :top, :bottom)

      # The pixels that differ, a row at a time: a row of the same bytes is passed over whole.
      def rows_differing(one, other, width, looked_at)
        count = 0
        first = top = bottom = nil
        left = width
        right = -1
        row_bytes = width * BYTES_PER_PIXEL
        (one.bytesize / row_bytes).times do |y|
          start = y * row_bytes
          next if one.byteslice(start, row_bytes) == other.byteslice(start, row_bytes)

          mine = one.unpack("V#{width}", offset: start)
          theirs = other.unpack("V#{width}", offset: start)
          width.times do |x|
            at = (y * width) + x
            next if looked_at && looked_at.getbyte(at).zero?
            next if ((mine[x] ^ theirs[x]) & BITS_SHOWN).zero?

            count += 1
            first, top = at, y unless first
            bottom = y
            left = x if x < left
            right = x if x > right
          end
        end
        Differing.new(count: count, first: first, left: left, right: right, top: top, bottom: bottom)
      end

      # The colour most pixels are. Colour 0 starts as the commonest, counted like any other, and a
      # colour takes its place only by passing it, so of two as common the first to get there wins.
      def commonest_color(colors)
        seen = Hash.new(0)
        commonest = 0
        colors.each do |color|
          seen[color] += 1
          commonest = color if seen[color] > seen[commonest]
        end
        commonest
      end
      private_class_method :pixel_at, :pixel_count, :pair_pixel_count, :bits_looked_at, :refuse_wrong_width!,
                           :refuse_wrong_looked_at!, :rows_differing, :commonest_color
      private_constant :Differing
    end
  end
end
