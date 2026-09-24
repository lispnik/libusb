;;; The condition hierarchy, and the one place where negative-means-error is
;;; decided.
;;;
;;; This file depends on nothing but the package, and in particular not on
;;; src/ffi.lisp. That is deliberate: its messages come from a static table
;;; rather than from libusb_strerror, so a failure is reportable before the
;;; shared library has been opened -- including the failure to open it. It also
;;; means the text cannot be changed out from under a caller by
;;; libusb_setlocale, which is the other reason not to use libusb_strerror
;;; here.

(in-package #:libusb)

(define-condition libusb-error (error) ()
  (:documentation "Base of every error this library signals.

Trap this to catch anything USB-related without enumerating the subclasses."))

(define-condition libusb-api-error (libusb-error)
  ((code     :initarg :code     :reader libusb-error-code)
   (function :initarg :function  :initform nil :reader libusb-error-function)
   (context  :initarg :context   :initform nil :reader libusb-error-context))
  (:report (lambda (c stream)
             (format stream "libusb: ~@[~A: ~]~A (~A)~@[: ~A~]"
                     (libusb-error-function c)
                     (error-code-message (libusb-error-code c))
                     (libusb-error-code c)
                     (libusb-error-context c))))
  (:documentation "A libusb entry point returned a negative error code.

CODE is the integer libusb returned, FUNCTION the binding that returned it, and
CONTEXT an optional string with whatever the caller knew that libusb did not --
which device, which endpoint. Branch on the condition class or on
LIBUSB-ERROR-CODE; never on the report text."))

(macrolet ((define-error-classes (&rest specs)
             `(progn
                ,@(loop for (name code keyword) in specs
                        collect `(define-condition ,name (libusb-api-error)
                                   ((code :initform ,code))
                                   (:documentation
                                    ,(format nil "libusb returned ~D (~A)."
                                             code keyword)))))))
  ;; One class per libusb_error value. Signalling a distinct class rather than
  ;; only a code is what lets a caller say (handler-case ... (libusb-busy ...))
  ;; instead of comparing integers -- and LIBUSB-ACCESS-ERROR in particular is
  ;; worth catching by name, because on Linux it almost always means the
  ;; /dev/bus/usb node is not writable rather than anything about the device.
  (define-error-classes
    (libusb-io-error        -1  :error-io)
    (libusb-invalid-param   -2  :error-invalid-param)
    (libusb-access-error    -3  :error-access)
    (libusb-no-device       -4  :error-no-device)
    (libusb-not-found       -5  :error-not-found)
    (libusb-busy            -6  :error-busy)
    (libusb-timeout         -7  :error-timeout)
    (libusb-overflow        -8  :error-overflow)
    (libusb-pipe-error      -9  :error-pipe)
    (libusb-interrupted     -10 :error-interrupted)
    (libusb-no-memory       -11 :error-no-mem)
    (libusb-not-supported   -12 :error-not-supported)
    (libusb-other-error     -99 :error-other)))

(define-condition libusb-unsupported-function (libusb-error)
  ((name  :initarg :name  :reader libusb-unsupported-function-name)
   (since :initarg :since :reader libusb-unsupported-function-since))
  (:report (lambda (c stream)
             (format stream "libusb: ~A is not present in the loaded libusb ~
                             (added in ~A); see FOREIGN-FUNCTION-AVAILABLE-P"
                     (libusb-unsupported-function-name c)
                     (libusb-unsupported-function-since c))))
  (:documentation "A version-guarded entry point is missing from this libusb.

Signalled instead of letting SBCL die in its undefined-alien handler, which
reports an address and not a name. Test with FOREIGN-FUNCTION-AVAILABLE-P to
branch rather than handle."))

(define-condition libusb-invalid-object (libusb-error)
  ((object    :initarg :object    :reader libusb-invalid-object-object)
   (operation :initarg :operation :initform nil
              :reader libusb-invalid-object-operation)
   (reason    :initarg :reason    :initform :closed
              :reader libusb-invalid-object-reason))
  (:report (lambda (c stream)
             (format stream "libusb: ~@[~S on ~]~S, which is ~(~A~)"
                     (libusb-invalid-object-operation c)
                     (libusb-invalid-object-object c)
                     (libusb-invalid-object-reason c))))
  (:documentation "A closed context, handle, transfer or device was used.

The alternative to signalling here is dereferencing a pointer libusb has
already freed, so this condition is the difference between a Lisp error and a
segmentation fault. REASON is :CLOSED for something we freed ourselves and
:STALE for something that belonged to a previous image."))

(define-condition libusb-usage-error (libusb-error)
  ((format-control   :initarg :format-control   :reader libusb-usage-format-control)
   (format-arguments :initarg :format-arguments :initform '()
                     :reader libusb-usage-format-arguments))
  (:report (lambda (c stream)
             (format stream "libusb: ~?"
                     (libusb-usage-format-control c)
                     (libusb-usage-format-arguments c))))
  (:documentation "This library was asked to do something contradictory.

Distinct from LIBUSB-API-ERROR because nothing was asked of libusb: the call
was rejected here, before it could turn into undefined behaviour in C."))

(defparameter +error-code-messages+
  '((0   . "success")
    (-1  . "input/output error")
    (-2  . "invalid parameter")
    (-3  . "access denied (insufficient permissions)")
    (-4  . "no such device (it may have been disconnected)")
    (-5  . "entity not found")
    (-6  . "resource busy")
    (-7  . "operation timed out")
    (-8  . "overflow")
    (-9  . "pipe error")
    (-10 . "system call interrupted (perhaps due to a signal)")
    (-11 . "insufficient memory")
    (-12 . "operation not supported or unimplemented on this platform")
    (-99 . "other error"))
  "libusb's enum libusb_error, for messages only.

A caller branching on a failure must use LIBUSB-ERROR-CODE, ERROR-CODE-KEYWORD
or the condition class -- not this wording, and not libusb_strerror's either,
whose text libusb_setlocale can translate.")

(defparameter +error-code-keywords+
  '((0 . :success) (-1 . :error-io) (-2 . :error-invalid-param)
    (-3 . :error-access) (-4 . :error-no-device) (-5 . :error-not-found)
    (-6 . :error-busy) (-7 . :error-timeout) (-8 . :error-overflow)
    (-9 . :error-pipe) (-10 . :error-interrupted) (-11 . :error-no-mem)
    (-12 . :error-not-supported) (-99 . :error-other)))

(defun error-code-message (code)
  "A human-readable description of libusb error CODE. Never signals."
  (or (cdr (assoc code +error-code-messages+))
      (format nil "unrecognised libusb error ~D" code)))

(defun error-code-keyword (code)
  "CODE as a keyword, or the integer itself if this libusb is newer than we are.

Returning the integer rather than signalling matters: a libusb 1.0.31 with a new
error code must not turn a device problem into a bug in this library."
  (if (minusp code)
      (or (cdr (assoc code +error-code-keywords+)) code)
      (if (zerop code) :success code)))

(defun %error-class-for-code (code)
  (case code
    (-1 'libusb-io-error) (-2 'libusb-invalid-param) (-3 'libusb-access-error)
    (-4 'libusb-no-device) (-5 'libusb-not-found) (-6 'libusb-busy)
    (-7 'libusb-timeout) (-8 'libusb-overflow) (-9 'libusb-pipe-error)
    (-10 'libusb-interrupted) (-11 'libusb-no-memory)
    (-12 'libusb-not-supported)
    ;; -99 and anything this build has never heard of. An unknown code is a
    ;; device error we cannot name, not an internal inconsistency.
    (t 'libusb-other-error)))

(defun check-result (result &optional function context)
  "Return RESULT unless it is a negative libusb error code, in which case signal.

The single place the negative-means-error convention is applied, so that the
hundred raw bindings do not each re-derive it. FUNCTION lands in the report:
\"libusb: %LIBUSB-CLAIM-INTERFACE: resource busy (-6)\" is a bug report,
\"error -6\" is a scavenger hunt."
  (if (and (integerp result) (minusp result))
      (error (%error-class-for-code result)
             :code result :function function :context context)
      result))

(defun usage-error (format-control &rest format-arguments)
  (error 'libusb-usage-error :format-control format-control
                             :format-arguments format-arguments))
