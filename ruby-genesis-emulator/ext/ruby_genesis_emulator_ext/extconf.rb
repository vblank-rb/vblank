# frozen_string_literal: true

require "mkmf"

# The libretro frontend Genesis Plus GX is played through. It links nothing but the system's dlopen:
# the core is opened when a console is made, from the copy KeptCopy hands out, and never linked in
# here. Linux keeps dlopen in libdl before glibc 2.34; elsewhere it is in the C library.
have_library("dl", "dlopen") unless RUBY_PLATFORM.include?("mingw")

$srcs = %w[ruby_genesis_emulator_ext.c libretro_frontend.c]

# THE SOURCE THIS BUILD COMES FROM, compiled in as RubyGenesisEmulator::BUILT_FROM so that loading a
# checkout's build can tell whether somebody pulled new source since (see built_from.rb). The quotes
# are for the shell make hands the line to: it takes off the single ones and the compiler is left
# with a C string.
require_relative "../../lib/ruby_genesis_emulator/built_from"
$defs << %(-DRUBY_GENESIS_EMULATOR_BUILT_FROM='"#{RubyGenesisEmulator.source_fingerprint(__dir__)}"')

# Installed as lib/ruby_genesis_emulator/ruby_genesis_emulator_ext.<dlext>, where
# `require "ruby_genesis_emulator/ruby_genesis_emulator_ext"` finds it (ruby-gba-emulator's
# extconf.rb says why the directory is in the name).
create_makefile("ruby_genesis_emulator/ruby_genesis_emulator_ext")
