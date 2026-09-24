(in-package #:libusb/tests)
(in-suite libusb-hygiene)

;;; FiveAM has no teardown hook, so leaks are caught by assertion instead. This suite
;;; is last in LIBUSB-ALL's file order and therefore last to run, and it asks the
;;; library what it still holds.
;;;
;;; A left-behind claimed interface is worse than a failing test: it makes the NEXT run
;;; fail with LIBUSB_ERROR_BUSY and sends whoever is debugging it looking in entirely
;;; the wrong place. Same for a minted closure, which leaks an executable page, and for
;;; a context, which keeps every device it enumerated referenced.

(test the-suite-leaves-no-context-behind
  "Every test above either used WITH-CONTEXT or closed what it opened."
  (is (zerop (libusb:live-context-count))
      "~D context(s) still open" (libusb:live-context-count)))

(test the-suite-leaves-no-transfer-registered
  "A registered transfer means a libusb_transfer, a foreign buffer and a completion
cell that were never freed -- and, if it is still in flight, a callback that may yet
fire into a record nobody is expecting."
  (is (zerop (libusb:live-transfer-count))
      "~D transfer(s) still registered" (libusb:live-transfer-count)))

(test the-suite-leaves-no-hotplug-registration-or-log-sink
  "Both hold a minted closure, and both hold a pointer libusb may still call."
  (is (zerop (libusb:live-hotplug-registration-count)))
  (is (zerop (libusb:live-log-sink-count))))

(test the-suite-frees-every-libffi-closure-it-minted
  "Reaches into cffi-callback-closures' own registry on purpose: it is the only way to
see a trampoline that nobody freed. cffi-callback-closures installs no finalizers, so
an unfreed closure leaks an mmap'd executable page for the life of the image -- and
freeing one too early is worse, because then libusb holds a pointer into memory that is
no longer mapped."
  (is (= *closures-at-start* (libusb:live-closure-count))
      "~D libffi closure(s) minted and never freed"
      (- (libusb:live-closure-count) *closures-at-start*)))

(test shutdown-all-is-idempotent-and-reports-nothing-left-to-do
  "The net under the net, which RUN-TESTS calls at the end of every run and fails the
run on. Here it should have nothing to sweep up, which is the whole claim of this
suite."
  (is (zerop (libusb:shutdown-all))
      "SHUTDOWN-ALL had to close something, so a test above did not clean up")
  (is (zerop (libusb:shutdown-all)) "and it must be idempotent"))
