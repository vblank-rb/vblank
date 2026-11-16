#ifndef LIBRETRO_FRONTEND_H
#define LIBRETRO_FRONTEND_H

#include <ruby.h>

/* Defines +outer+::Frontend, a libretro frontend written in C (see libretro_frontend.c). */
void libretro_frontend_define(VALUE outer);

#endif
