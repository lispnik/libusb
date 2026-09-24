;;; One policy for every Lisp function that C can enter.
;;;
;;; Neither CFFI:DEFCALLBACK nor cffi-callback-closures contains an error. A
;;; condition signalled inside a callback propagates out through the native
;;; dispatcher into the C frame that called it: in a REPL that means the debugger
;;; entered while holding one of libusb's locks, and on a thread libusb created it
;;; means the process dies. There is no useful recovery available to the C caller
;;; either -- libusb's event loop has no notion of "the callback failed".
;;;
;;; So every callback body in this library goes through WITH-CALLBACK-GUARD, and
;;; that is not a style preference. The precedent is lispfs's DEFOP macro, which
;;; wraps every FUSE operation for exactly this reason.

(in-package #:libusb)

(defmacro without-float-traps (&body body)
  ;; A callback can arrive on a thread libusb created -- macOS's darwin backend
  ;; runs an event thread, and pollfd notifiers fire from wherever a device
  ;; happened to be added. A foreign thread's floating-point control word is not
  ;; SBCL's, so a float operation on one traps, and a SIGTRAP cannot be handled.
  ;; Merely formatting a float in a log handler is enough to do it. Masking costs
  ;; two instructions against a callback that is about to do I/O bookkeeping, so
  ;; it is applied uniformly rather than argued about case by case.
  #+sbcl `(sb-int:with-float-traps-masked
              (:invalid :overflow :divide-by-zero :inexact :underflow)
            ,@body)
  #-sbcl `(progn ,@body))

(defvar *callback-error-hook* nil
  "Called with (WHAT CONDITION) when a callback body escapes, before the default
report. Must not signal, and must not call into libusb.

Bound by the test suite to keep expected failures off the error stream, and by an
application that would rather log these somewhere it can see them.")

(defun report-callback-error (what condition)
  "Report a condition that escaped a callback body, without signalling.

Deliberately paranoid: this runs inside a C frame, possibly inside libusb's own
locks, possibly on a foreign thread, and -- when the log callback is what failed
-- possibly inside libusb's logging. So it must not signal, must not log through
libusb, and must not assume *ERROR-OUTPUT* is in a usable state."
  (ignore-errors
   (when *callback-error-hook*
     (funcall *callback-error-hook* what condition)))
  (ignore-errors
   (format *error-output* "~&libusb: unhandled error in ~A callback: ~A~%"
           what (princ-to-string condition))
   (finish-output *error-output*))
  nil)

(defmacro with-callback-guard ((what &optional on-error) &body body)
  "Run BODY as the body of a C callback; report and return ON-ERROR if it escapes.

WHAT is a short string naming the callback, for the report. ON-ERROR is what the
callback returns when the body failed -- NIL for the :VOID ones, and 0 for a
hotplug callback, because 1 there means \"deregister me\" and a handler that
merely has a bug should not also disappear."
  `(handler-case (without-float-traps ,@body)
     (serious-condition (e)
       (report-callback-error ,what e)
       ,on-error)))
