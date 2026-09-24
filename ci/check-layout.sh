#!/bin/sh
# Assert that src/structs.lisp agrees with the installed libusb.h.
#
# The Lisp suite pins these offsets against our own declarations, which catches
# a typo but cannot catch a header that changed underneath us. This compiles a C
# program against the real libusb.h, prints every offset that matters, and
# compares it with what CFFI computes -- on whatever architecture it runs on,
# which is the point: struct layout is exactly what differs between the x86_64
# box a change is written on and the aarch64 one it has to work on.
set -eu

: "${SBCL:=sbcl}"
: "${CC:=cc}"
CFLAGS=$(pkg-config --cflags libusb-1.0 2>/dev/null || echo "")
LIBS=$(pkg-config --libs libusb-1.0 2>/dev/null || echo "-lusb-1.0")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/layout.c" <<'C'
#include <stddef.h>
#include <stdio.h>
#include <libusb-1.0/libusb.h>
#define O(s,f) printf("%s.%s %zu\n", #s, #f, offsetof(struct s, f))
#define S(s)   printf("sizeof.%s %zu\n", #s, sizeof(struct s))
int main(void) {
    O(libusb_transfer, dev_handle);      O(libusb_transfer, flags);
    O(libusb_transfer, endpoint);        O(libusb_transfer, type);
    O(libusb_transfer, timeout);         O(libusb_transfer, status);
    O(libusb_transfer, length);          O(libusb_transfer, actual_length);
    O(libusb_transfer, callback);        O(libusb_transfer, user_data);
    O(libusb_transfer, buffer);          O(libusb_transfer, num_iso_packets);
    O(libusb_transfer, iso_packet_desc);
    S(libusb_device_descriptor);         S(libusb_config_descriptor);
    S(libusb_control_setup);             S(libusb_iso_packet_descriptor);
    S(libusb_endpoint_descriptor);       S(libusb_interface_descriptor);
    O(libusb_config_descriptor, interface);
    O(libusb_endpoint_descriptor, extra);
    O(libusb_interface_descriptor, endpoint);
    O(timeval, tv_usec);                 S(timeval);
    return 0;
}
C

# libusb-1.0/libusb.h vs libusb.h: pkg-config's -I points at the libusb-1.0
# directory, so try the bare name too rather than guessing.
if ! $CC $CFLAGS -o "$tmp/layout" "$tmp/layout.c" 2>/dev/null; then
    sed 's|<libusb-1.0/libusb.h>|<libusb.h>|' "$tmp/layout.c" > "$tmp/layout2.c"
    $CC $CFLAGS -o "$tmp/layout" "$tmp/layout2.c"
fi
"$tmp/layout" | sort > "$tmp/c.txt"

# --noinform matters: the banner goes to stdout, which is the diff input.
$SBCL --noinform --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval '(asdf:initialize-source-registry `(:source-registry (:tree ,(truename "./")) :ignore-inherited-configuration))' \
  --eval '(asdf:load-system :libusb/ffi)' \
  --load ci/layout.lisp | sort > "$tmp/lisp.txt"

if diff -u "$tmp/c.txt" "$tmp/lisp.txt"; then
    echo "==> struct layout agrees with libusb.h ($(uname -m))"
else
    echo "struct layout DISAGREES with libusb.h on $(uname -m)" >&2
    exit 1
fi
