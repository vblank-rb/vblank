# frozen_string_literal: true

require "fiddle"
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
  # The core talks back through functions it is handed (the libretro callbacks): it asks its
  # settings through the environment callback, hands over each finished picture and each batch of
  # sound, and asks which buttons are down. Those are Ruby blocks wrapped as C functions (Fiddle
  # closures), kept alive here for as long as the core is.
  #
  # ENDIANNESS. The 68000 is big-endian: the high byte of a number is at the lower address. The
  # library keeps work RAM as 16-bit words in the host's own order, so on a little-endian machine
  # every pair of bytes is swapped in the memory it hands over. The reads here put that right, so
  # an address means what it means to the cartridge's code.
  class Core
    # libretro's names for the memories, and the probe patch's own (core/gpgx-vblank-probe.patch).
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

    # libretro's environment calls that matter here.
    GET_CAN_DUPE = 3
    GET_SYSTEM_DIRECTORY = 9
    SET_PIXEL_FORMAT = 10
    GET_VARIABLE_UPDATE = 17
    GET_SAVE_DIRECTORY = 31
    RGB565 = 2

    JOYPAD = 1
    JOYPAD_MASK = 256

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
    # without one keeps them in a folder of its own that is gone with it.
    def initialize(rom_path, save_dir: nil)
      @dir = Dir.mktmpdir("ruby-genesis-emulator")
      @save_dir = save_dir || @dir
      @buttons = Array.new(2) { [] }
      @frames = 0
      @picture = nil
      @audio = "".b
      @width = WIDTH
      @height = HEIGHT
      @kept = [] # what the core holds a pointer to, kept from the garbage collector
      load_library
      hand_over_callbacks
      @call[:retro_init].call
      load_cartridge(rom_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a Genesis controller has no #{unknown.join(', ')} button" unless unknown.empty?

      @buttons[port] = buttons.map { |button| BUTTONS.fetch(button) }
    end

    # Plays one frame: up to the moment the console starts its next picture.
    def run_frame
      @call[:retro_run].call
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
    # the same byte), the high byte first as the console keeps a number.
    def wram_read8(address) = live(SYSTEM_RAM, 0x10000)[(address & 0xFFFF) ^ 1, 1].getbyte(0)
    def wram_read16(address) = wram_bytes(address, 2).unpack1("n")
    def wram_read32(address) = wram_bytes(address, 4).unpack1("N")
    def wram_bytes(address, count) = Array.new(count) { |i| wram_read8(address + i) }.pack("C*")
    def wram_write8(address, value) = (live(SYSTEM_RAM, 0x10000)[(address & 0xFFFF) ^ 1, 1] = [value & 0xFF].pack("C"))
    def wram_write32(address, value) = [value & 0xFFFFFFFF].pack("N").bytes.each_with_index { |byte, i| wram_write8(address + i, byte) }

    # Unloads the cartridge, shuts the core and lets go of its library.
    def destroy
      return unless @call

      @call[:retro_unload_game].call
      @call[:retro_deinit].call
      @handle.close
      @copy.give_back
      @call = nil
      FileUtils.rm_rf(@dir)
    end

    private

    def memory(id)
      size = @call[:retro_get_memory_size].call(id)
      return "".b if size.zero?

      Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i)[0, size]
    end

    def live(id, size) = Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i, size)

    FUNCTIONS = {
      retro_set_environment: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_video_refresh: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample_batch: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_poll: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_state: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_init: [[], Fiddle::TYPE_VOID],
      retro_deinit: [[], Fiddle::TYPE_VOID],
      retro_load_game: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_BOOL],
      retro_unload_game: [[], Fiddle::TYPE_VOID],
      retro_run: [[], Fiddle::TYPE_VOID],
      retro_set_controller_port_device: [[Fiddle::TYPE_UINT, Fiddle::TYPE_UINT], Fiddle::TYPE_VOID],
      retro_get_memory_data: [[Fiddle::TYPE_UINT], Fiddle::TYPE_VOIDP],
      retro_get_memory_size: [[Fiddle::TYPE_UINT], Fiddle::TYPE_SIZE_T]
    }.freeze

    def load_library
      @copy = KeptCopy.take
      @handle = Fiddle::Handle.new(@copy.path, Fiddle::Handle::RTLD_NOW)
      @call = FUNCTIONS.to_h do |name, (args, result)|
        [name, Fiddle::Function.new(@handle[name.to_s], args, result)]
      end
      refuse_unpatched_core!
    end

    def refuse_unpatched_core!
      return if @call[:retro_get_memory_size].call(VIDEO_RAM) == 0x10000

      raise LoadError, "#{CoreLibrary.path} is a Genesis Plus GX core built without this gem's probe patch, so it " \
                       "cannot hand over the console's memories. Build it with `rake compile_core` in " \
                       "ruby-genesis-emulator/."
    end

    def hand_over_callbacks
      @callbacks = {
        retro_set_environment: closure(Fiddle::TYPE_BOOL, [Fiddle::TYPE_UINT, Fiddle::TYPE_VOIDP]) { |cmd, data| environment(cmd, data) },
        retro_set_video_refresh: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                             Fiddle::TYPE_SIZE_T]) { |*args| take_picture(*args) },
        retro_set_audio_sample: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_INT16_T, Fiddle::TYPE_INT16_T]) { nil },
        retro_set_audio_sample_batch: closure(Fiddle::TYPE_SIZE_T, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]) { |data, frames| take_sound(data, frames) },
        retro_set_input_poll: closure(Fiddle::TYPE_VOID, []) { nil },
        retro_set_input_state: closure(Fiddle::TYPE_INT16_T, [Fiddle::TYPE_UINT, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                              Fiddle::TYPE_UINT]) do |port, device, _index, id|
          button_state(port, device, id)
        end
      }
      @callbacks.each { |setter, callback| @call.fetch(setter).call(callback) }
    end

    def closure(result, args, &block) = Fiddle::Closure::BlockCaller.new(result, args, &block)

    # What the core asks of the controller: one button, or all of them as bits when it asks for the mask.
    def button_state(port, device, id)
      return 0 unless device == JOYPAD

      down = @buttons.fetch(port, [])
      return down.sum { |button| 1 << button } if id == JOYPAD_MASK

      down.include?(id) ? 1 : 0
    end

    # What the core asks of its frontend. Anything not answered here is answered "no", which a
    # core takes as the frontend not having it, and uses its own settings.
    def environment(cmd, data)
      case cmd & 0xFFFF
      when GET_CAN_DUPE then write_bool(data, true)
      when SET_PIXEL_FORMAT then Fiddle::Pointer.new(data.to_i)[0, 4].unpack1("l<") == RGB565
      when GET_SYSTEM_DIRECTORY then write_pointer(data, kept_string(@dir))
      when GET_SAVE_DIRECTORY then write_pointer(data, kept_string(@save_dir))
      when GET_VARIABLE_UPDATE then write_bool(data, false)
      else false
      end
    rescue StandardError
      false
    end

    def write_bool(data, value)
      Fiddle::Pointer.new(data.to_i, 1)[0, 1] = value ? "\1" : "\0"
      true
    end

    def write_pointer(data, pointer)
      Fiddle::Pointer.new(data.to_i, 8)[0, 8] = [pointer.to_i].pack("J")
      true
    end

    # A C string the core may hold on to for as long as this core lives.
    def kept_string(text) = kept_bytes("#{text}\0".b)

    # +bytes+ copied into memory of their own that does not move, kept as long as the core lives.
    def kept_bytes(bytes)
      pointer = Fiddle::Pointer.malloc([bytes.bytesize, 1].max, Fiddle::RUBY_FREE)
      pointer[0, bytes.bytesize] = bytes
      @kept << pointer
      pointer
    end

    # A picture handed over at the end of a frame. A null one is the last frame again.
    def take_picture(data, width, height, pitch)
      return if data.null?

      @width = width
      @height = height
      rows = Fiddle::Pointer.new(data.to_i)[0, pitch * height]
      @picture = pitch == width * 2 ? rows : (0...height).map { |y| rows.byteslice(y * pitch, width * 2) }.join
    end

    # A batch of sound, +frames+ pairs of 16-bit samples, kept until #take_audio asks for it. It says
    # how many pairs it took, which is all of them.
    def take_sound(data, frames)
      @audio << Fiddle::Pointer.new(data.to_i)[0, frames * 4]
      frames
    end

    # libretro's retro_game_info: the path, the bytes and their count, and nothing for meta.
    def load_cartridge(rom_path)
      bytes = File.binread(rom_path)
      path = kept_string(File.expand_path(rom_path))
      data = kept_bytes(bytes)
      info = kept_bytes([path.to_i, data.to_i, bytes.bytesize, 0].pack("J4"))
      raise ArgumentError, "Genesis Plus GX would not load #{rom_path}" unless @call[:retro_load_game].call(info)

      @call[:retro_set_controller_port_device].call(0, JOYPAD)
    end
  end
end
