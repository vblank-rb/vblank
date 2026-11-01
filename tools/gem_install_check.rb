# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# DOES THE GEM WORK ONCE IT IS INSTALLED? A release check, not a unit test: the suite plays a
# checkout, where every file is on hand, so it cannot see a file left out of the gem or an emulator
# an install did not build. This builds the gem and installs it on two clean Linux machines, made
# by tools/gem_install_check/Dockerfile:
#
#   rake release:install_check
#
# A machine with nothing but Ruby must install the gem, build cartridges and say what each emulator
# needs, then get both emulators from the fix it was told. A machine with the tools must get them
# from a plain install. On each, a game's own tests play its cartridges in those emulators.
#
# It needs Docker with buildx and a network. The first run takes minutes; after that Docker reuses
# what has not changed (the Dockerfile says what). The machines run the Ruby running this. A Mac has
# no clean room like this, so it is checked by hand for now.
module GemInstallCheck
  ROOT = File.expand_path("..", __dir__)
  MACHINES = File.join(__dir__, "gem_install_check")

  # A gem holds the time it was built, which would make every build different bytes, and Docker
  # would take each for a new gem and install it again. A fixed time keeps a gem that has not
  # changed the same to the byte.
  FIXED_BUILD_TIME = { "SOURCE_DATE_EPOCH" => "1" }.freeze

  module_function

  def build_gem(folder)
    system(FIXED_BUILD_TIME, "gem", "build", "vblank.gemspec", "--output", File.join(folder, "vblank.gem"),
           chdir: ROOT, exception: true)
  end

  def docker_command(folder)
    ["docker", "buildx", "build", "--target", "passed", "--output", "type=cacheonly", "--progress", "plain",
     "--build-arg", "RUBY_VERSION=#{RUBY_VERSION}", folder]
  end

  def run
    Dir.mktmpdir("gem-install-check") do |folder|
      build_gem(folder)
      FileUtils.cp_r(Dir[File.join(MACHINES, "*")], folder)
      system(*docker_command(folder)) || abort("The installed gem failed. The step that stopped is above.")
      puts "The installed gem passed on both machines."
    end
  end
end

GemInstallCheck.run if $PROGRAM_NAME == __FILE__
