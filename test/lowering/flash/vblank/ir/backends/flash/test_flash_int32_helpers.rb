# frozen_string_literal: true

require "test_helper"
require "int32_cases"
require "tmpdir"

# The Flash arithmetic (runtime/rg_int32.hx) gives the answer IR::Int32 gives, for the values where a
# float and a 32-bit whole number are most likely to part ways (Int32Cases).
#
# Every calculation goes through one run of the Flash player: the cases are written into a small movie
# beside the arithmetic, which traces an answer for each.
class TestFlashInt32Helpers < Minitest::Test
  Flash = VBlank::IR::Backends::Flash
  RUNTIME = Ractor.make_shareable(File.join(Flash::RUNTIME_DIR, "rg_int32.hx"))
  CASES = Int32Cases.cases.freeze

  # The helper each calculation names, by the function that does it.
  HELPERS = { "add" => "rg_add", "sub" => "rg_sub", "mul" => "rg_mul", "neg" => "rg_neg", "abs" => "rg_abs",
              "clamp" => "rg_clamp", "div" => "rg_div", "mod" => "rg_mod", "mul_fix" => "rg_mul_fix", "div_fix" => "rg_div_fix",
              "bit_and" => "rg_and", "bit_or" => "rg_or", "bit_xor" => "rg_xor", "bit_not" => "rg_not",
              "shift_left" => "rg_shl", "shift_right" => "rg_shr", "lt" => "rg_lt", "le" => "rg_le", "gt" => "rg_gt",
              "ge" => "rg_ge", "eq" => "rg_eq", "ne" => "rg_ne", "both" => "rg_both", "either" => "rg_either",
              "to_byte" => "rg_to_byte", "to_half" => "rg_to_half" }.freeze

  def test_every_helper_gives_int32s_answer
    wrong = Int32Cases.wrong_answers(CASES, calculate(CASES))

    assert_empty wrong.first(10), "#{wrong.size} of #{CASES.size} calculations disagree"
  end

  # Dividing by zero follows the console's own divide routine, so a game that does it behaves the
  # same in Flash as on the cartridge.
  def test_dividing_by_zero_gives_the_consoles_answer
    calculations, answers = Int32Cases::BY_ZERO.transpose

    assert_equal answers, calculate(calculations)
  end

  private

  def calculate(cases)
    Dir.mktmpdir("vblank-flash-int32") do |dir|
      File.write(File.join(dir, "Main.hx"), movie(cases))
      swf = Flash::Haxe.compile(dir, main: "Main", swf: File.join(dir, "int32.swf"), width: 16, height: 16)
      VBlank::Diagnostics::FlashPlayer.play(swf, frames: 1).map(&:to_i)
    end
  end

  def calls
    HELPERS.map { |name, function| "case \"#{name}\": #{function}(#{arguments(name)});" }.join("\n")
  end

  # Which of a line's three numbers the helper is given.
  def arguments(name)
    case name
    when "neg", "abs", "bit_not", "to_byte", "to_half" then "a"
    when "clamp", "mul_fix", "div_fix" then "a, b, c"
    else "a, b"
    end
  end

  def movie(cases)
    lines = cases.map { |name, a, b, c| "#{name} #{a} #{b} #{c}" }.join("\n")
    <<~HAXE
      class Main {
        #{File.read(RUNTIME)}
        static function main() {
          var lines = "#{lines}".split("\\n");
          for (line in lines) {
            var words = line.split(" ");
            var a = Std.parseInt(words[1]);
            var b = Std.parseInt(words[2]);
            var c = Std.parseInt(words[3]);
            var answer:Int = switch (words[0]) {
              #{calls}
              default: 0;
            };
            flash.Lib.trace(Std.string(answer));
          }
        }
      }
    HAXE
  end
end
