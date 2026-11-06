# frozen_string_literal: true

require "test_helper"

# The C tree's forms that write data rather than the game (a struct, a constant that is not a
# number, an array of structs), and the file a build that is no shell is given for a shell's facts.
class TestNativePrinter < Minitest::Test
  C = VBlank::IR::Backends::Native::C
  Printer = VBlank::IR::Backends::Native::Printer
  ShellData = VBlank::IR::Backends::Native::ShellData

  private def printed(*items) = Printer.new.print_file(items)

  def test_a_struct_is_written_by_the_names_of_its_fields
    struct = C::Struct.new(fields: { title: C::Text.new(value: "A \"B\""), size: C::Int.new(value: 7), inner: C::Struct.new(fields: { n: C::Int.new(value: -1) }),
                                     list: C::Name.new(text: "items") })

    assert_equal "static const thing_t thing = {.title = \"A \\\"B\\\"\", .size = 7, .inner = {.n = -1}, .list = items};\n",
                 printed(C::ConstGlobal.new(name: C::Name.new(text: "thing"), type: "thing_t", value: struct))
  end

  def test_a_constant_pointer_to_another_global_is_exported_when_asked
    text = printed(C::ConstGlobal.new(name: C::Name.new(text: "facts"), type: "thing_t *const", value: C::AddressOf.new(name: C::Name.new(text: "thing")),
                                      exported: true))

    assert_equal "const thing_t *const facts = &thing;\n", text
  end

  def test_an_array_holds_structs
    entries = [1, 2].map { |number| C::Struct.new(fields: { n: C::Int.new(value: number) }) }

    assert_equal "static const thing_t things[2] = {\n  {.n = 1}, {.n = 2},\n};\n",
                 printed(C::ConstArray.new(name: C::Name.new(text: "things"), type: "thing_t", values: entries))
  end

  # C has no empty initializer, so an array with nothing in it is one zero long.
  def test_an_empty_array_is_written_one_zero_long
    assert_equal "static const uint8_t none[1] = {\n  0,\n};\n", printed(C::ConstArray.new(name: C::Name.new(text: "none"), type: "uint8_t", values: []))
  end

  def test_a_build_that_is_no_shell_says_it_has_none
    text = printed(*ShellData.items)

    assert_includes text, "#include \"rg_shell.h\""
    assert_includes text, "const rg_shell_description *const rg_shell_facts = NULL;"
  end
end
