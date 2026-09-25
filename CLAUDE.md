# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CFFI bindings to **libusb-1.0**, in two layers: a complete raw layer over every entry
point libusb exports, and an ergonomic layer over contexts, enumeration, descriptors,
synchronous and asynchronous transfers, hotplug and logging. SBCL, developed on macOS
arm64 against libusb 1.0.30, verified on a Raspberry Pi 4 (aarch64) against 1.0.28,
and CI-tested on Ubuntu 24.04 (x86_64 and aarch64) against 1.0.27.

## Commands

Dependencies are vendored under `ocicl/` (ocicl-managed; restore with `ocicl install`).
`cffi-callback-closures` is **not** in any ocicl registry and must be a checkout on the
source registry -- the Makefile takes `CCC_DIR` for it, defaulting to a sibling.

```sh
make test          # every suite that needs no USB device; what CI runs
make check         # also loads libusb/hw-tests, so it cannot rot unnoticed
make layout        # our struct offsets vs. the installed libusb.h, via a C compiler
make deploy        # rsync this tree + ocicl/ + the ccc checkout to pi@rpi4
make pi-test       # unprivileged suites on the Pi
make pi-test-root  # adds the CC2531 hardware tier, under the Pi's passwordless sudo
make clean         # drop this tree's fasl cache
```

```lisp
(asdf:load-system :libusb)            ; no libffi, no C toolchain needed
(asdf:load-system :libusb/closures)   ; adds hotplug and log callbacks
(asdf:test-system :libusb)            ; -> libusb/tests
```

To run one test: `(fiveam:run! 'libusb/tests::the-dispatcher-finds-the-right-transfer-out-of-a-thousand)`.

The Lisp snippets above assume a source registry. The Makefile's `BOOT` sets up a
**hermetic** one on purpose. It walks this tree as a `:tree`, excluding `vendor/`, and
adds exactly one `:directory` for `CCC_DIR`, ignoring inherited configuration. A `:tree`
over the ccc checkout (or over `vendor/`, where CI clones it) would bring in its own
vendored copy of cffi, and two cffis on the registry produce errors that look like type
confusion. At a REPL, copy that `initialize-source-registry` form. Don't widen it.

CI (`ci/test.sh`, on Linux x86_64 and aarch64) runs `make test`, `make check` and
`make layout`, in that order. It clones cffi-callback-closures into
`vendor/cffi-callback-closures` if it's missing.

Always use `make deploy` to push to the Pi, never a bare rsync. rsync keeps mtimes, so
the Pi's ASDF can decide stale fasls are current. `deploy` deletes both the `pi` fasl
cache and root's (`pi-test-root` runs under `sudo -E`), then checks that they're gone.

## Architecture

Five systems, split by **build-time dependency weight** rather than platform. Every file
needs CFFI, so the usual portable-core seam does not apply; the seam that matters is
libffi.

```
libusb/ffi       cffi                                 raw layer; loads with no libusb present
libusb           libusb/ffi + bordeaux-threads        sync + async transfers + event loop
libusb/closures  libusb + cffi-callback-closures      hotplug + log callbacks
libusb/tests     libusb/closures + fiveam             no USB device required
libusb/hw-tests  libusb/tests                         needs the CC2531 and permission
```

`libusb/ffi` earns its own system twice: streams, `dev_mem` and the BOS/SuperSpeed
descriptors are raw-only by design, and because `defcfun` resolves lazily and
`load-libraries` is lazy it loads on a machine with no libusb at all -- which is what lets
the enum, struct-offset and descriptor tests run anywhere. `libusb/closures` is separate
because `cffi-callback-closures` brings `cffi-libffi` and `cffi-grovel`, i.e. libffi
headers and a C compiler, and is in no ocicl registry; keeping it out of `#:libusb` keeps
`ocicl install libusb` possible.

One package, `#:libusb`. The raw layer is exported under a `%libusb-` prefix; exports are
declared in the system that implements them (`src/package.lisp`, `src/api-package.lisp`,
`src/closures-package.lisp`) so each system advertises only what it provides.

### Two callback mechanisms, on purpose

```
transfer completion:  C ──▶ ONE cffi:defcallback (%transfer-complete)
                              │  demux on transfer->user_data (an integer index)
                              ▼
                            *transfers* ──▶ transfer record (buffer, fn, handle)

hotplug and logging:  C ──▶ a libffi closure minted per Lisp closure
                            (cffi-callback-closures:make-foreign-callback)
```

Transfers get the static callback because `ffi_closure_alloc` costs an mmap'd executable
page per closure and transfers are many and short-lived; `libusb_transfer` carries a
`void *user_data` that is exactly the demultiplexer a closure would pay for. Hotplug and
logging get closures because they are few and long-lived -- and for logging it is the only
option: `libusb_set_log_cb` takes **no** `user_data`, so a per-context Lisp handler has
nowhere to put a registry index.

## Conventions and constraints

- **Nothing in `src/ffi.lisp` signals.** Raw bindings return what C returned;
  `CHECK-RESULT` is the single place negative-means-error is interpreted.
- **Never let CFFI's enum translation see a value from a device.**
  `FOREIGN-ENUM-KEYWORD` signals on an unknown value, so a class code or speed from a
  future device would break enumeration for the whole bus. Device-reported bindings
  return `:int` and the ergonomic layer converts with `ENUM-KEYWORD`, which falls back to
  the integer.
- **libusb version differences are a run-time fact, never `#+`.** Entry points that
  exist only in 1.0.28 or later go in `src/ffi-optional.lisp`, behind a
  `cffi:foreign-symbol-pointer` probe that signals `LIBUSB-UNSUPPORTED-FUNCTION` when
  the symbol is absent. A saved image can be restored against a different libusb.
- **Every callback body goes through `WITH-CALLBACK-GUARD`.** Neither
  `cffi:defcallback` nor `cffi-callback-closures` contains an error; an escaped condition
  reaches libusb's C frame. The guard also masks float traps, because a callback can
  arrive on a thread libusb created whose FPU control word is not SBCL's.
- **The ergonomic layer owns no foreign memory across a function boundary** except
  context, device and device handle. Descriptors are deep-copied and libusb's tree freed
  before return.
- **No GC finalizers.** A finalizer calling `libusb_unref_device` can run after
  `libusb_exit`. The context owns the references instead.
- **Async buffers are `foreign-alloc`'d, never pinned.** SBCL pinning is dynamic-extent
  and an async buffer must outlive the submitting form.
- **Teardown order is registered in one place** (`REGISTER-CONTEXT-TEARDOWN` in
  `src/core.lisp`, steps 10–70), because getting it wrong is a use-after-free rather
  than a leak. In particular the event pump is stopped and **joined** before
  `libusb_exit`, and minted closures are freed only *after* it.

### Things that are easy to get wrong here

- `struct libusb_transfer`'s flexible `iso_packet_desc[]` starts at **offset 60** on LP64
  while `sizeof` is 64 and CFFI's `foreign-type-size` reports 72. Use
  `+TRANSFER-ISO-PACKET-DESC-OFFSET+`; never the type size.
- `flags` is a `uint8_t`, so the bitfield must be `(defbitfield (… :uint8))`. An `:int`
  base reads four bytes and misreads `FREE_TRANSFER` as set whenever the endpoint is 4.
- `struct timeval`'s `tv_usec` is 32 bits on Darwin and a `long` on glibc. The one
  platform-conditional struct.
- `libusb_set_option` is variadic and **mis-passes its argument on Apple arm64**, where
  variadic arguments go on the stack rather than in registers. Measured with a C probe:
  a variadic callee handed 42 from Lisp receives garbage on macOS arm64 and 42 on Linux
  aarch64, and `libusb_set_option(ctx, LOG_LEVEL, 2)` returns `-2` from Lisp on macOS
  while returning `0` when C makes the same call. Nothing in this library calls it; use
  `libusb_init_context`'s option array, `%LIBUSB-SET-DEBUG`, or `%LIBUSB-SET-LOG-CB`.
- `LIBUSB_CLASS_IMAGE` and `LIBUSB_CLASS_PTP` are both `0x06`; CFFI keeps the last
  definition, so the order in `enums.lisp` is load-bearing.
- A **zero `wMaxPacketSize` is legal** for an isochronous endpoint -- it is how an
  alternate setting claims no bandwidth, and every Bluetooth adapter does it for SCO.
  A test asserting otherwise passes on a laptop and fails on the Pi.
- `LIBUSB_HOTPLUG_ENUMERATE` fires the callback *during* registration, so a registration
  must be marked live before the register call. Returning `:DEREGISTER` does **not**
  abandon the enumerate pass; libusb finishes walking the device list.
- `libusb_pollfds_handle_timeouts` returns false on macOS. An external event loop there
  must drive `libusb_get_next_timeout` itself.
- libusb writes its own copy of every log message to file descriptor 2 in addition to
  calling the handler, and at `:debug` that is hundreds of lines Lisp cannot redirect.

## Testing

Tiered by what each tier needs from the machine, split across two ASDF systems rather
than `#+` or environment flags. The valuable trick: **the callback tier calls this
library's own C entry points from Lisp** -- `foreign-funcall-pointer` on
`(cffi:callback %transfer-complete)`, and on minted log and hotplug closures -- so the
registry, demultiplexer, guard, state machine and struct offsets are all covered with no
device, no permissions and no timing. `LIBUSB_HOTPLUG_ENUMERATE` does the same for
hotplug against a real bus.

FiveAM has no teardown, so: every resource is acquired by a macro with an
`unwind-protect` (`tests/helpers.lisp`), a hygiene suite asserts nothing survived the
run, and `RUN-TESTS` fails the run if its final `SHUTDOWN-ALL` had work to do.

`tests/helpers.lisp` holds `*FORBIDDEN*`, enforced in code: on the Pi the Bluetooth
adapters have `btusb` bound and are in use, and the hub they hang off must not be reset.
The suite may open the CC2531 (`0451:16AE`) and nothing else.

Tunables come from the environment: `LIBUSB_TEST_TIME_SCALE=4` on a loaded Pi. No test
asserts an exact duration, only a band, and no test asserts what a device chooses to
send -- the async bulk read accepts `:timed-out` or `:completed`, because a dongle left
running a sniffer firmware would otherwise fail the suite for the state of somebody's
flash.

## Known-incomplete

- **Isochronous transfers** are bound and their packet arithmetic is tested, but nothing
  has streamed over one: neither test machine has an iso-capable device the suite is
  allowed to claim.
- **Bulk streams** (`libusb_alloc_streams`) are bound and unexercised -- USB 3 only, and
  in practice Linux only.
- **`dev_mem`** zero-copy buffers fall back to `malloc` silently where unsupported;
  `TRANSFER-DEV-MEM` reports which was used.
- **BOS and SuperSpeed capability descriptors** are raw-only: bound, with no Lisp-side
  parsing, and untested for want of a device that has them.
- **`libusb_wrap_sys_device`** is bound and untested; it wants an Android-style
  pre-opened descriptor.
- **The pollfd notifier path** is tested for installation and teardown, not for driving a
  real external event loop.
