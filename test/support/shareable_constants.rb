# frozen_string_literal: true

# A file of plain Ruby required for the tests, with every constant it defined made shareable
# afterwards, so a test playing in a Ractor can read them.
#
# The examples name their constants the way any Ruby does (`MAP = [...]`, `GAME = VBlank.game ...`),
# because people read them to learn the library and never meet a Ractor outside the tests. The
# tests play each game in a Ractor of its own, and a Ractor may read a constant only once nothing
# in it can change. So a test requires an example through here:
#
#   ShareableConstants.require_file(VBlank.root.join("examples/pong").to_s)
#
# Ractor.make_shareable freezes each value in place, all the way down, so no constant is set
# again and nothing that already holds one sees a different object. A constant that holds a
# module or class is walked into, for the constants it holds in turn.
#
# A file's constants are found by where Ruby says each was defined: the file itself, or a file
# in the folder of its name beside it (examples/dive.rb and examples/dive/fish.rb). Comparing the
# constants before and after the require would find nothing when the file was already loaded by
# something else, a test that reads every example, say, and would leave its constants unfrozen.
# Asking where each was defined also leaves alone a constant of a library the file happened to
# load first.
module ShareableConstants
  # Raised for a constant the file defined that cannot be made shareable, naming both.
  class Unshareable < StandardError; end

  # Requires +path+, then makes every constant it defined shareable. Returns what require did.
  def self.require_file(path)
    path = File.expand_path(path)
    path = "#{path}.rb" unless path.end_with?(".rb")
    required = require path
    share_constants_of(Object, path, {}.compare_by_identity)
    required
  end

  # Every constant of +holder+ that +path+ or its folder defined, made shareable. +walked+ holds
  # the modules already gone through, so a module that names itself is walked once.
  def self.share_constants_of(holder, path, walked)
    walked[holder] = true
    holder.constants(false).each do |name|
      next if holder.autoload?(name)
      next unless defined_by?(holder.const_source_location(name), path)

      value = holder.const_get(name, false)
      if value.is_a?(Module)
        share_constants_of(value, path, walked) unless walked.key?(value)
      else
        share_value(value, holder, name, path)
      end
    end
  end

  # Whether +location+, where Ruby says a constant was defined, is +path+ or a file in the folder
  # of its name.
  def self.defined_by?(location, path)
    file = location&.first
    return false unless file

    file == path || file.start_with?("#{path.delete_suffix(".rb")}/")
  end

  def self.share_value(value, holder, name, path)
    Ractor.make_shareable(value)
  rescue Ractor::Error, FrozenError => e
    constant = holder.equal?(Object) ? name : "#{holder}::#{name}"
    raise Unshareable, "#{constant}, defined by #{path}, cannot be made shareable for the tests: #{e.message}"
  end

  private_class_method :share_constants_of, :defined_by?, :share_value
end
