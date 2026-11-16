# frozen_string_literal: true

module RubyDOSEmulator
  # WHERE THE EMULATOR ITSELF IS: DOSBox, built as a libretro core with the probe patch in
  # core/dosbox-vblank-probe.patch, which lets this gem read the PC's memory, the video card's memory
  # and palette, and its mode. A core built without the patch has none of the probe's functions, and
  # Core refuses it saying so (Core#start).
  #
  # VBLANK_DOS_CORE names the library when it is set. Otherwise it is the build beside this code, which
  # `gem install vblank` makes (ext/vblank/Rakefile), and `rake compile_core` in a checkout. An install
  # that could not make one says why in NOT_BUILT.
  module CoreLibrary
    SETTING = "VBLANK_DOS_CORE"
    BUILT = File.expand_path("../../core/build/dosbox_svn_libretro.so", __dir__).freeze
    NOT_BUILT = File.expand_path("../../NOT_BUILT", __dir__).freeze

    module_function

    # The path of the core, or a LoadError saying how to make one.
    def path(env = ENV)
      named = env[SETTING]
      return named if named && File.file?(named)
      return BUILT if File.file?(BUILT)

      raise LoadError, missing_message(named, not_built: (File.read(NOT_BUILT) if File.file?(NOT_BUILT)))
    end

    def not_installed_message(reason)
      <<~MESSAGE
        A DOS program is played in DOSBox. This copy of VBlank was installed without it:

            #{reason.strip}

        To fix this, install what is missing, then run:

            gem pristine vblank
      MESSAGE
    end

    # What Core says of a library that is a core and lacks the probe patch's functions.
    def unpatched_message(library)
      <<~MESSAGE
        The DOSBox core at #{library} was built without this gem's probe patch, so it cannot hand
        over the PC's memory or its picture. To build one with the patch, run this in ruby-dos-emulator/:

            rake clean compile_core
      MESSAGE
    end

    # Why the C extension that plays the core did not load (+detail+, Ruby's own reason), and how to build it:
    # an install that could not build it says why in NOT_BUILT, and is fixed by `gem pristine vblank`.
    def extension_missing_message(detail, not_built: (File.read(NOT_BUILT) if File.file?(NOT_BUILT)))
      return not_installed_message(not_built) if not_built

      <<~MESSAGE
        A DOS program is played through ruby-dos-emulator's C extension, and it is not
        built for this Ruby (#{detail}). To build it, run this in ruby-dos-emulator/:

            rake compile

        It needs a C compiler.
      MESSAGE
    end

    def missing_message(named, not_built: nil)
      return not_installed_message(not_built) if not_built && !named

      where = named ? "#{SETTING} names #{named}, and there is no file there." : "There is no DOSBox core built."
      <<~MESSAGE
        A DOS program is played in DOSBox, built as a libretro core with this gem's probe
        patch. #{where} To build it, run this in ruby-dos-emulator/:

            rake compile_core

        It needs make, patch, tar and a C++ compiler. Or set #{SETTING} to a core that is built already.
      MESSAGE
    end
  end
end
