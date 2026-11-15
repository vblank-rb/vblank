# frozen_string_literal: true

module RubyGenesisEmulator
  # WHERE THE EMULATOR ITSELF IS: Genesis Plus GX, built as a libretro core with the probe patch in
  # core/gpgx-vblank-probe.patch, which lets this gem read the console's video RAM, colour memory,
  # vertical scroll memory, video chip registers and processor registers. A core built without
  # the patch hands none of those over, so it is refused rather than used.
  #
  # VBLANK_GENESIS_CORE names the library when it is set. Otherwise this gem's own build is used,
  # which `rake compile_core` in this gem's folder makes (see the Rakefile for the steps). The core is
  # played through the gem's C extension, which `rake compile` builds.
  #
  # The paths are frozen, so a Ractor worker may read them.
  module CoreLibrary
    SETTING = "VBLANK_GENESIS_CORE"
    BUILT = File.expand_path("../../core/build/genesis_plus_gx_libretro.so", __dir__).freeze

    module_function

    # The path of the core, or a LoadError saying how to make one.
    def path(env = ENV)
      named = env[SETTING]
      return named if named && File.file?(named)
      return BUILT if File.file?(BUILT)

      raise LoadError, missing_message(named)
    end

    def missing_message(named)
      where = named ? "#{SETTING} names #{named}, and there is no file there." : "There is no Genesis Plus GX core built."
      <<~MESSAGE
        A Genesis cartridge is played in Genesis Plus GX, built as a libretro core with this gem's probe
        patch. #{where} To build it, run this in ruby-genesis-emulator/:

            rake compile_core

        It needs git, make and a C compiler. Or set #{SETTING} to a core that is built already.
      MESSAGE
    end

    # Why the C extension that plays the core did not load (+detail+, Ruby's own reason), and how
    # to build it.
    def extension_missing_message(detail)
      <<~MESSAGE
        A Genesis cartridge is played through ruby-genesis-emulator's C extension, and it is not
        built for this Ruby (#{detail}). To build it, run this in ruby-genesis-emulator/:

            rake compile

        It needs a C compiler.
      MESSAGE
    end
  end
end
