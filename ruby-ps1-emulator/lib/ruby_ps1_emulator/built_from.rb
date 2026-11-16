# frozen_string_literal: true

require "digest"

module RubyPS1Emulator
  # WHICH SOURCE A CHECKOUT'S BUILT EXTENSION CAME FROM. The Ruby half of a checkout changes the
  # moment new code is pulled, and the compiled half only when somebody builds, so extconf.rb
  # compiles a fingerprint of the C source in as BUILT_FROM and the entry point compares it with the
  # source beside it as it loads (ruby-gba-emulator's built_from.rb tells the whole of it). A build
  # RubyGems makes for the gem is not checked.
  SOURCE_DIR = File.expand_path("../../ext/ruby_ps1_emulator_ext", __dir__).freeze

  # Raised when the build loaded is not from the source beside it. Not a LoadError: the extension
  # did load, and a caller that treats "no emulator" as "carry on without one" has to hear this one.
  class OutOfDate < StandardError; end

  class << self
    # A fingerprint of the C source in +dir+: its .c and .h files, by name and content.
    def source_fingerprint(dir = SOURCE_DIR)
      digest = Digest::SHA256.new
      Dir.glob("*.{c,h}", base: dir).sort.each do |name|
        digest << name << "\0" << File.binread(File.join(dir, name)) << "\0"
      end
      digest.hexdigest
    end

    # Raise OutOfDate unless +built_from+ is the fingerprint of the source in +source_dir+.
    def refuse_out_of_date_build!(built_from: BUILT_FROM, source_dir: SOURCE_DIR)
      return if built_from == source_fingerprint(source_dir)

      raise OutOfDate, <<~MSG
        The ruby-ps1-emulator extension is out of date. It was built from different C source than the source in #{source_dir}, and the Ruby half of the gem cannot use it.
        To rebuild the extension, run `rake compile` in #{File.expand_path('../..', source_dir)}.
      MSG
    end
  end
end
