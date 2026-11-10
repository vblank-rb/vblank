# frozen_string_literal: true

require "test_helper"

# The C tree's forms that write data rather than the game (a struct, a constant that is not a
# number, an array of structs), and the file a build that is no shell is given for a shell's facts.
class TestNativePrinter < Minitest::Test
  Statements = VBlank::IR::Backends::Computer::Statements
  Printer = VBlank::IR::Backends::Native::Printer
  ShellData = VBlank::IR::Backends::Native::ShellData

  private def printed(*items) = Printer.new.print_file(items)

  def test_a_struct_is_written_by_the_names_of_its_fields
    struct = Statements::Struct.new(fields: { title: Statements::Text.new(value: "A \"B\""), size: Statements::Int.new(value: 7), inner: Statements::Struct.new(fields: { n: Statements::Int.new(value: -1) }),
                                     list: Statements::Name.new(text: "items") })

    assert_equal "static const thing_t thing = {.title = \"A \\\"B\\\"\", .size = 7, .inner = {.n = -1}, .list = items};\n",
                 printed(Statements::ConstGlobal.new(name: Statements::Name.new(text: "thing"), type: "thing_t", value: struct))
  end

  def test_a_constant_pointer_to_another_global_is_exported_when_asked
    text = printed(Statements::ConstGlobal.new(name: Statements::Name.new(text: "facts"), type: "thing_t *const", value: Statements::AddressOf.new(name: Statements::Name.new(text: "thing")),
                                      exported: true))

    assert_equal "const thing_t *const facts = &thing;\n", text
  end

  def test_an_array_holds_structs
    entries = [1, 2].map { |number| Statements::Struct.new(fields: { n: Statements::Int.new(value: number) }) }

    assert_equal "static const thing_t things[2] = {\n  {.n = 1}, {.n = 2},\n};\n",
                 printed(Statements::ConstArray.new(name: Statements::Name.new(text: "things"), type: "thing_t", values: entries))
  end

  # A big table of bytes is kept in a file of its own beside game.c, named by its bytes, and the C
  # reads it from there; a smaller one is still its numbers.
  def test_a_big_table_of_bytes_is_embedded_from_a_file_of_its_own
    values = Array.new(Printer::MOST_WRITTEN_AS_NUMBERS + 1) { |i| (i % 256) - 128 }
    printer = Printer.new
    text = printer.print_file([Statements::ConstArray.new(name: Statements::Name.new(text: "sound"), type: "int8_t", values: values)])

    file, bytes = printer.embedded.first
    assert_equal values, bytes.unpack("c*")
    assert_includes text, "static const int8_t sound[#{values.size}] = {\n#embed \"#{file}\"\n};"
    assert_includes printed(Statements::ConstArray.new(name: Statements::Name.new(text: "small"), type: "int8_t", values: [1, -2])), "1, -2,"
  end

  def test_a_number_that_does_not_fit_a_big_table_of_bytes_is_refused
    values = Array.new(Printer::MOST_WRITTEN_AS_NUMBERS + 1, 0) << 300
    error = assert_raises(VBlank::IR::Backends::Computer::LoweringError) do
      printed(Statements::ConstArray.new(name: Statements::Name.new(text: "sound"), type: "int8_t", values: values))
    end

    assert_match(/does not fit int8_t/, error.message)
  end

  # C has no empty initializer, so an array with nothing in it is one zero long.
  def test_an_empty_array_is_written_one_zero_long
    assert_equal "static const uint8_t none[1] = {\n  0,\n};\n", printed(Statements::ConstArray.new(name: Statements::Name.new(text: "none"), type: "uint8_t", values: []))
  end

  def test_a_build_that_is_no_shell_says_it_has_none
    text = printed(*ShellData.items)

    assert_includes text, "#include \"rg_shell.h\""
    assert_includes text, "const rg_shell_description *const rg_shell_facts = NULL;"
  end
end
