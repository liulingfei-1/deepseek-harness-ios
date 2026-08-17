/*
 * Public umbrella for the pinned OpenMinis/ish-arm64 static libraries.
 * The included implementation remains governed by its upstream GPL terms.
 */

#ifndef HARNESS_OPENMINIS_ISH_H
#define HARNESS_OPENMINIS_ISH_H

#ifndef ISH_INTERNAL
#define ISH_INTERNAL 1
#define HARNESS_OPENMINIS_ISH_UNDEFINE_INTERNAL 1
#endif

#include "misc.h"
#include "debug.h"

#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/errno.h"

#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/poll.h"
#include "fs/dev.h"
#include "fs/sock.h"

#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/mmu.h"

#include "platform/platform.h"

#ifdef HARNESS_OPENMINIS_ISH_UNDEFINE_INTERNAL
#undef HARNESS_OPENMINIS_ISH_UNDEFINE_INTERNAL
#undef ISH_INTERNAL
#endif

#endif
