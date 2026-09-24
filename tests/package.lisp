;;; The test suites.
;;;
;;; Tiered by what each tier needs from the machine, not by what it tests:
;;;
;;;   LIBUSB-CALLBACKS    nothing at all. The dispatcher and the minted closures
;;;                       are invoked from Lisp, the way libusb would invoke them,
;;;                       so the registry, the demultiplexer, the error containment
;;;                       and the transfer state machine are covered on a machine
;;;                       with no USB devices. This is the tier that makes CI worth
;;;                       having.
;;;   LIBUSB-ENUMS,
;;;   LIBUSB-STRUCTS,
;;;   LIBUSB-DESCRIPTORS,
;;;   LIBUSB-CONDITIONS,
;;;   LIBUSB-SYMBOLS      nothing but a loadable libusb.
;;;   LIBUSB-EVENTS       a context, which is unprivileged, and no devices.
;;;   LIBUSB-ENUMERATION  a real bus. Skips itself where there is none.
;;;   LIBUSB-HYGIENE      runs last and asserts on what the others left behind.
;;;   LIBUSB-HARDWARE     the CC2531 dongle and permission to open it
;;;                       (libusb/hw-tests).
;;;
;;; FiveAM has no teardown hook, which shapes two things here: every resource is
;;; acquired by a macro with an UNWIND-PROTECT in it (see helpers.lisp), and the
;;; hygiene suite turns a leak into a failing assertion rather than a later mystery.

(defpackage #:libusb/tests
  (:use #:cl #:fiveam)
  (:shadowing-import-from #:fiveam #:test)
  (:export #:run-tests #:run-hw-tests
           #:libusb-all #:libusb-symbols #:libusb-enums #:libusb-structs
           #:libusb-descriptors #:libusb-conditions #:libusb-callbacks
           #:libusb-events #:libusb-enumeration #:libusb-hygiene
           #:libusb-hardware))

(in-package #:libusb/tests)

(def-suite libusb-all
  :description "Every libusb test. The suites below are separated by what they
need from the machine they run on.")

(def-suite libusb-symbols
  :description "Which of the bindings the installed libusb actually exports.
Reports rather than asserts a count: 1.0.28 and 1.0.30 do not export the same set,
and a binding that is merely absent from an older library is not a defect."
  :in libusb-all)

(def-suite libusb-enums
  :description "Enum and bitfield translation, including the two cases that bite:
a value the enum has never heard of, and the one-byte width of the transfer flags."
  :in libusb-all)

(def-suite libusb-structs
  :description "Foreign struct layout. These are hand-written rather than
grovelled, so the offsets are an assumption -- and this suite is what stops the
assumption rotting quietly. ci/check-layout.sh checks the same offsets against the
installed libusb.h, which is the half a Lisp test cannot do."
  :in libusb-all)

(def-suite libusb-descriptors
  :description "The descriptor parser, driven from descriptors built in foreign
memory by hand. No device required, which is the point of keeping the parser free
of contexts and handles."
  :in libusb-all)

(def-suite libusb-conditions
  :description "Error codes to conditions, and the sentinel-versus-signal policy."
  :in libusb-all)

(def-suite libusb-callbacks
  :description "The callback machinery, driven synthetically. Every test here calls
our own C entry points from Lisp -- the transfer dispatcher, a minted log closure, a
minted hotplug closure -- so nothing needs a device, a permission or a timing
window."
  :in libusb-all)

(def-suite libusb-events
  :description "handle_events, the pump thread and its shutdown, and the polling
primitives. Needs a context, which is unprivileged, and no devices."
  :in libusb-all)

(def-suite libusb-enumeration
  :description "Enumeration and hotplug against whatever is actually plugged in.
Skips itself on a machine with no USB devices, such as a CI runner."
  :in libusb-all)

(def-suite libusb-hygiene
  :description "Assertions about the suite itself: that it left no context,
transfer, registration or minted closure behind. A left-behind claimed interface is
worse than a failing test, because it makes the NEXT run fail with
LIBUSB_ERROR_BUSY and sends you hunting in the wrong place."
  :in libusb-all)

(def-suite libusb-hardware
  :description "Tests that open a real device and move bytes. Skip cleanly, by
name, when the dongle is absent or /dev/bus/usb is not writable."
  :in libusb-all)

(defvar *closures-at-start* 0)

(defun %run-suite (suite what)
  (let ((*closures-at-start* (libusb:live-closure-count))
        (status nil)
        (swept 0))
    (unwind-protect
         (let ((results (run suite)))
           (explain! results)
           (setf status (results-status results)))
      ;; A net under the net. Anything SHUTDOWN-ALL finds is something a test did
      ;; not clean up, and it fails the run rather than being quietly tidied away --
      ;; a leak swept up here is a leak that becomes somebody else's problem later.
      (setf swept (+ (libusb:live-context-count) (libusb:live-transfer-count)
                     (- (libusb:live-closure-count) *closures-at-start*)))
      (libusb:shutdown-all))
    (when (plusp swept)
      (format *error-output*
              "~&libusb/tests: ~D object~:P had to be swept up after the ~A run; ~
               a test is not cleaning up after itself.~%" swept what)
      (setf status nil))
    status))

(defun run-tests ()
  "Run every suite that needs no USB device. Returns true if all passed."
  (%run-suite 'libusb-all "libusb/tests"))

(defun run-hw-tests ()
  "Run the suites that need a real device. Returns true if all passed."
  (%run-suite 'libusb-hardware "libusb/hw-tests"))
