# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"

# BUILDING THE EMULATORS WHEN THE GEM IS INSTALLED.
#
# VBlank is one gem. ruby-gba-emulator/ and ruby-snes-emulator/ are folders inside it, and each
# holds source that has to be compiled on the machine it runs on: a C extension over libmgba, and
# bsnes itself. They are built in place, into the same folders a checkout builds them in, so
# everything that finds an emulator finds it the same way in a checkout and in an installed gem.
#
# AN EMULATOR THAT CANNOT BE BUILT DOES NOT STOP THE INSTALL. Building a cartridge is plain Ruby,
# and somebody with no compiler can still do all of that. So each failure is written to a file
# called NOT_BUILT in that emulator's folder, and the first thing to want that emulator repeats the
# reason and how to fix it, which reaches the person at the moment it matters: RubyGems shows
# nothing an extension prints unless the build fails.
module EmulatorBuilds
  ROOT = File.expand_path("../..", __dir__)

  class Failed < StandardError; end

  module_function

  def build_all(root: ROOT)
    attempt(File.join(root, "ruby-gba-emulator")) { build_advance_emulator(File.join(root, "ruby-gba-emulator")) }
    attempt(File.join(root, "ruby-snes-emulator")) { build_snes_core(File.join(root, "ruby-snes-emulator")) }
  end

  # Runs the block and leaves NOT_BUILT in +folder+ saying why if it raised, or no such file if not.
  def attempt(folder, out: $stdout)
    reason_file = File.join(folder, "NOT_BUILT")
    FileUtils.rm_f(reason_file)
    yield
    out.puts "built #{File.basename(folder)}"
  rescue StandardError, ScriptError => e
    File.write(reason_file, "#{e.message}\n")
    out.puts "skipped #{File.basename(folder)}: #{e.message}"
  end

  # What `rake compile` does in ruby-gba-emulator/, whose Rakefile says why it installs where it
  # does. Not by calling that Rakefile: it is a checkout's, and loads its test tasks.
  def build_advance_emulator(folder)
    compiler = RbConfig::CONFIG["CC"].split.first
    raise Failed, "a C compiler (#{compiler}) is not installed" unless on_path?(compiler)

    load File.join(folder, "lib", "ruby_gba_emulator", "built_for.rb")
    installed = File.join(folder, "lib", RubyGBAEmulator::BUILT_FOR, "ruby_gba_emulator")
    source = File.join(folder, "ext", "ruby_gba_emulator_ext")
    FileUtils.mkdir_p(installed)
    run(source, RbConfig.ruby, "extconf.rb")
    run(source, "make")
    run(source, "make", "install-so", "RUBYARCHDIR=#{installed}")
    run(source, "make", "clean")
  rescue StandardError
    # A folder for this Ruby is what tells the emulator's loader that a build is there.
    FileUtils.rm_rf(File.dirname(installed)) if installed
    raise
  end

  def build_snes_core(folder)
    require File.join(folder, "lib", "ruby_snes_emulator", "core_build")
    RubySNESEmulator::CoreBuild.make(File.join(folder, "core", "build", "bsnes_libretro.so"))
  end

  def on_path?(tool)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
  end

  def run(folder, *command)
    output, status = Open3.capture2e(*command, chdir: folder)
    raise Failed, output.lines.last(10).join.strip unless status.success?
  end
end
