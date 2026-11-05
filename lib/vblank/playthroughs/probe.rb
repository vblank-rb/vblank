# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Playthroughs
    # ANY CARTRIDGE DRIVEN A FRAME AT A TIME BY SOMEBODY WATCHING IT, and read by the names its
    # decompilation gave to what it keeps in memory. It is how a port measures its original: the
    # decompilation says what the game does, and this says how much, frame by frame, from the real
    # cartridge in the emulator.
    #
    #   labels = { "wMode" => 0xC0A0, "wShipX" => [0xC0B4, :u16] }
    #   Probe.open("rocket.gbc", labels: labels) do |probe|
    #     probe.press_until(:a, "the first level", within: 600) { probe.read("wMode") == 3 }
    #     probe.read("wShipX")   # => 1234, read as the label says
    #     probe.reader.screenshot("level.png")
    #   end
    #
    # IT WAITS ON THE GAME, never on a count of frames: step_until and press_until play until the
    # block says yes, so the drive keeps working when a screen takes a frame longer than it did. One
    # that never says yes within its frames raises NeverHappened, naming what was waited for, the
    # frame it stopped on, and the values of the labels it was told to watch.
    #
    # WHAT THE GAME SUPPLIES: the cartridge (a path, or anything Diagnostics::CartridgeFile takes) and
    # its labels, as its decompilation's RAM map has them: a name to an address on the console's bus,
    # or to an address and how it is read (WIDTHS), one byte unsigned unless said. A read or a write
    # takes a label or an address. +save+ (an IR::SaveImage) is what the save memory holds as the
    # console is switched on: a save file of the player's, say.
    #
    # THE SAVE MEMORY GOES TO A FOLDER OF ITS OWN, made when the probe opens and removed when it
    # closes, so no run finds a save another left; +save_dir+ names one to keep instead.
    #
    # Everything else is read through #reader, the one reader over a running cartridge
    # (Diagnostics::Verifier): the picture, its pixels and colours, the sound, each console its own
    # way. Step the cartridge through the probe, never the reader, or #frame goes out of step.
    class Probe
      # What was waited for did not happen in the frames allowed.
      class NeverHappened < StandardError; end

      # How a value in memory is read: how many bytes, and whether it is signed. Three bytes is the
      # 65816's long address (a routine's, say), kept low byte first, and only a console whose
      # processor reads a number at any address keeps one (Console::Kit#words_at_any_address?).
      Width = Data.define(:bytes, :signed)
      WIDTHS = Ractor.make_shareable({ u8: Width.new(1, false), s8: Width.new(1, true), u16: Width.new(2, false),
                                       s16: Width.new(2, true), u24: Width.new(3, false), s24: Width.new(3, true),
                                       u32: Width.new(4, false), s32: Width.new(4, true) })

      # A label: where it is, and how it is read.
      Label = Data.define(:address, :as)

      # How long a press holds its button, and how long it lets go after: a menu watches for the
      # frame a button goes down, so it must come up again before the next press counts.
      PRESS_FRAMES = 4
      RELEASE_FRAMES = 8

      # The reader over the running cartridge, and how many frames have been played since power-on.
      attr_reader :reader, :frame

      # A probe on +cartridge+ for the length of the block, closed when it ends; without a block, the
      # probe, for the caller to close.
      def self.open(cartridge, labels: {}, save: nil, save_dir: nil)
        probe = new(cartridge, labels: labels, save: save, save_dir: save_dir)
        return probe unless block_given?

        begin
          yield probe
        ensure
          probe.close
        end
      end

      def initialize(cartridge, labels: {}, save: nil, save_dir: nil)
        @labels = labels.to_h { |name, place| [name.to_s, label_from(place)] }
        @owns_save_dir = save_dir.nil?
        @save_dir = save_dir || Dir.mktmpdir("vblank-probe")
        cartridge = Diagnostics::CartridgeFile.new(cartridge) unless cartridge.respond_to?(:console)
        @kit = Console.for(cartridge.console)
        @reader = Diagnostics::Verifier.new(cartridge, frames: 0, save: save, save_dir: @save_dir)
        @frame = 0
      rescue StandardError
        FileUtils.remove_entry(@save_dir, true) if @owns_save_dir && @save_dir
        raise
      end

      # Play +frames+ frames holding +holding+: a button, a list of them, nil for none, or a block
      # (anything answering `call`) handed the probe before each frame and answering what to hold.
      def step(frames = 1, holding: nil)
        return step_holding_buttons(frames, holding) unless holding.respond_to?(:call)

        frames.times { step_holding_buttons(1, holding.call(self)) }
        self
      end

      # Press +button+ once: down for a few frames, then up for a few, which is what a menu waits for.
      def press(button)
        step(PRESS_FRAMES, holding: button)
        step(RELEASE_FRAMES)
      end

      # Play a frame at a time holding +holding+ (as #step takes it) until the block says yes, at most
      # +within+ frames. The block is asked before each frame, so a game already there plays none.
      # +what+ says what is waited for, and +watch+ the labels whose values the error gives if it never
      # happens.
      def step_until(what, within:, holding: nil, watch: [])
        within.times do
          return self if yield(self)

          step(1, holding: holding)
        end
        return self if yield(self)

        raise NeverHappened, never_happened_message(what, "#{within} frames", watch)
      end

      # Press +button+ again and again until the block says yes, at most +within+ presses. The block
      # is asked on every frame, so the probe stops on the frame it first says yes, part way through
      # a press if that is when.
      def press_until(button, what, within:, watch: [])
        within.times do
          [[button, PRESS_FRAMES], [nil, RELEASE_FRAMES]].each do |held, frames|
            frames.times do
              return self if yield(self)

              step(1, holding: held)
            end
          end
        end
        return self if yield(self)

        raise NeverHappened, never_happened_message(what, "#{within} presses of #{button}", watch)
      end

      # The value at +place+ (a label or an address) now, read +as+ one of WIDTHS (as the label says,
      # or one byte unsigned), in the console's own byte order, as its processor keeps it. Where a
      # value of two or more bytes can be, and whether three bytes are one value, is the processor's
      # rule too (Console::Kit#words_at_any_address?); a read it would not make is refused. Three
      # bytes are read one at a time, low byte first, so each is the byte the console has there.
      def read(place, as: nil)
        at, width = located(place, as)
        value = case width.bytes
                when 1 then @reader.mem8(at)
                when 2 then @reader.mem16(at)
                when 3 then (0..2).sum { |offset| @reader.mem8(at + offset) << (offset * 8) }
                else @reader.mem32(at)
                end
        width.signed && value >= (1 << ((width.bytes * 8) - 1)) ? value - (1 << (width.bytes * 8)) : value
      end

      # +count+ bytes from +place+ (a label or an address), as a binary string.
      def read_bytes(place, count)
        at, = located(place, :u8)
        Array.new(count) { |offset| @reader.mem8(at + offset) }.pack("C*")
      end

      # Put +value+ at +place+ (a label or an address), written +as+ one of WIDTHS, and leave the bytes
      # beside it as they were. It is for reaching a state no drive reaches cheaply (fewer lives than
      # a new game gives), so say beside anything measured after one that it was reached this way.
      #
      # The emulator writes a whole word of four bytes at a time, so the word holding the value is
      # read, changed in its place, and written back: the bytes beside it are written again with
      # what they held, which is no change in memory and can be one in a register the console acts
      # on when it is written. A value the Color keeps across two words is written into each of them
      # in turn. Only the consoles whose emulator writes memory can be written (the Advance and the
      # Color, whose processors keep the low byte first); on another it is refused saying so.
      def write(place, value, as: nil)
        at, width = located(place, as)
        (at...(at + width.bytes)).group_by { |address| address & ~3 }.each do |boundary, addresses|
          write_into_word(boundary, addresses.to_h { |address| [address, (value >> ((address - at) * 8)) & 0xFF] })
        end
        self
      end

      # Write the console's whole state to +path+, to come back to with #load_state.
      def save_state(path)
        @reader.save_state(path.to_s)
        self
      end

      # Put the console back as #save_state left it, +frame+ frames from power-on (the frame it was
      # saved on, which the state file does not hold).
      def load_state(path, frame:)
        @reader.load_state(path)
        @frame = frame
        self
      end

      # Shut the emulator, and remove the save folder unless it was named. The emulator writes its
      # save as it shuts, so the folder goes after.
      def close
        @reader.close
      ensure
        FileUtils.remove_entry(@save_dir, true) if @owns_save_dir
      end

      private

      def step_holding_buttons(frames, buttons)
        @reader.step(frames, keys: Playthrough.key_mask(Array(buttons)))
        @frame += frames
        self
      end

      # The word at +boundary+ (a multiple of four) with +bytes+ (an address to its byte) put in it,
      # read and written back once, low byte first.
      def write_into_word(boundary, bytes)
        word = bytes.reduce(@reader.mem32(boundary)) do |kept, (address, byte)|
          shift = (address - boundary) * 8
          (kept & ~(0xFF << shift) & 0xFFFF_FFFF) | (byte << shift)
        end
        @reader.write32(boundary, word)
      end

      def label_from(place)
        at, as = Array(place)
        width_of(as || :u8)
        Label.new(address: Integer(at), as: as || :u8)
      end

      # The address of +place+ and the width to read it as: +as+ if said, else the label's, else a byte.
      def located(place, as)
        label = place.is_a?(Integer) ? Label.new(address: place, as: :u8) : @labels.fetch(place.to_s) { refuse_unknown_label!(place) }
        width = width_of(as || label.as)
        unless @kit.words_at_any_address?
          refuse_three_bytes!(width)
          refuse_misaligned!(place, label.address, width)
        end
        [label.address, width]
      end

      # A processor that keeps its values aligned reads 1, 2 or 4 bytes, and never 3 as one value.
      def refuse_three_bytes!(width)
        return unless width.bytes == 3

        raise ArgumentError, "A #{@kit.title} reads a number of 1, 2 or 4 bytes, not 3. To fix this, read it as " \
                             "one of those, or read its bytes with read_bytes."
      end

      # A value of two or four bytes at an address its processor does not read it at
      # (Console::Kit#value_alignment).
      def refuse_misaligned!(place, at, width)
        boundary = @kit.value_alignment(width.bytes)
        return if (at % boundary).zero?

        where = boundary == 2 ? "an even address" : "a multiple of #{boundary}"
        raise ArgumentError, "#{place} is at #{format('0x%X', at)}. A #{@kit.title} reads a value of #{width.bytes} " \
                             "bytes only at #{where}. Use a smaller width, or the right address."
      end

      def refuse_unknown_label!(place)
        raise ArgumentError, "No label is named #{place}. Give the probe the label in labels:, or use its address."
      end

      def width_of(as)
        WIDTHS.fetch(as) { raise ArgumentError, "A value is read as one of #{WIDTHS.keys.map(&:inspect).join(', ')}, not #{as.inspect}." }
      end

      def never_happened_message(what, waited, watch)
        values = watch.map { |label| "#{label} is #{read(label)}" }
        ["The cartridge did not reach #{what} in #{waited}. It stopped on frame #{@frame}.",
         ("#{values.join(', ')}." unless values.empty?)].compact.join(" ")
      end
    end
  end
end
