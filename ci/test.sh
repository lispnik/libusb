#!/bin/sh
# What CI runs. The last commands are `make test' and `make check' -- the same ones a
# developer runs -- because a CI script that tests something else is a CI script that
# goes green on a tree nobody can build.
#
# There are no USB devices on a GitHub runner, and that is not the limitation it sounds
# like. The callback tier drives this library's own C entry points from Lisp -- the
# transfer dispatcher through its function pointer, minted log and hotplug closures
# likewise -- so the registry, the demultiplexer, the error containment, the transfer
# state machine and every struct offset are all covered here. The tiers that need a bus
# skip themselves by name. What CI cannot do is move bytes; that is what the Raspberry Pi
# in `make pi-test-root' is for.
set -eu

: "${CCC_DIR:=vendor/cffi-callback-closures}"
: "${CCC_REPO:=https://github.com/lispnik/cffi-callback-closures}"

# cffi-callback-closures is not published to any ocicl registry, so it cannot be
# restored from ocicl.csv -- it has to arrive as a path. Cloned rather than carried as a
# submodule: one fewer thing to forget to update, and the Makefile puts exactly this one
# directory on the source registry with :directory, so its own vendored dependencies
# never join ours.
if [ ! -f "$CCC_DIR/cffi-callback-closures.asd" ]; then
    echo "==> cloning cffi-callback-closures into $CCC_DIR"
    mkdir -p "$(dirname "$CCC_DIR")"
    # Retried: ghcr.io and github both fail often enough over a year of CI runs to be
    # worth three attempts rather than one red build.
    for attempt in 1 2 3; do
        if git clone --depth 1 "$CCC_REPO" "$CCC_DIR"; then break; fi
        echo "==> clone attempt $attempt failed; retrying"
        rm -rf "$CCC_DIR"
        sleep 5
    done
    test -f "$CCC_DIR/cffi-callback-closures.asd"
fi

if [ ! -d ocicl ]; then
    echo "==> restoring vendored dependencies"
    # ocicl exits 0 when a download fails, so the presence of the directory is checked
    # rather than the exit status.
    for attempt in 1 2 3; do
        ocicl install && test -d ocicl && break
        echo "==> ocicl install attempt $attempt did not produce ocicl/; retrying"
        sleep 5
    done
    test -d ocicl
fi

echo "==> libusb and libffi versions on this runner"
pkg-config --modversion libusb-1.0 || true
pkg-config --modversion libffi || true

make test CCC_DIR="$CCC_DIR"
make check CCC_DIR="$CCC_DIR"

# The half of the struct-layout assertion a Lisp test cannot make: our declarations
# against the installed libusb.h, compiled by a C compiler, on this architecture.
make layout CCC_DIR="$CCC_DIR"
