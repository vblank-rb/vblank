# frozen_string_literal: true

require "test_helper"

# HOW THE RUBY PRINTER WRITES A BIG TABLE (Ruby::Printer#print_const_array): its numbers packed and
# written as base64, read back as the game starts. A game's recordings can be tens of millions of
# numbers, so they are checked all at once rather than one by one; these hold that check to what
# writing them one by one refused, and the table to what it read back.
class TestRubyPrinterTables < Minitest::Test
  Statements = VBlank::IR::Backends::Computer::Statements
  Printer = VBlank::IR::Backends::Ruby::Printer

  # The table +values+ of C's +type+, written by the printer as the game's setup writes it.
  private def written(values, type: "int16_t", writable: true)
    table = Statements::ConstArray.new(name: Statements::Name.new("t_big"), type: type, values: values, writable: writable)
    Printer.new.print_file([table])
  end

  # What the setup line for t_big gives when Ruby runs it.
  private def read_back(text)
    line = text.lines.find { |each| each.include?("@t_big = ") }
    eval(line.split("@t_big = ", 2).last) # rubocop:disable Security/Eval
  end

  def test_a_big_table_reads_back_as_its_numbers
    values = Array.new(Printer::MOST_WRITTEN_AS_NUMBERS * 4) { |at| ((at * 37) % 600) - 300 }
    values[100] = -32_768
    values[200] = 32_767

    assert_equal values, read_back(written(values))
  end

  def test_a_big_table_of_words_reads_back_whole_numbers_at_each_end_of_32_bits
    values = [0] * Printer::MOST_WRITTEN_AS_NUMBERS + [-(2**31), (2**31) - 1]

    assert_equal values, read_back(written(values, type: "int32_t"))
  end

  def test_a_big_table_with_a_number_past_32_bits_is_refused
    values = [0] * Printer::MOST_WRITTEN_AS_NUMBERS + [2**31]

    refused = assert_raises(VBlank::BuildError) { written(values, type: "int32_t") }
    assert_match(/is not a 32-bit whole number/, refused.message)
  end

  def test_a_big_table_with_something_not_a_whole_number_is_refused_naming_it
    values = [0] * Printer::MOST_WRITTEN_AS_NUMBERS + [1.5, 7]

    refused = assert_raises(VBlank::BuildError) { written(values) }
    assert_match(/1\.5 is not a 32-bit whole number/, refused.message)
  end

  def test_a_table_kept_as_bytes_with_a_number_past_32_bits_is_refused
    values = [0] * 10 + [-(2**31) - 1]

    assert_raises(VBlank::BuildError) do
      table = Statements::ConstArray.new(name: Statements::Name.new("rg_game_recording_samples"), type: "int32_t", values: values)
      Printer.new.print_file([table])
    end
  end
end
