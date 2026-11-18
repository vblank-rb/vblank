# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyGenesisEmulator
  # ONE SEGA GENESIS (MEGA DRIVE), PLAYED A FRAME AT A TIME with nobody watching: a cartridge
  # loaded into Genesis Plus GX (a libretro core, see CoreLibrary), its buttons set from Ruby,
  # and everything a test wants to read back handed over as plain bytes — the picture of the
  # last frame, the work RAM, the video RAM, the colour memory, the vertical scroll memory, the
  # video chip's registers and the 68000's registers.
  #
  #   core = RubyGenesisEmulator::Core.new("game.gen")
  #   core.set_buttons(%i[right a])
  #   core.run_frame
  #   core.wram_read16(0x0100)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE CONSOLE PER LIBRARY: it keeps the whole machine in the library's own
  # globals. So each Core loads a copy of the library of its own (KeptCopy), and two Cores in one
  # process are two consoles that cannot see each other. The copy is loaded with its names kept
  # to itself (no RTLD_GLOBAL), or the second copy's code would call into the first's.
  #
  # The core is played through Frontend, this gem's C extension: it opens the copy, answers what
  # the core asks, and keeps the picture and the sound the core hands over until they are asked for
  # here (ext/ruby_genesis_emulator_ext/libretro_frontend.c says why that is C). So a Core can be
  # made and played in any Ractor.
  #
  # ENDIANNESS. The 68000 is big-endian: the high byte of a number is at the lower address. The
  # library keeps work RAM as 16-bit words in the host's own order, so on a little-endian machine
  # every pair of bytes is swapped in the memory it hands over. The reads here put that right, so
  # an address means what it means to the cartridge's code.
  class Core
    # libretro's names for the memories, and the probe patch's own (core/gpgx-vblank-probe.patch).
    SAVE_RAM = 0
    SYSTEM_RAM = 2
    VIDEO_RAM = 0x8001
    COLOR_RAM = 0x8002
    VERTICAL_SCROLL_RAM = 0x8003
    VDP_REGISTERS = 0x8004
    M68K_REGISTERS = 0x8005
    SPRITE_CACHE = 0x8006
    PSG_REGISTERS = 0x8007
    FM_REGISTERS = 0x8008
    PROCESSOR_TIME = 0x8009

    # How much each of the PSG's sixteen loudness steps is in the core's numbers, the last being silence,
    # and the bits of its noise setting.
    PSG_LOUDNESS = (Array.new(15) { |step| (2800 * (10**(-step / 10.0))).to_i } + [0]).freeze
    NOISE_SETTING = 7

    # libretro's joypad: the number it asks about each button by, for the buttons of the console's
    # pad as the core lays them out (its own "B" is the Genesis's B, its "A" the Genesis's C, and
    # its "Y" the Genesis's A).
    BUTTONS = { b: 0, a: 1, mode: 2, start: 3, up: 4, down: 5, left: 6, right: 7,
                c: 8, y: 9, x: 10, z: 11 }.freeze

    # The settings the core asks for, as libretro names them: none, so it keeps its own.
    SETTINGS = Ractor.make_shareable({})

    # libretro's picture format of two bytes a pixel, five bits of red, six of green and five of
    # blue: the one the core is let draw in, and the one PIXEL_COLORS reads.
    RGB565 = 2

    JOYPAD = 1

    # The picture of the usual setting: 320 pixels across and 224 lines down. A game that asks the
    # video chip for 256 across (H32) or 240 lines shows a different size, which #width and #height say.
    WIDTH = 320
    HEIGHT = 224

    # The 68000's registers in the order the probe patch hands them over.
    REGISTER_NAMES = (%i[d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7] + %i[pc sr]).freeze

    # What each 16 bit pixel of the core's picture is worth in the console's own colours: the
    # core lays a colour out as 5 bits of red, 6 of green and 5 of blue, and the console's three bits
    # of each are in the top of those (a channel at its highest is 29 of 31, as the console's normal
    # brightness is the lower half of the video chip's range). The colour comes back as 9 bits: red
    # in the low three, then green, then blue — the same layout #color_ram reads.
    PIXEL_COLORS = Array.new(0x10000) do |pixel|
      ((pixel >> 13) & 7) | (((pixel >> 8) & 7) << 3) | (((pixel >> 2) & 7) << 6)
    end.freeze

    attr_reader :frames, :width, :height

    # +rom_path+ is the cartridge. +save_dir+ is where the core is told to keep files; a core made
    # without one keeps them in a folder of its own that is gone with it. +settings+ are core settings
    # by libretro's names, over SETTINGS: "genesis_plus_gx_psg_channel_0_volume" => "0" silences the
    # first square voice. The core reads them as it loads the cartridge, so they hold for its life.
    def initialize(rom_path, save_dir: nil, settings: {})
      @dir = Dir.mktmpdir("ruby-genesis-emulator")
      @frames = 0
      @picture = nil
      @audio = "".b
      @width = WIDTH
      @height = HEIGHT
      start_frontend(save_dir || @dir, SETTINGS.merge(settings))
      load_cartridge(rom_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a Genesis controller has no #{unknown.join(', ')} button" unless unknown.empty?

      @frontend.set_buttons(port, buttons.uniq.sum { |button| 1 << BUTTONS.fetch(button) })
    end

    # Plays one frame: up to the moment the console starts its next picture.
    def run_frame
      @frontend.run
      @audio << @frontend.drain_audio
      update_picture
      @frames += 1
      self
    end

    # The last frame's picture as the console's own colours: a 9 bit number for each pixel, #width
    # by #height of them row by row, red in the low three bits, then green, then blue.
    #
    # A picture that has not changed since the last one asked for is the same list again: most
    # frames of a game change little, and comparing the bytes is far quicker than turning them into
    # colours. So the list must not be changed by whoever is given it.
    def colors
      return @colors if @colors && @colors_of == video_buffer

      @colors_of = video_buffer
      # A lookup Array#values_at makes in C for every pixel, not a Ruby block run for each.
      @colors = PIXEL_COLORS.values_at(*video_buffer.unpack("v*")).freeze
    end

    # The last frame's picture as the core drew it: #width × #height pixels, two bytes each, row
    # by row.
    def video_buffer = @picture || ("\0".b * (@width * @height * 2))

    # THE CONSOLE'S WHOLE STATE, as Genesis Plus GX saves it: every chip's memory and registers, in
    # its own format, for #unserialize to put back on a console playing the same cartridge.
    def serialize = @frontend.serialize

    def unserialize(state)
      raise ArgumentError, "Genesis Plus GX did not take this state. It must be one this core saved." unless @frontend.unserialize(state)

      self
    end

    # --- the memories ---

    # All 64K of work RAM, in the order the cartridge's code sees it, at $FF0000 to $FFFFFF.
    def wram = memory(SYSTEM_RAM).unpack("v*").pack("n*")

    # Video RAM, 64K, as the video chip keeps it: the tiles and the maps of them, a word's high
    # byte at the even address.
    def vram = memory(VIDEO_RAM).unpack("v*").pack("n*")

    # The colour memory as the core keeps it: 64 colours, each a number of 9 bits with red in the
    # low three bits, then green, then blue.
    def color_ram = memory(COLOR_RAM).unpack("v*")

    # The same 64 colours as 16-bit words in the layout the console's own code writes them in:
    # 0000 BBB0 GGG0 RRR0.
    def cram = color_ram.map { |color| ((color & 7) << 1) | (((color >> 3) & 7) << 5) | (((color >> 6) & 7) << 9) }.pack("v*")

    # The vertical scroll memory: 40 words, two for each pair of columns of the picture.
    def vsram = memory(VERTICAL_SCROLL_RAM)

    # The video chip's 24 registers, a byte each.
    def vdp_registers = memory(VDP_REGISTERS).bytes.first(24)

    # The sprite table as the video chip keeps its own copy of it (1K, as the chip reads it).
    def sprite_cache = memory(SPRITE_CACHE)

    # The PSG's eight registers as a cartridge wrote them: for each of its three square voices the length of
    # its wave then its loudness (fifteen is silent), then the noise voice's setting and its loudness. The
    # core keeps a loudness as how much that step of two decibels is, so it is turned back into the step.
    def psg_registers
      memory(PSG_REGISTERS).unpack("l<*").each_with_index.map do |value, register|
        next value & NOISE_SETTING if register == 6
        next value if register.even?

        PSG_LOUDNESS.index(PSG_LOUDNESS.min_by { |loudness| (loudness - value).abs })
      end
    end

    # The FM chip's registers as it was last told them, a byte each: 256 for its first three voices
    # and the settings for the whole chip, and 256 for its other three. The chip has no way to read
    # them back, so the probe patch keeps this copy as they are written.
    def fm_registers = memory(FM_REGISTERS)

    # Every sample of sound made since the last call, as signed numbers: left, right, left, right.
    def take_audio
      samples = @audio.unpack("s<*")
      @audio = "".b
      samples
    end

    # WHERE THE PROCESSOR'S TIME WENT since this was last asked: each address an instruction started
    # at, and the core's cycles spent there, seven to a cycle of the 68000, whatever it stood still
    # for included. A line of the picture is 3420 of them. The first ask starts the count and
    # answers nothing.
    def take_processor_time
      bytes = memory(PROCESSOR_TIME)
      bytes.unpack("L<Q<" * (bytes.bytesize / 12)).each_slice(2).to_h
    end

    # The 68000's registers by name (REGISTER_NAMES): the data registers, the address registers,
    # the program counter and the status register.
    def registers = REGISTER_NAMES.zip(memory(M68K_REGISTERS).unpack("L<*")).to_h

    # Work RAM read in place, at +address+ (only its low 16 bits matter, so $FF0100 and $0100 are
    # the same byte), the high byte first as the console keeps a number. Each address is taken within
    # the 64K as the first is, so a read that runs past $FFFFFF goes on from $FF0000.
    def wram_read8(address) = @frontend.memory_read(SYSTEM_RAM, (address & 0xFFFF) ^ 1, 1).getbyte(0)
    def wram_read16(address) = wram_bytes(address, 2).unpack1("n")
    def wram_read32(address) = wram_bytes(address, 4).unpack1("N")
    def wram_bytes(address, count) = Array.new(count) { |i| wram_read8(address + i) }.pack("C*")
    def wram_write8(address, value) = @frontend.memory_write(SYSTEM_RAM, (address & 0xFFFF) ^ 1, [value & 0xFF].pack("C"))
    def wram_write32(address, value) = [value & 0xFFFFFFFF].pack("N").bytes.each_with_index { |byte, i| wram_write8(address + i, byte) }

    # The cartridge's save memory, a byte for each odd address from $200000, as far as the last byte
    # written that is not $FF (what the chip holds where nothing was saved): empty for a cartridge that
    # saved nothing. The core keeps it only in memory and writes no file of it.
    def save_ram = memory(SAVE_RAM)

    # Unloads the cartridge, shuts the core and lets go of its library.
    def destroy
      return unless @shutdown

      ObjectSpace.undefine_finalizer(self)
      @shutdown.call
      @shutdown = nil
    end

    # A CONSOLE NOBODY DESTROYED IS SHUT BY RUBY when it collects the Core, the same way #destroy
    # shuts it. It must not be left as it is. Ruby closes the copy's lock when it collects it, and the
    # copy is handed to the next console made in this process, while the library is still open here
    # with the old cartridge in it, never shut: the next console's start goes on top of it. So the
    # frontend is closed first and the copy given back after.
    #
    # The finalizer must hold nothing that holds the Core, or the Core is never collected. The
    # frontend's callbacks are C and hold nothing of Ruby's, so holding the frontend is enough.
    class Shutdown
      def initialize(frontend, copy, dir)
        @frontend = frontend
        @copy = copy
        @dir = dir
      end

      # Unloads the cartridge, shuts the core, closes the library and gives the copy back. A finalizer
      # is handed the Core's object id, which is not needed here.
      def call(_object_id = nil)
        return unless @frontend

        @frontend.close
        @copy.give_back
        @frontend = nil
        FileUtils.rm_rf(@dir)
      end
    end

    private

    def memory(id) = @frontend.memory(id)

    # Opens a copy of the core of this Core's own and starts it, keeping the picture to the format
    # PIXEL_COLORS reads.
    def start_frontend(save_dir, settings)
      copy = KeptCopy.take
      begin
        @frontend = Frontend.new(copy.path, @dir, save_dir, settings, RGB565)
      rescue StandardError, LoadError
        copy.give_back
        FileUtils.rm_rf(@dir)
        raise
      end
      @shutdown = Shutdown.new(@frontend, copy, @dir)
      ObjectSpace.define_finalizer(self, @shutdown)
      refuse_unpatched_core!
    end

    def refuse_unpatched_core!
      return if @frontend.memory_size(VIDEO_RAM) == 0x10000

      destroy
      raise LoadError, "#{CoreLibrary.path} is a Genesis Plus GX core built without this gem's probe patch, so it " \
                       "cannot hand over the console's memories. Build it with `rake compile_core` in " \
                       "ruby-genesis-emulator/."
    end

    # The picture handed over by the frame just played, if there was one. A frame the core drew
    # nothing new for keeps the last.
    def update_picture
      bytes, width, height = @frontend.drain_picture
      return unless bytes

      @width = width
      @height = height
      @picture = bytes
    end

    # Hands the core the cartridge's path and bytes, and plugs a pad into each of the two ports.
    def load_cartridge(rom_path)
      loaded = @frontend.load_game(File.expand_path(rom_path), File.binread(rom_path))
      raise ArgumentError, "Genesis Plus GX would not load #{rom_path}" unless loaded

      @frontend.set_controller_port_device(0, JOYPAD)
      @frontend.set_controller_port_device(1, JOYPAD)
    end
  end
end
