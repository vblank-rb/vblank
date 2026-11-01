# frozen_string_literal: true

module RubySNESEmulator
  # WHERE THE EMULATOR ITSELF IS: bsnes, built as a libretro core with the probe patch in
  # core/bsnes-vblank-probe.patch, which lets this code read the console's work RAM, video RAM,
  # colour memory, sprite table and processor registers. A core built without the patch hands
  # none of those over, so it is refused rather than used.
  #
  # VBLANK_SNES_CORE names the library when it is set. Otherwise it is the build beside this code,
  # which `gem install vblank` makes (ext/vblank/Rakefile), and `rake compile_core` in a checkout.
  # An install that could not make one says why in NOT_BUILT.
  module CoreLibrary
    SETTING = "VBLANK_SNES_CORE"
    BUILT = File.expand_path("../../core/build/bsnes_libretro.so", __dir__)
    NOT_BUILT = File.expand_path("../../NOT_BUILT", __dir__)

    module_function

    # The path of the core, or a LoadError saying how to make one.
    def path(env = ENV)
      named = env[SETTING]
      return named if named && File.file?(named)
      return BUILT if File.file?(BUILT)

      raise LoadError, missing_message(named, not_built: (File.read(NOT_BUILT) if File.file?(NOT_BUILT)))
    end

    def missing_message(named, not_built: nil)
      return not_installed_message(not_built) if not_built && !named

      where = named ? "#{SETTING} names #{named}, and there is no file there." : "There is no bsnes core built."
      <<~MESSAGE
        A Super Nintendo cartridge is played in bsnes, built as a libretro core with a probe
        patch. #{where} To build it, run this in ruby-snes-emulator/:

            rake compile_core

        It needs make, patch, tar and a C++ compiler. Or set #{SETTING} to a core that is built already.
      MESSAGE
    end

    def not_installed_message(reason)
      <<~MESSAGE
        A Super Nintendo cartridge is played in bsnes. This copy of VBlank was installed without it:

            #{reason.strip}

        To fix this, install what is missing, then run:

            gem pristine vblank
      MESSAGE
    end
  end
end
