#include "libretro_frontend.h"

/*
 * ruby-ps1-emulator's compiled half: RubyPS1Emulator::Frontend, the libretro frontend Beetle PSX is
 * played through (libretro_frontend.c says why it is C), and BUILT_FROM, the fingerprint of the
 * source it was built from (lib/ruby_ps1_emulator/built_from.rb).
 *
 * Ractor-safe: a Frontend is made and used inside one Ractor, keeps nothing in a process global but
 * the thread-local pointer its callbacks read, and its callbacks run no Ruby.
 */
void Init_ruby_ps1_emulator_ext(void)
{
    rb_ext_ractor_safe(true);
    VALUE outer = rb_define_module("RubyPS1Emulator");
    libretro_frontend_define(outer);
    rb_define_const(outer, "BUILT_FROM", rb_obj_freeze(rb_str_new_cstr(RUBY_PS1_EMULATOR_BUILT_FROM)));
}
