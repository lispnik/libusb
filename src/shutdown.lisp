;;; Whole-image teardown, and what a saved core can and cannot keep.
;;;
;;; Nothing survives SAVE-LISP-AND-DIE. Not the libusb_context (file descriptors,
;;; an internal pipe, backend threads), not a libusb_transfer (malloc'd in another
;;; process), not a buffer, not a libffi trampoline's address, not the handle on
;;; libusb-1.0 itself. cffi-callback-closures frees its own C resources in a dump
;;; hook and rebuilds its *named* callbacks on restore, but the closures this
;;; library mints are anonymous, and in any case ASDF does not order dump hooks
;;; between systems -- so this library cannot rely on somebody else's hook having
;;; run first.
;;;
;;; Two positions follow, and the second is the one worth stating out loud:
;;;
;;;   1. A dump hook tears everything down before the image is written, so a
;;;      forgetful caller gets a clean core rather than a mysterious one.
;;;   2. On restore the epoch is bumped, which makes every surviving Lisp object
;;;      detectably dead: using one signals LIBUSB-STALE-OBJECT instead of calling
;;;      into an address that now belongs to something else. There is no honest way
;;;      to replay an open device handle across a save -- the device may not even be
;;;      plugged in any more -- and a library that pretended otherwise would be
;;;      lying at the worst possible moment.
;;;
;;; The contract, therefore: SHUTDOWN-ALL before you dump; OPEN-CONTEXT again after
;;; you restore.

(in-package #:libusb)

(defun live-closure-count ()
  "How many libffi closures this image has minted and not yet freed.

Reaches into cffi-callback-closures' registry on purpose: it is the only way to see
a trampoline nobody freed, and an unfreed closure leaks an executable page for the
life of the image. The hygiene test in the suite asserts this comes back to where it
started."
  (hash-table-count (symbol-value (find-symbol "*REGISTRY*" :cffi-callback-closures))))

(defun shutdown-all (&key (reason :explicit))
  "Close every context this image has open, in the safe order. Idempotent.

Returns the number of contexts that had to be closed, which is the number a
well-behaved program would have closed itself. The test suite fails a run on a
non-zero answer, because a leak that gets quietly swept up here is a leak that will
be someone else's problem later."
  (declare (ignore reason))
  (let ((contexts (bt:with-lock-held (*contexts-lock*) (copy-list *contexts*))))
    (dolist (context contexts)
      (handler-case (close-context context)
        (serious-condition (e)
          (format *error-output* "~&libusb: error closing ~S during shutdown: ~A~%"
                  context e))))
    ;; Anything still in the tables after that belongs to a context that failed to
    ;; close. Dropping it is the right call for an image about to be written or
    ;; abandoned; keeping it would mean the next save carries dangling bookkeeping.
    (bt:with-lock-held (*contexts-lock*) (setf *contexts* '()))
    (bt:with-lock-held (*transfers-lock*) (clrhash *transfers*))
    (bt:with-lock-held (*hotplug-lock*) (clrhash *hotplug-registrations*))
    (bt:with-lock-held (*log-lock*) (clrhash *log-sinks*))
    (setf *context* nil)
    (length contexts)))

(defun %before-image-dump ()
  (let ((n (shutdown-all :reason :image-dump)))
    (when (plusp n)
      (format *error-output*
              "~&libusb: closed ~D context~:P while dumping the image; a program ~
               that dumps should call LIBUSB:SHUTDOWN-ALL itself.~%" n))))

(defun %after-image-restore ()
  ;; Everything from the previous process is dangling. Bump the epoch first, so that
  ;; anything which survived in a global signals rather than dereferences, then drop
  ;; the bookkeeping and reopen the shared library under whatever name this machine
  ;; has for it.
  (incf *image-epoch*)
  (bt:with-lock-held (*contexts-lock*) (setf *contexts* '()))
  (bt:with-lock-held (*transfers-lock*) (clrhash *transfers*))
  (bt:with-lock-held (*hotplug-lock*) (clrhash *hotplug-registrations*))
  (bt:with-lock-held (*log-lock*) (clrhash *log-sinks*))
  (setf *context* nil
        *libraries-loaded* nil)
  (clrhash %function-cache)
  ;; Not fatal if it fails: an image restored on a machine with no libusb should
  ;; report that at the first call, not at startup.
  (ignore-errors (load-libraries))
  (values))

(uiop:register-image-dump-hook '%before-image-dump)
(uiop:register-image-restore-hook '%after-image-restore nil)
