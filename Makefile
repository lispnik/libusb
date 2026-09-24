# Build and test the libusb binding.
#
#   make test         -- the suites that need no USB device (runs anywhere, incl. CI)
#   make check        -- also load the hardware suite, to prove it still compiles
#   make layout       -- check the foreign struct offsets against libusb.h itself
#   make deploy       -- copy this tree and cffi-callback-closures to the Pi
#   make pi-test      -- run the unprivileged suites on the Pi, as pi
#   make pi-test-root -- run every suite on the Pi under sudo (needs /dev/bus/usb)
#   make clean        -- drop this tree's SBCL fasl cache
#
# There is no binary to build: this is a library. Its consumers embed it.
#
# The hardware tier needs the TI CC2531 dongle (0451:16AE) and read/write access to
# /dev/bus/usb. On the Pi those nodes are root:root 0664, so as user `pi' the privileged
# tests SKIP by name and as root they run. Nothing is installed on the Pi to change
# that: a udev rule would be a permanent change to somebody else's machine in exchange
# for saving one sudo.

SBCL       ?= sbcl
SBCL_FLAGS := --noinform --non-interactive --no-userinit --no-sysinit

# cffi-callback-closures is ours and is in no ocicl registry, so it resolves as a path or
# not at all. A sibling checkout for development; CI clones it under vendor/.
CCC_DIR ?= ../cffi-callback-closures

# Hermetic: this tree, its vendored ocicl/ deps, and exactly one directory of the
# cffi-callback-closures checkout. If something is missing we want a loud failure, not a
# neighbour's copy.
#
# :directory, not :tree, for CCC_DIR -- so we pick up cffi-callback-closures.asd without
# also inheriting its own vendored dependencies and ending up with two copies of cffi on
# the registry. Two cffis is an afternoon of errors that all look like type confusion,
# because that is exactly what they are.
#
# (:also-exclude "vendor") for the same reason in the other direction: CI clones
# cffi-callback-closures into vendor/, and a plain :tree of "./" would walk into
# vendor/*/ocicl/ and find that second cffi anyway. It is a directive of its own rather
# than an :exclude inside the :tree -- ASDF rejects the latter.
BOOT := --eval "(require :asdf)" \
        --eval "(asdf:initialize-source-registry \`(:source-registry (:also-exclude \"vendor\") (:tree ,(truename \"./\")) (:directory ,(truename \"$(CCC_DIR)/\")) :ignore-inherited-configuration))"
# Where the USB devices are. Overridable: make deploy HOST=pi@other
HOST     ?= pi@rpi4
DEST     ?= ~/libusb/
CCC_DEST ?= ~/cffi-callback-closures/

# Plain `make', not $(MAKE): that expands to this machine's absolute path, which on macOS
# is inside Xcode and does not exist on the Pi.
REMOTE_MAKE ?= make

.PHONY: test check hw-test layout deploy pi-test pi-test-root clean help
.DEFAULT_GOAL := test

# Needs no USB device at all: the callback machinery is driven by calling our own C entry
# points from Lisp, and the tiers that want a bus skip themselves by name.
test:
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :libusb/tests)" --eval "(sb-ext:exit)"

# The hardware suite cannot run here -- this machine has no CC2531 and is not the target
# -- but it must keep COMPILING. A hardware test that has quietly stopped building is
# worse than no hardware test, because you find out on the Pi, at the end of a deploy,
# with the dongle in your hand.
check: test
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:load-system :libusb/hw-tests)" \
	  --eval "(format t \"~&libusb ~A loaded: ~D exported symbols~%\" \
	            (libusb:version-string) \
	            (let ((n 0)) (do-external-symbols (s :libusb) (declare (ignore s)) (incf n)) n))" \
	  --eval "(sb-ext:exit)"

# Not in the help text: only ever invoked by pi-test-root, because it fails by design on
# a machine with no CC2531 or no permission to open it.
hw-test:
	$(SBCL) $(SBCL_FLAGS) $(BOOT) \
	  --eval "(asdf:test-system :libusb/hw-tests)" --eval "(sb-ext:exit)"

# The other half of the struct-layout assertion. The Lisp suite pins the offsets against
# our own declarations; this compares those declarations with the installed libusb.h
# using a C compiler, which is the half that catches a header changing underneath us.
layout:
	SBCL="$(SBCL)" sh ci/check-layout.sh

# Copy both trees, then DROP THE REMOTE FASL CACHE.
#
# That second step is not tidiness. rsync -a preserves this machine's mtimes, and against
# the target's cached build times they can look older -- so ASDF sees no reason to
# recompile and silently keeps the previous build. The source on the target is right, the
# fasls are not, and the only clue is behaviour that matches code you have already
# changed.
#
# Both caches, and here that is not belt and braces: the privileged tier runs under sudo,
# so root has its own ~/.cache/common-lisp full of fasls built from an older tree, and
# `make pi-test' and `make pi-test-root' would then be testing two different programs.
deploy:
	rsync -a --delete --exclude .git --exclude ocicl --exclude vendor --exclude '*.fasl' ./ $(HOST):$(DEST)
	rsync -a --exclude .git ./ocicl/ $(HOST):$(DEST)ocicl/
	@# cffi-callback-closures is ours and is in no ocicl registry, so it cannot be
	@# restored on the Pi -- it has to be shipped. Its own ocicl/ is excluded: the Pi
	@# resolves cffi and cffi-libffi from OUR ocicl/, which is the whole point of
	@# putting it on the registry with :directory rather than :tree.
	rsync -a --delete --exclude .git --exclude ocicl $(CCC_DIR)/ $(HOST):$(CCC_DEST)
	ssh $(HOST) 'sudo -n find ~/.cache/common-lisp /root/.cache/common-lisp \
	               \( -path "*/libusb/src/*" -o -path "*/libusb/tests/*" \
	                  -o -path "*/cffi-callback-closures/src/*" \) \
	               -delete 2>/dev/null; exit 0'
	@# Verified, not assumed: a cache that silently survives is the whole failure this
	@# target exists to prevent.
	ssh $(HOST) 'test -z "$$(find ~/.cache/common-lisp /root/.cache/common-lisp \
	               \( -path "*/libusb/src/*" -o -path "*/cffi-callback-closures/src/*" \) \
	               -name "*.fasl" 2>/dev/null | head -1)"' \
	  && echo "==> deployed to $(HOST):$(DEST), stale fasls cleared" \
	  || (echo "deploy: remote fasl cache NOT cleared" >&2; exit 1)

# As user pi: enumeration, descriptors, hotplug ENUMERATE, the event pump and the whole
# synthetic tier all work. libusb_open returns LIBUSB_ERROR_ACCESS, so the hardware tier
# skips -- cleanly and by name, not by failing.
pi-test:
	ssh $(HOST) 'cd $(DEST) && $(REMOTE_MAKE) test CCC_DIR=$(CCC_DEST)'

# Under the Pi's passwordless sudo, so /dev/bus/usb is writable and the CC2531 tier runs.
# -E keeps HOME, hence the root cache that deploy also clears.
pi-test-root:
	ssh $(HOST) 'cd $(DEST) && sudo -n -E $(REMOTE_MAKE) test CCC_DIR=$(CCC_DEST) && sudo -n -E $(REMOTE_MAKE) hw-test CCC_DIR=$(CCC_DEST)'

clean:
	rm -rf $(HOME)/.cache/common-lisp/*/$(subst /,_,$(CURDIR))

help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'
