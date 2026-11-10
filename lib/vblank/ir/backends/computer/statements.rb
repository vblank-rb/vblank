# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE C THE BACKEND WRITES, as data rather than text.
        #
        # The lowering builds these and the Printer alone turns them into text, so the things
        # that are easy to get wrong by hand — how a number is spelt, which names are legal,
        # indentation, what a comment may contain — are settled in one place, and no lowering
        # method ever glues C together out of strings.
        #
        # It is small on purpose. The game's numbers only ever go through rg_int32.h (see the
        # comment atop Backends::Native), so an expression here is a number, a name, the address of a
        # name, a piece of text, or a call — there are no operators, and so no precedence to
        # get wrong.
        module Statements
          # --- expressions ---

          # A whole number, written so C reads it as the int32_t it is.
          Int = Data.define(:value)

          # An identifier. Only Names hands these out, so every one is legal and none collide.
          Name = Data.define(:text)

          # &name: where a global lives, for a runtime function that fills it in.
          AddressOf = Data.define(:name)

          # A piece of text, as a C string. The printer escapes it.
          Text = Data.define(:value)

          Call = Data.define(:function, :args) do
            def initialize(function:, args: [])
              super
            end
          end

          # { .field = value, ... }: a struct's value by the names of its fields, so the order they are
          # declared in does not matter. +fields+ maps a field's name (a Symbol) to any expression here,
          # a Struct or a Name included.
          Struct = Data.define(:fields)

          # name[index], for reading a table or a list.
          Index = Data.define(:array, :index)

          # --- statements ---

          # A call whose answer nobody keeps.
          Eval = Data.define(:call)

          # target = value; the target is a Name or an Index.
          Assign = Data.define(:target, :value)

          # A local variable of the routine, int32_t unless set.
          Local = Data.define(:name, :value, :type) do
            def initialize(name:, value:, type: "int32_t")
              super
            end
          end

          # Taken when +condition+ is not nought, the way the game's conditions are numbers.
          If = Data.define(:condition, :body, :otherwise) do
            def initialize(condition:, body:, otherwise: [])
              super
            end
          end

          While = Data.define(:condition, :body)
          Break = Data.define
          Return = Data.define

          # { ... }, so a loop's own locals stay its own.
          Block = Data.define(:body)

          # --- a routine that can stop for a frame and carry on (Resumable) ---

          # The body of a resumable routine: +steps+, each a list of statements, run from the one
          # numbered by the routine's +counter+ (a Name, a global of the routine's own). Every step
          # ends in a Goto, a Pause or a Finish, so no step runs on into the next.
          Steps = Data.define(:counter, :steps)

          # Carry on at step +step+ of the routine whose counter is +counter+.
          Goto = Data.define(:counter, :step)

          # Stop for the frame: the routine carries on at step +step+ when it is called again, and
          # hands back 1, waiting.
          Pause = Data.define(:counter, :step)

          # The routine is done: its counter back to step 0 for the next call, and it hands back 0.
          Finish = Data.define(:counter)

          # A call of a resumable routine (+call+): when it hands back 1, waiting, this routine
          # stops too and hands back 1, and is called again at the step this stands first in.
          Resume = Data.define(:call)

          # A call of a resumable routine from one that answers the runtime and cannot wait: run from
          # its start to its end now, and a wait there is a fault (rg_wait_vblank_while_answering).
          # The +counters+ (Names) and +locals+ (the Statements::Locals made globals) of every resumable routine the call can reach are kept before
          # it, the counters set to 0 so each runs from its start, and all put back after it, so a game
          # stopped inside one of them carries on from where it stopped.
          RunToEnd = Data.define(:call, :counters, :locals)

          # A comment on a line of its own: where in the game a piece of C came from.
          Comment = Data.define(:text)

          # --- the top level ---

          Include = Data.define(:header)

          # A global the game keeps, starting at +value+.
          Global = Data.define(:name, :value, :type) do
            def initialize(name:, value: 0, type: "int32_t")
              super
            end
          end

          # Numbers fixed when the program is built: a table, a picture, or +values+ that are Structs
          # (+type+ then the struct's). +exported+ is for the art the runtime reads by name (see
          # runtime/rg_screen.h).
          ConstArray = Data.define(:name, :type, :values, :exported) do
            def initialize(name:, type:, values:, exported: false)
              super
            end
          end

          # A constant of a type that is not a number: a struct, a pointer. +value+ is any expression,
          # &another global included. Private to the generated file unless +exported+.
          ConstGlobal = Data.define(:name, :type, :value, :exported) do
            def initialize(name:, type:, value:, exported: false)
              super
            end
          end

          # An array of +count+ numbers of +type+ that the program is written without: they are read
          # from the file it is handed as it starts (IR::StartFile), before the game's first statement,
          # and never written after. So it is written as its size alone, where it can be written.
          StartFileArray = Data.define(:name, :type, :count)

          # A routine taking nothing and giving nothing back. +exported+ is for the few the
          # runtime calls by name; the rest are private to the generated file. A +resumable+ one
          # gives back 1 when it stopped for a frame and 0 when it is done (Resumable).
          Function = Data.define(:name, :body, :exported, :resumable) do
            def initialize(name:, body:, exported: false, resumable: false)
              super
            end
          end

          # Declares a routine before its body, so routines can call each other in any order.
          Prototype = Data.define(:name, :exported, :resumable) do
            def initialize(name:, exported: false, resumable: false)
              super
            end
          end

          # An array of routines, for calling one by its number; resumable ones where any is.
          FunctionTable = Data.define(:name, :functions, :resumable) do
            def initialize(name:, functions:, resumable: false)
              super
            end
          end

          # A game's list (see runtime/rg_list.h): +items+ is the array behind it, +capacity+
          # long, each slot +width+ bytes; +label+ is the game's name for it, for messages.
          ListStorage = Data.define(:name, :items, :capacity, :width, :label)
        end
      end
    end
  end
end
