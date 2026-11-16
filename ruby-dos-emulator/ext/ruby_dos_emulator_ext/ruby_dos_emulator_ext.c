/*
 * ruby-dos-emulator's compiled half: RubyDOSEmulator::Machine, which opens one copy of the DOSBox core
 * and calls into it for Ruby, and BUILT_FROM, the fingerprint of the source it was built from
 * (lib/ruby_dos_emulator/built_from.rb).
 *
 * WHY C AND NOT FIDDLE. Ruby lets Fiddle run only on the main Ractor (Fiddle::Handle raises
 * Ractor::UnsafeError anywhere else), and a test suite plays its tests in Ractor workers. A C extension
 * that declares itself Ractor-safe can be used from any of them.
 *
 * WHY NOT THE OTHER EMULATORS' FRONTEND. ruby-snes-emulator, ruby-genesis-emulator and ruby-ps1-emulator
 * carry one libretro frontend in C (libretro_frontend.c) whose callbacks keep the picture, sound and
 * buttons. DOSBox already has that half in C, inside the core, from the probe patch
 * (core/dosbox-vblank-probe.patch, the vblank_* functions): its keys must reach the keyboard at a moment
 * in the machine's own time, which only code inside the core can schedule, and its clock is pinned
 * inside the core's clock chip. So this file hands the core its own callbacks and calls the probe's
 * functions; nothing here is called back, and no Ruby runs while the core runs.
 *
 * ONE MACHINE PER COPY. The core keeps the whole PC, and the probe its picture and sound, in the
 * library's globals, so each Machine opens a copy of the library of its own (CoreCopy), and two Machines
 * in two Ractors, on two threads, share nothing.
 */
#include <dlfcn.h>
#include <ruby.h>
#include <ruby/thread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* libretro's retro_game_info and retro_system_av_info, from its libretro.h. */
struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_system_av_info {
    unsigned base_width, base_height, max_width, max_height;
    float aspect_ratio;
    double fps;
    double sample_rate;
};

typedef void (*any_fn)(void);

/* The core's functions this calls: libretro's, then the probe patch's. */
struct core_functions {
    void (*set_environment)(any_fn);
    void (*set_video_refresh)(any_fn);
    void (*set_audio_sample)(any_fn);
    void (*set_audio_sample_batch)(any_fn);
    void (*set_input_poll)(any_fn);
    void (*set_input_state)(any_fn);
    void (*init)(void);
    void (*deinit)(void);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void (*run)(void);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);

    void (*set_directory)(const char *);
    void (*clock_at)(int, int, int, int, int, int, int, int);
    void (*key_event)(int, unsigned);
    size_t (*copy_picture)(uint32_t *, size_t, unsigned *, unsigned *);
    size_t (*take_sound)(int16_t *, size_t);
};

struct machine {
    void *library;  /* NULL once closed */
    struct core_functions call;
    bool started;   /* retro_init called */
    bool game_loaded;
    bool running;   /* inside retro_run, with Ruby's lock let go */
    char *directory; /* the core keeps the pointer it is handed, so this outlives every call */
    char *game_path;
};

/* Takes the program out, shuts the machine and closes its library. Shutting resumes the machine's own
 * stack one last time so it unwinds and frees the PC's memory (the probe patch's vblank_leave_frame). */
static void shut(struct machine *m)
{
    if (!m->library) return;
    if (m->game_loaded) m->call.unload_game();
    if (m->started) m->call.deinit();
    dlclose(m->library);
    m->library = NULL;
    m->game_loaded = false;
    m->started = false;
}

static void machine_free(void *pointer)
{
    struct machine *m = pointer;
    shut(m);
    free(m->directory);
    free(m->game_path);
    free(m);
}

static const rb_data_type_t machine_type = {
    .wrap_struct_name = "DOSBox machine",
    /* Not freed immediately: shutting the machine unwinds its stack and closes a library, which does
     * not belong in the middle of a sweep. */
    .function = { .dmark = NULL, .dfree = machine_free, .dsize = NULL },
};

static VALUE machine_allocate(VALUE klass)
{
    struct machine *m = calloc(1, sizeof(*m));
    if (!m) rb_raise(rb_eNoMemError, "no memory for a DOSBox machine");
    return TypedData_Wrap_Struct(klass, &machine_type, m);
}

static struct machine *machine_of(VALUE self)
{
    struct machine *m;
    TypedData_Get_Struct(self, struct machine, &machine_type, m);
    return m;
}

/* The machine of +self+, refused when it is closed or inside a frame on another thread. */
static struct machine *open_machine(VALUE self)
{
    struct machine *m = machine_of(self);
    if (!m->library) rb_raise(rb_eRuntimeError, "this DOSBox machine is shut");
    if (m->running) rb_raise(rb_eRuntimeError, "this DOSBox machine is playing a frame on another thread");
    return m;
}

static char *copied_string(VALUE text)
{
    char *copy = strdup(StringValueCStr(text));
    if (!copy) rb_raise(rb_eNoMemError, "no memory for a DOSBox machine");
    return copy;
}

/* The library's function +name+. A library without one is no core built with the probe patch, which
 * Ruby says in words of its own (CoreLibrary.unpatched_message), so it is raised as Machine::Unpatched. */
static void *core_function(struct machine *m, const char *name)
{
    void *function = dlsym(m->library, name);
    if (!function) {
        dlclose(m->library);
        m->library = NULL;
        rb_raise(rb_path2class("RubyDOSEmulator::Machine::Unpatched"), "the library has no %s", name);
    }
    return function;
}

#define FIND(field, name) m->call.field = (__typeof__(m->call.field))core_function(m, name)

static void find_core_functions(struct machine *m)
{
    FIND(set_environment, "retro_set_environment");
    FIND(set_video_refresh, "retro_set_video_refresh");
    FIND(set_audio_sample, "retro_set_audio_sample");
    FIND(set_audio_sample_batch, "retro_set_audio_sample_batch");
    FIND(set_input_poll, "retro_set_input_poll");
    FIND(set_input_state, "retro_set_input_state");
    FIND(init, "retro_init");
    FIND(deinit, "retro_deinit");
    FIND(load_game, "retro_load_game");
    FIND(unload_game, "retro_unload_game");
    FIND(run, "retro_run");
    FIND(set_controller_port_device, "retro_set_controller_port_device");
    FIND(get_system_av_info, "retro_get_system_av_info");
    FIND(get_memory_data, "retro_get_memory_data");
    FIND(get_memory_size, "retro_get_memory_size");
    FIND(set_directory, "vblank_set_directory");
    FIND(clock_at, "vblank_clock_at");
    FIND(key_event, "vblank_key_event");
    FIND(copy_picture, "vblank_copy_picture");
    FIND(take_sound, "vblank_take_sound");
}

/* The core's own frontend function +name+, handed to it through +setter+. */
static void hand_over(struct machine *m, void (*setter)(any_fn), const char *name)
{
    setter((any_fn)core_function(m, name));
}

/*
 * Machine.new(library, directory)
 *
 * Opens +library+ (a path), with its names kept to itself, hands the core the probe's frontend
 * functions, tells it +directory+ for its system and save files, and starts it (retro_init).
 */
static VALUE machine_initialize(VALUE self, VALUE library, VALUE directory)
{
    struct machine *m = machine_of(self);
    if (m->library || m->directory) rb_raise(rb_eRuntimeError, "this DOSBox machine is started already");

    m->directory = copied_string(directory);
    m->library = dlopen(StringValueCStr(library), RTLD_NOW | RTLD_LOCAL);
    if (!m->library) rb_raise(rb_eLoadError, "%s", dlerror());
    find_core_functions(m);

    hand_over(m, m->call.set_environment, "vblank_environment");
    hand_over(m, m->call.set_video_refresh, "vblank_video_refresh");
    hand_over(m, m->call.set_audio_sample, "vblank_audio_sample");
    hand_over(m, m->call.set_audio_sample_batch, "vblank_audio_batch");
    hand_over(m, m->call.set_input_poll, "vblank_input_poll");
    hand_over(m, m->call.set_input_state, "vblank_input_state");
    m->call.set_directory(m->directory);
    m->call.init();
    m->started = true;
    return self;
}

/* Starts the machine from the configuration file at +path+: true when the core took it. */
static VALUE machine_load_game(VALUE self, VALUE path)
{
    struct machine *m = open_machine(self);
    if (m->game_loaded) rb_raise(rb_eRuntimeError, "this DOSBox machine has a program loaded already");
    char *game_path = copied_string(path);
    free(m->game_path);
    m->game_path = game_path;

    struct retro_game_info info = { m->game_path, NULL, 0, NULL };
    m->game_loaded = m->call.load_game(&info);
    return m->game_loaded ? Qtrue : Qfalse;
}

static VALUE machine_set_controller_port_device(VALUE self, VALUE port, VALUE device)
{
    struct machine *m = open_machine(self);
    m->call.set_controller_port_device(NUM2UINT(port), NUM2UINT(device));
    return Qnil;
}

/* A key going down (true) or up (false), by libretro's key number. */
static VALUE machine_key_event(VALUE self, VALUE down, VALUE code)
{
    struct machine *m = open_machine(self);
    m->call.key_event(RTEST(down) ? 1 : 0, NUM2UINT(code));
    return Qnil;
}

/* Pins the clock chip: year, month, day, hour, minute, second, weekday, and whether the battery kept it. */
static VALUE machine_clock_at(int argc, VALUE *argv, VALUE self)
{
    struct machine *m = open_machine(self);
    rb_check_arity(argc, 8, 8);
    m->call.clock_at(NUM2INT(argv[0]), NUM2INT(argv[1]), NUM2INT(argv[2]), NUM2INT(argv[3]), NUM2INT(argv[4]),
                     NUM2INT(argv[5]), NUM2INT(argv[6]), RTEST(argv[7]) ? 1 : 0);
    return Qnil;
}

static void *run_without_lock(void *pointer)
{
    ((struct machine *)pointer)->call.run();
    return NULL;
}

static VALUE run_frame_without_lock(VALUE pointer)
{
    rb_thread_call_without_gvl(run_without_lock, (void *)pointer, NULL, NULL);
    return Qnil;
}

/* Marks the machine free again however the frame ended, so an interrupt Ruby raises around it leaves
 * no machine that refuses every later call. */
static VALUE mark_frame_over(VALUE pointer)
{
    ((struct machine *)pointer)->running = false;
    return Qnil;
}

/* Plays one frame (retro_run), with Ruby's lock let go: the core calls back nothing but its own code. */
static VALUE machine_run(VALUE self)
{
    struct machine *m = open_machine(self);
    m->running = true;
    rb_ensure(run_frame_without_lock, (VALUE)m, mark_frame_over, (VALUE)m);
    return Qnil;
}

/* [frames a second, sound samples a second], as the core says them now. */
static VALUE machine_timing(VALUE self)
{
    struct machine *m = open_machine(self);
    struct retro_system_av_info info;
    memset(&info, 0, sizeof(info));
    m->call.get_system_av_info(&info);
    return rb_ary_new_from_args(2, DBL2NUM(info.fps), DBL2NUM(info.sample_rate));
}

/* The last picture the core handed over as [bytes, width, height], four bytes a pixel (0xXXRRGGBB, little
 * end first), or nil before the first. */
static VALUE machine_picture(VALUE self)
{
    struct machine *m = open_machine(self);
    unsigned width = 0, height = 0;
    size_t count = m->call.copy_picture(NULL, 0, &width, &height);
    if (!count) return Qnil;

    VALUE bytes = rb_str_new(NULL, (long)(count * 4));
    m->call.copy_picture((uint32_t *)RSTRING_PTR(bytes), count, &width, &height);
    return rb_ary_new_from_args(3, bytes, UINT2NUM(width), UINT2NUM(height));
}

/* The sound made since this was last asked, as a String of signed 16-bit samples, left and right by turns. */
static VALUE machine_take_sound(VALUE self)
{
    struct machine *m = open_machine(self);
    size_t held = m->call.take_sound(NULL, 0);
    VALUE samples = rb_str_new(NULL, (long)(held * sizeof(int16_t)));
    size_t taken = m->call.take_sound((int16_t *)RSTRING_PTR(samples), held);
    rb_str_set_len(samples, (long)((taken < held ? taken : held) * sizeof(int16_t)));
    return samples;
}

/* Where memory +id+ is and how big, through the core's retro_get_memory_*. */
static uint8_t *memory_of(struct machine *m, unsigned id, size_t *size)
{
    *size = m->call.get_memory_size(id);
    return *size ? m->call.get_memory_data(id) : NULL;
}

/* The memory +id+ whole, copied out; empty when the core has none by that id. */
static VALUE machine_memory(VALUE self, VALUE id)
{
    struct machine *m = open_machine(self);
    size_t size;
    uint8_t *data = memory_of(m, NUM2UINT(id), &size);
    if (!data) return rb_str_new(NULL, 0);
    return rb_str_new((const char *)data, (long)size);
}

/* Where +count+ bytes from +offset+ of memory +id+ are, refused past its end. */
static uint8_t *memory_span(struct machine *m, VALUE id, VALUE offset, long count)
{
    unsigned which = NUM2UINT(id);
    size_t start = NUM2SIZET(offset);
    size_t size;
    uint8_t *data = memory_of(m, which, &size);
    if (count < 0 || !data || start > size || (size_t)count > size - start) {
        rb_raise(rb_eIndexError, "%ld bytes from %zu are past the end of memory %u, which is %zu bytes", count, start,
                 which, size);
    }
    return data + start;
}

/* +count+ bytes of memory +id+ from +offset+. */
static VALUE machine_memory_read(VALUE self, VALUE id, VALUE offset, VALUE count)
{
    struct machine *m = open_machine(self);
    long length = NUM2LONG(count);
    return rb_str_new((const char *)memory_span(m, id, offset, length), length);
}

/* +bytes+ written over memory +id+ from +offset+, as a program's own store would. */
static VALUE machine_memory_write(VALUE self, VALUE id, VALUE offset, VALUE bytes)
{
    struct machine *m = open_machine(self);
    StringValue(bytes);
    long length = RSTRING_LEN(bytes);
    memcpy(memory_span(m, id, offset, length), RSTRING_PTR(bytes), (size_t)length);
    return Qnil;
}

/* Shuts the machine and closes its library. Shutting a shut one does nothing. One nobody shut is shut
 * when Ruby frees it. */
static VALUE machine_close(VALUE self)
{
    struct machine *m = machine_of(self);
    if (m->running) rb_raise(rb_eRuntimeError, "this DOSBox machine is playing a frame on another thread");
    shut(m);
    return Qnil;
}

static VALUE machine_closed_p(VALUE self) { return machine_of(self)->library ? Qfalse : Qtrue; }

/*
 * Ractor-safe: a Machine is made and used inside one Ractor, keeps nothing in a process global, and the
 * core it runs calls no Ruby.
 */
void Init_ruby_dos_emulator_ext(void)
{
    rb_ext_ractor_safe(true);
    VALUE outer = rb_define_module("RubyDOSEmulator");
    VALUE machine = rb_define_class_under(outer, "Machine", rb_cObject);
    /* A library without the functions of a core built with the probe patch. */
    rb_define_class_under(machine, "Unpatched", rb_eLoadError);
    rb_define_alloc_func(machine, machine_allocate);
    rb_define_method(machine, "initialize", machine_initialize, 2);
    rb_define_method(machine, "load_game", machine_load_game, 1);
    rb_define_method(machine, "set_controller_port_device", machine_set_controller_port_device, 2);
    rb_define_method(machine, "key_event", machine_key_event, 2);
    rb_define_method(machine, "clock_at", machine_clock_at, -1);
    rb_define_method(machine, "run", machine_run, 0);
    rb_define_method(machine, "timing", machine_timing, 0);
    rb_define_method(machine, "picture", machine_picture, 0);
    rb_define_method(machine, "take_sound", machine_take_sound, 0);
    rb_define_method(machine, "memory", machine_memory, 1);
    rb_define_method(machine, "memory_read", machine_memory_read, 3);
    rb_define_method(machine, "memory_write", machine_memory_write, 3);
    rb_define_method(machine, "close", machine_close, 0);
    rb_define_method(machine, "closed?", machine_closed_p, 0);
    rb_define_const(outer, "BUILT_FROM", rb_obj_freeze(rb_str_new_cstr(RUBY_DOS_EMULATOR_BUILT_FROM)));
}
