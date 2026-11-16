/*
 * A LIBRETRO FRONTEND IN C: what plays one copy of a libretro core for Ruby, from any Ractor.
 *
 * A libretro core is an emulator built as a library with a fixed set of retro_* functions. The
 * program that loads it (the "frontend") calls retro_run once a frame, and the core calls back
 * through functions the frontend handed it: to ask a setting, to hand over a picture or a batch
 * of sound, and to ask which buttons are down.
 *
 * WHY C AND NOT FIDDLE. Ruby lets Fiddle run only on the main Ractor (Fiddle::Handle raises
 * Ractor::UnsafeError anywhere else), and a test suite plays its tests in Ractor workers. So the
 * callbacks are C functions that copy what they are handed into buffers of the frontend's own,
 * and Ruby reads those buffers between frames. No Ruby runs while the core runs, so this
 * extension declares itself Ractor-safe, and Ruby's garbage collector never meets a core's own
 * stacks (bsnes runs each chip as a cothread).
 *
 * ONE PATH, NOT TWO. There is no Fiddle path kept for the main Ractor: one way of playing a core is
 * one way to be right, and a picture read through one path and compared with a picture read through
 * the other would test the paths, not the cartridge.
 *
 * WHICH CONSOLE CALLED BACK. A libretro callback is handed no pointer to say which frontend it
 * belongs to, because libretro expects one core in a process. Here each frontend has a copy of the
 * core library of its own (the gem's KeptCopy), so two may run at once in two Ractors, on two
 * threads. Every call into a core sets a thread-local pointer to the frontend making it, and the
 * callbacks read that. A cothread switches stacks, never threads, so the pointer holds across it.
 *
 * THE SAME FILE SERVES ANY LIBRETRO CORE. Nothing here names a console: the core's settings, the
 * picture format it may ask for, and its memory ids all come from the Ruby that makes a Frontend.
 * So each emulator gem carries this file as it is, with an Init function of its own (its
 * ruby_<gem>_ext.c), rather than a frontend of each: ruby-snes-emulator's, ruby-genesis-emulator's
 * and ruby-ps1-emulator's copies are the same file, and a change to one is made to all three.
 *
 * The callbacks allocate with malloc, never through Ruby: Ruby's allocator may start the garbage
 * collector, and the core may call back from a stack Ruby knows nothing of.
 */
#include "libretro_frontend.h"

#include <dlfcn.h>
#include <ruby/thread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* libretro's numbers, from its libretro.h, for the few calls answered here. */
#define ENV_GET_CAN_DUPE 3
#define ENV_GET_SYSTEM_DIRECTORY 9
#define ENV_SET_PIXEL_FORMAT 10
#define ENV_GET_VARIABLE 15
#define ENV_GET_VARIABLE_UPDATE 17
#define ENV_GET_LOG_INTERFACE 27
#define ENV_GET_SAVE_DIRECTORY 31
#define PIXEL_FORMAT_XRGB8888 1
#define DEVICE_JOYPAD 1
#define JOYPAD_MASK 256
#define PORTS 2

struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_variable {
    const char *key;
    const char *value;
};

/* libretro's log function takes a level (an enum, passed as an int), a printf format and its values. */
typedef void (*log_fn)(int, const char *, ...);

struct retro_log_callback {
    log_fn log;
};

typedef bool (*environment_fn)(unsigned, void *);
typedef void (*video_refresh_fn)(const void *, unsigned, unsigned, size_t);
typedef void (*audio_sample_fn)(int16_t, int16_t);
typedef size_t (*audio_sample_batch_fn)(const int16_t *, size_t);
typedef void (*input_poll_fn)(void);
typedef int16_t (*input_state_fn)(unsigned, unsigned, unsigned, unsigned);

/* The core's functions this frontend calls. */
struct core_functions {
    void (*set_environment)(environment_fn);
    void (*set_video_refresh)(video_refresh_fn);
    void (*set_audio_sample)(audio_sample_fn);
    void (*set_audio_sample_batch)(audio_sample_batch_fn);
    void (*set_input_poll)(input_poll_fn);
    void (*set_input_state)(input_state_fn);
    void (*init)(void);
    void (*deinit)(void);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void (*run)(void);
    void (*set_controller_port_device)(unsigned, unsigned);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
};

struct frontend {
    void *library;              /* NULL once closed */
    struct core_functions call;
    bool started;               /* retro_init called */
    bool game_loaded;
    bool running;               /* inside retro_run, with Ruby's lock let go */
    bool out_of_memory;         /* a callback could not keep what it was handed */

    char *system_dir;
    char *save_dir;
    size_t setting_count;
    char **setting_keys;
    char **setting_values;
    int wanted_pixel_format;    /* -1: whichever the core asks for */
    unsigned bytes_per_pixel;   /* libretro's default format is two bytes a pixel */

    uint16_t buttons[PORTS];    /* one bit per libretro joypad id */

    int16_t *audio;             /* samples, left and right by turns */
    size_t audio_count;
    size_t audio_capacity;

    uint8_t *picture;           /* rows packed with no gap: width * bytes_per_pixel each */
    size_t picture_capacity;
    unsigned width;
    unsigned height;
    bool picture_new;

    char *game_path;
    void *game_data;            /* the cartridge's bytes, kept while the core holds it */
};

static _Thread_local struct frontend *current;

/* --- the callbacks: C only, never Ruby --- */

static bool grow(void **buffer, size_t *capacity, size_t wanted, size_t unit)
{
    if (wanted <= *capacity) return true;
    size_t capacity_wanted = *capacity ? *capacity : 4096;
    while (capacity_wanted < wanted) capacity_wanted *= 2;
    void *grown = realloc(*buffer, capacity_wanted * unit);
    if (!grown) return false;
    *buffer = grown;
    *capacity = capacity_wanted;
    return true;
}

static void keep_samples(struct frontend *f, const int16_t *samples, size_t count)
{
    if (!grow((void **)&f->audio, &f->audio_capacity, f->audio_count + count, sizeof(int16_t))) {
        f->out_of_memory = true;
        return;
    }
    memcpy(f->audio + f->audio_count, samples, count * sizeof(int16_t));
    f->audio_count += count;
}

static bool answer_setting(struct frontend *f, struct retro_variable *variable)
{
    if (!variable || !variable->key) return false;
    for (size_t i = 0; i < f->setting_count; i++) {
        if (strcmp(f->setting_keys[i], variable->key) == 0) {
            variable->value = f->setting_values[i];
            return true;
        }
    }
    return false;
}

/* What a core says as it works (which BIOS it found, which pads are plugged in) goes to a log its
 * frontend hands it, or to the terminal when it is handed none. This log hears it and says nothing:
 * a test run has no use for the chatter. */
static void quiet_log(int level, const char *format, ...)
{
    (void)level;
    (void)format;
}

/* What the core asks of its frontend. Anything not answered here is answered "no", which a core
 * takes as the frontend not having it. */
static bool on_environment(unsigned cmd, void *data)
{
    struct frontend *f = current;
    if (!f || !data) return false;

    switch (cmd & 0xFFFF) {
    case ENV_GET_CAN_DUPE:
        *(bool *)data = true;
        return true;
    case ENV_SET_PIXEL_FORMAT: {
        int format = *(const int *)data;
        if (f->wanted_pixel_format >= 0 && format != f->wanted_pixel_format) return false;
        f->bytes_per_pixel = format == PIXEL_FORMAT_XRGB8888 ? 4 : 2;
        return true;
    }
    case ENV_GET_SYSTEM_DIRECTORY:
        *(const char **)data = f->system_dir;
        return true;
    case ENV_GET_SAVE_DIRECTORY:
        *(const char **)data = f->save_dir;
        return true;
    case ENV_GET_VARIABLE:
        return answer_setting(f, data);
    case ENV_GET_VARIABLE_UPDATE:
        *(bool *)data = false;
        return true;
    case ENV_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = quiet_log;
        return true;
    default:
        return false;
    }
}

/* A picture handed over at the end of a frame. A null one is the last frame again. */
static void on_video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
    struct frontend *f = current;
    if (!f || !data) return;

    size_t row = (size_t)width * f->bytes_per_pixel;
    if (!grow((void **)&f->picture, &f->picture_capacity, row * height, 1)) {
        f->out_of_memory = true;
        return;
    }
    for (unsigned y = 0; y < height; y++) {
        memcpy(f->picture + row * y, (const uint8_t *)data + pitch * y, row);
    }
    f->width = width;
    f->height = height;
    f->picture_new = true;
}

static void on_audio_sample(int16_t left, int16_t right)
{
    struct frontend *f = current;
    if (!f) return;
    int16_t pair[2] = { left, right };
    keep_samples(f, pair, 2);
}

static size_t on_audio_sample_batch(const int16_t *data, size_t frames)
{
    struct frontend *f = current;
    if (f && data) keep_samples(f, data, frames * 2);
    return frames;
}

static void on_input_poll(void) {}

/* One button of a controller, or all of them as bits when the core asks for the mask. */
static int16_t on_input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
    (void)index;
    struct frontend *f = current;
    if (!f || device != DEVICE_JOYPAD || port >= PORTS) return 0;
    if (id == JOYPAD_MASK) return (int16_t)f->buttons[port];
    return id < 16 && (f->buttons[port] >> id) & 1;
}

/* --- calls into the core, each made as the frontend it belongs to --- */

#define WITH_CURRENT(f, statement) \
    do { \
        struct frontend *was_ = current; \
        current = (f); \
        statement; \
        current = was_; \
    } while (0)

static void *run_without_lock(void *pointer)
{
    struct frontend *f = pointer;
    WITH_CURRENT(f, f->call.run());
    return NULL;
}

static VALUE run_frame_without_lock(VALUE pointer)
{
    rb_thread_call_without_gvl(run_without_lock, (void *)pointer, NULL, NULL);
    return Qnil;
}

/* Marks the frontend free again however the frame ended, so an interrupt Ruby raises around it
 * (Thread#raise, a timeout) leaves no frontend that refuses every later call. */
static VALUE mark_frame_over(VALUE pointer)
{
    ((struct frontend *)pointer)->running = false;
    return Qnil;
}

/* Takes the cartridge out (the core writes its saves), shuts the core and closes the library. */
static void shut(struct frontend *f)
{
    if (!f->library) return;
    if (f->game_loaded) WITH_CURRENT(f, f->call.unload_game());
    if (f->started) WITH_CURRENT(f, f->call.deinit());
    dlclose(f->library);
    f->library = NULL;
    f->game_loaded = false;
    f->started = false;
}

static void free_strings(char **strings, size_t count)
{
    if (!strings) return;
    for (size_t i = 0; i < count; i++) free(strings[i]);
    free(strings);
}

static void frontend_free(void *pointer)
{
    struct frontend *f = pointer;
    shut(f);
    free(f->system_dir);
    free(f->save_dir);
    free_strings(f->setting_keys, f->setting_count);
    free_strings(f->setting_values, f->setting_count);
    free(f->audio);
    free(f->picture);
    free(f->game_path);
    free(f->game_data);
    free(f);
}

static size_t frontend_size(const void *pointer)
{
    const struct frontend *f = pointer;
    return sizeof(*f) + f->audio_capacity * sizeof(int16_t) + f->picture_capacity;
}

static const rb_data_type_t frontend_type = {
    .wrap_struct_name = "libretro frontend",
    /* Not freed immediately: freeing one nobody closed takes its game out, which writes a save
     * file, and closes a library, neither of which belongs in the middle of a sweep. */
    .function = { .dmark = NULL, .dfree = frontend_free, .dsize = frontend_size },
};

static VALUE frontend_allocate(VALUE klass)
{
    struct frontend *f = calloc(1, sizeof(*f));
    if (!f) rb_raise(rb_eNoMemError, "no memory for a libretro frontend");
    f->wanted_pixel_format = -1;
    f->bytes_per_pixel = 2;
    return TypedData_Wrap_Struct(klass, &frontend_type, f);
}

static struct frontend *frontend_of(VALUE self)
{
    struct frontend *f;
    TypedData_Get_Struct(self, struct frontend, &frontend_type, f);
    return f;
}

/* The frontend of +self+, refused when it is closed or inside a frame on another thread. */
static struct frontend *open_frontend(VALUE self)
{
    struct frontend *f = frontend_of(self);
    if (!f->library) rb_raise(rb_eRuntimeError, "this libretro core is closed");
    if (f->running) rb_raise(rb_eRuntimeError, "this libretro core is playing a frame on another thread");
    return f;
}

static char *copied_string(VALUE text)
{
    const char *from = StringValueCStr(text);
    char *copy = strdup(from);
    if (!copy) rb_raise(rb_eNoMemError, "no memory for a libretro frontend");
    return copy;
}

static int copy_setting(VALUE key, VALUE value, VALUE arg)
{
    struct frontend *f = (struct frontend *)arg;
    /* Both checked before either is copied, so a refused one leaves no copy uncounted. */
    StringValueCStr(key);
    StringValueCStr(value);
    f->setting_keys[f->setting_count] = copied_string(key);
    f->setting_count++;
    f->setting_values[f->setting_count - 1] = copied_string(value);
    return ST_CONTINUE;
}

/* The library's retro_* function +name+, or a LoadError naming it. */
static void *core_function(struct frontend *f, const char *name)
{
    void *function = dlsym(f->library, name);
    if (!function) rb_raise(rb_eLoadError, "the libretro core has no %s", name);
    return function;
}

static void find_core_functions(struct frontend *f)
{
    struct core_functions *c = &f->call;
    c->set_environment = (void (*)(environment_fn))core_function(f, "retro_set_environment");
    c->set_video_refresh = (void (*)(video_refresh_fn))core_function(f, "retro_set_video_refresh");
    c->set_audio_sample = (void (*)(audio_sample_fn))core_function(f, "retro_set_audio_sample");
    c->set_audio_sample_batch = (void (*)(audio_sample_batch_fn))core_function(f, "retro_set_audio_sample_batch");
    c->set_input_poll = (void (*)(input_poll_fn))core_function(f, "retro_set_input_poll");
    c->set_input_state = (void (*)(input_state_fn))core_function(f, "retro_set_input_state");
    c->init = (void (*)(void))core_function(f, "retro_init");
    c->deinit = (void (*)(void))core_function(f, "retro_deinit");
    c->load_game = (bool (*)(const struct retro_game_info *))core_function(f, "retro_load_game");
    c->unload_game = (void (*)(void))core_function(f, "retro_unload_game");
    c->run = (void (*)(void))core_function(f, "retro_run");
    c->set_controller_port_device = (void (*)(unsigned, unsigned))core_function(f, "retro_set_controller_port_device");
    c->get_memory_data = (void *(*)(unsigned))core_function(f, "retro_get_memory_data");
    c->get_memory_size = (size_t (*)(unsigned))core_function(f, "retro_get_memory_size");
}

/*
 * Frontend.new(library, system_dir, save_dir, settings, pixel_format)
 *
 * Opens +library+ (a path), with its names kept to itself, hands it the callbacks and starts it
 * (retro_init). The two directories are what the core is told when it asks where its system files
 * and its saves go. +settings+ is a Hash of the core's own setting names to their values, answered
 * when the core asks; +pixel_format+ is libretro's number for the one picture format to accept, or
 * nil for whichever the core asks for.
 */
static VALUE frontend_initialize(VALUE self, VALUE library, VALUE system_dir, VALUE save_dir, VALUE settings,
                                 VALUE pixel_format)
{
    struct frontend *f = frontend_of(self);
    if (f->library || f->system_dir) rb_raise(rb_eRuntimeError, "this libretro frontend is started already");

    Check_Type(settings, T_HASH);
    f->system_dir = copied_string(system_dir);
    f->save_dir = copied_string(save_dir);
    size_t count = RHASH_SIZE(settings);
    f->setting_keys = calloc(count ? count : 1, sizeof(char *));
    f->setting_values = calloc(count ? count : 1, sizeof(char *));
    if (!f->setting_keys || !f->setting_values) rb_raise(rb_eNoMemError, "no memory for a libretro frontend");
    rb_hash_foreach(settings, copy_setting, (VALUE)f);
    if (!NIL_P(pixel_format)) f->wanted_pixel_format = NUM2INT(pixel_format);

    f->library = dlopen(StringValueCStr(library), RTLD_NOW | RTLD_LOCAL);
    if (!f->library) rb_raise(rb_eLoadError, "%s", dlerror());
    find_core_functions(f);

    WITH_CURRENT(f, {
        f->call.set_environment(on_environment);
        f->call.set_video_refresh(on_video_refresh);
        f->call.set_audio_sample(on_audio_sample);
        f->call.set_audio_sample_batch(on_audio_sample_batch);
        f->call.set_input_poll(on_input_poll);
        f->call.set_input_state(on_input_state);
        f->call.init();
    });
    f->started = true;
    return self;
}

/* Loads the game at +path+, whose bytes are +bytes+: true when the core took it. */
static VALUE frontend_load_game(VALUE self, VALUE path, VALUE bytes)
{
    struct frontend *f = open_frontend(self);
    if (f->game_loaded) rb_raise(rb_eRuntimeError, "this libretro core has a game loaded already");
    StringValue(bytes);
    StringValueCStr(path);

    /* Nothing below raises until both copies are in place, so neither field is left freed. */
    size_t size = RSTRING_LEN(bytes);
    char *game_path = strdup(RSTRING_PTR(path));
    void *game_data = malloc(size ? size : 1);
    if (!game_path || !game_data) {
        free(game_path);
        free(game_data);
        rb_raise(rb_eNoMemError, "no memory for a game of %zu bytes", size);
    }
    memcpy(game_data, RSTRING_PTR(bytes), size);
    free(f->game_path);
    free(f->game_data);
    f->game_path = game_path;
    f->game_data = game_data;

    struct retro_game_info info = { f->game_path, f->game_data, size, NULL };
    bool loaded = false;
    WITH_CURRENT(f, loaded = f->call.load_game(&info));
    f->game_loaded = loaded;
    return loaded ? Qtrue : Qfalse;
}

static VALUE frontend_set_controller_port_device(VALUE self, VALUE port, VALUE device)
{
    struct frontend *f = open_frontend(self);
    WITH_CURRENT(f, f->call.set_controller_port_device(NUM2UINT(port), NUM2UINT(device)));
    return Qnil;
}

/* The buttons down on controller +port+: bit n set for libretro's joypad id n. */
static VALUE frontend_set_buttons(VALUE self, VALUE port, VALUE mask)
{
    struct frontend *f = open_frontend(self);
    unsigned index = NUM2UINT(port);
    if (index >= PORTS) rb_raise(rb_eArgError, "a libretro frontend here has controllers 0 and 1, not %u", index);
    f->buttons[index] = (uint16_t)NUM2UINT(mask);
    return Qnil;
}

/* Plays one frame (retro_run), with Ruby's lock let go: nothing it calls back runs Ruby. */
static VALUE frontend_run(VALUE self)
{
    struct frontend *f = open_frontend(self);
    f->running = true;
    rb_ensure(run_frame_without_lock, (VALUE)f, mark_frame_over, (VALUE)f);
    if (f->out_of_memory) {
        f->out_of_memory = false;
        rb_raise(rb_eNoMemError, "the libretro core handed over a picture or sound there was no memory to keep");
    }
    return Qnil;
}

/* The sound since this was last asked, as a String of signed 16-bit samples, left and right by turns. */
static VALUE frontend_drain_audio(VALUE self)
{
    struct frontend *f = open_frontend(self);
    VALUE samples = rb_str_new((const char *)f->audio, (long)(f->audio_count * sizeof(int16_t)));
    f->audio_count = 0;
    return samples;
}

/* The picture handed over since this was last asked, as [bytes, width, height] with each row packed
 * (width times two or four bytes, as the pixel format is), or nil when none was. */
static VALUE frontend_drain_picture(VALUE self)
{
    struct frontend *f = open_frontend(self);
    if (!f->picture_new) return Qnil;

    f->picture_new = false;
    VALUE bytes = rb_str_new((const char *)f->picture, (long)((size_t)f->width * f->height * f->bytes_per_pixel));
    return rb_ary_new_from_args(3, bytes, UINT2NUM(f->width), UINT2NUM(f->height));
}

static VALUE frontend_memory_size(VALUE self, VALUE id)
{
    struct frontend *f = open_frontend(self);
    size_t size = 0;
    WITH_CURRENT(f, size = f->call.get_memory_size(NUM2UINT(id)));
    return SIZET2NUM(size);
}

/* The memory +id+ whole, copied out, as the core hands it over: its size asked first, then its
 * bytes, which is the order a core that makes a memory up when asked (a profile) needs. */
static VALUE frontend_memory(VALUE self, VALUE id)
{
    struct frontend *f = open_frontend(self);
    unsigned which = NUM2UINT(id);
    size_t size = 0;
    void *data = NULL;
    WITH_CURRENT(f, {
        size = f->call.get_memory_size(which);
        if (size) data = f->call.get_memory_data(which);
    });
    if (!size || !data) return rb_str_new(NULL, 0);
    return rb_str_new(data, (long)size);
}

/* Where +count+ bytes from +offset+ of memory +id+ are, refused past its end. */
static uint8_t *memory_span(struct frontend *f, VALUE id, VALUE offset, long count)
{
    unsigned which = NUM2UINT(id);
    size_t start = NUM2SIZET(offset);
    size_t size = 0;
    uint8_t *data = NULL;
    WITH_CURRENT(f, {
        size = f->call.get_memory_size(which);
        if (size) data = f->call.get_memory_data(which);
    });
    if (count < 0 || !data || start > size || (size_t)count > size - start) {
        rb_raise(rb_eIndexError, "%ld bytes from %zu are past the end of memory %u, which is %zu bytes", count, start,
                 which, size);
    }
    return data + start;
}

/* +count+ bytes of memory +id+ from +offset+, read in place. */
static VALUE frontend_memory_read(VALUE self, VALUE id, VALUE offset, VALUE count)
{
    struct frontend *f = open_frontend(self);
    long length = NUM2LONG(count);
    return rb_str_new((const char *)memory_span(f, id, offset, length), length);
}

/* +bytes+ written over memory +id+ from +offset+. */
static VALUE frontend_memory_write(VALUE self, VALUE id, VALUE offset, VALUE bytes)
{
    struct frontend *f = open_frontend(self);
    StringValue(bytes);
    long length = RSTRING_LEN(bytes);
    memcpy(memory_span(f, id, offset, length), RSTRING_PTR(bytes), (size_t)length);
    return Qnil;
}

/* Takes the game out (the core writes its saves), shuts the core and closes its library. Closing a
 * closed one does nothing. A frontend nobody closed is closed when Ruby frees it. */
static VALUE frontend_close(VALUE self)
{
    struct frontend *f = frontend_of(self);
    if (f->running) rb_raise(rb_eRuntimeError, "this libretro core is playing a frame on another thread");
    shut(f);
    return Qnil;
}

static VALUE frontend_closed_p(VALUE self) { return frontend_of(self)->library ? Qfalse : Qtrue; }

void libretro_frontend_define(VALUE outer)
{
    VALUE frontend = rb_define_class_under(outer, "Frontend", rb_cObject);
    rb_define_alloc_func(frontend, frontend_allocate);
    rb_define_method(frontend, "initialize", frontend_initialize, 5);
    rb_define_method(frontend, "load_game", frontend_load_game, 2);
    rb_define_method(frontend, "set_controller_port_device", frontend_set_controller_port_device, 2);
    rb_define_method(frontend, "set_buttons", frontend_set_buttons, 2);
    rb_define_method(frontend, "run", frontend_run, 0);
    rb_define_method(frontend, "drain_audio", frontend_drain_audio, 0);
    rb_define_method(frontend, "drain_picture", frontend_drain_picture, 0);
    rb_define_method(frontend, "memory_size", frontend_memory_size, 1);
    rb_define_method(frontend, "memory", frontend_memory, 1);
    rb_define_method(frontend, "memory_read", frontend_memory_read, 3);
    rb_define_method(frontend, "memory_write", frontend_memory_write, 3);
    rb_define_method(frontend, "close", frontend_close, 0);
    rb_define_method(frontend, "closed?", frontend_closed_p, 0);
}
