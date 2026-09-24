;;; Contexts: the object every other handle hangs off.
;;;
;;; There is no support here for libusb's implicit NULL default context, and
;;; that omission is deliberate. libusb_init(NULL) gives a process-global,
;;; reference-counted singleton, so two independent libraries in one image can
;;; each call libusb_exit(NULL) and whichever gets there second has pulled the
;;; context out from under the first. A context we created is ours.
;;;
;;; Liveness is tracked, and checked on every operation. The alternative --
;;; letting a closed handle's pointer be dereferenced -- is a segmentation
;;; fault, and the difference between that and LIBUSB-INVALID-OBJECT is the
;;; difference between an afternoon and a minute.

(in-package #:libusb)

(define-condition libusb-stale-object (libusb-invalid-object) ()
  (:default-initargs :reason :stale)
  (:documentation "An object from a previous image was used after a restore.

A saved core's contexts, handles and transfers refer to file descriptors,
malloc'd memory and mapped pages that belonged to the process that saved it.
Nothing can be recovered, so they are detectably dead instead: see the epoch
machinery in src/shutdown.lisp."))

(defvar *image-epoch* 0
  "Bumped on image restore. Every context, handle and transfer records the epoch
it was created in, and using one from an older epoch signals
LIBUSB-STALE-OBJECT rather than calling into an address that now belongs to
something else entirely.")

(defun image-epoch () *image-epoch*)

(defstruct (context (:constructor %make-context (pointer epoch))
                    (:predicate contextp)
                    (:copier nil)
                    (:print-object print-context))
  (pointer (cffi:null-pointer))
  (epoch 0 :type fixnum)
  (live t)
  (lock (bt:make-lock "libusb context"))
  ;; :MANUAL -- nobody is calling libusb_handle_events, so a thread that waits
  ;; for a transfer does the pumping itself. :THREAD -- PUMP is running and
  ;; waiters may simply block. See src/events.lisp.
  (event-mode :manual)
  (pump nil)
  ;; Filled in by libusb/closures. Named here because CLOSE-CONTEXT has to tear
  ;; them down in a particular order and that order lives in one function.
  (log-sink nil)
  (pollfd-notifiers nil)
  (hotplug-registrations '())
  ;; Everything we handed out and must reclaim, newest first.
  (transfers '())
  (handles '())
  (devices '()))

(defun print-context (context stream)
  (print-unreadable-object (context stream :type t :identity t)
    (format stream "~:[dead~;~A~]" (context-live context)
            (and (context-live context)
                 (format nil "~(~A~) mode, ~D handle~:P, ~D transfer~:P"
                         (context-event-mode context)
                         (length (context-handles context))
                         (length (context-transfers context)))))))

(defvar *contexts* '()
  "Every live context, for SHUTDOWN-ALL and the image dump hook.")
(defvar *contexts-lock* (bt:make-lock "libusb contexts"))

(defun live-context-count ()
  "How many contexts this image currently has open."
  (bt:with-lock-held (*contexts-lock*) (length *contexts*)))

(defvar *context* nil
  "The context used by calls that are not given one; bound by WITH-CONTEXT.

Never libusb's implicit NULL default context -- see the commentary at the head
of this file.")

(defun context-live-p (context)
  "True if CONTEXT is open and belongs to this image."
  (and (contextp context)
       (context-live context)
       (= (context-epoch context) *image-epoch*)))

(defun check-context (context &optional operation)
  (unless (contextp context)
    (usage-error "~S is not a libusb context." context))
  (unless (context-live context)
    (error 'libusb-invalid-object :object context :operation operation))
  (unless (= (context-epoch context) *image-epoch*)
    (error 'libusb-stale-object :object context :operation operation))
  context)

;;; --- creating and closing ----------------------------------------------

(defvar *log-callback-minter* nil
  "Set by libusb/closures to a function of one argument -- a Lisp log handler --
returning a C function pointer of libusb_log_cb shape.

A hook rather than a direct call because libusb_set_log_cb can only be used after a
context exists, so catching a context's *initialisation* messages means handing the
pointer to libusb_init_context -- and minting that pointer needs
cffi-callback-closures, which this system deliberately does not depend on.")

(defvar *log-callback-recorder* nil
  "Set by libusb/closures to a function of (CONTEXT HANDLER POINTER).

The other half of *LOG-CALLBACK-MINTER*, and not an optional nicety: a pointer minted
before the context existed has no owner until something records it, and an unrecorded
closure is an executable page that nothing will ever free. Called immediately after
libusb_init_context so that CLOSE-CONTEXT's teardown reclaims it like any other.")

(defun open-context (&key log-level log-callback no-device-discovery)
  "Create and return a libusb context.

LOG-LEVEL is a LIBUSB-LOG-LEVEL keyword. LOG-CALLBACK is a function of
(CONTEXT LEVEL MESSAGE) and requires libusb/closures to be loaded, because
libusb's log callback takes no user_data and so has to be a distinct C function
pointer per Lisp closure. NO-DEVICE-DISCOVERY skips enumeration entirely, which
is only useful with WRAP-SYS-DEVICE.

Options are passed through libusb_init_context rather than set afterwards, so
that a log callback sees the messages libusb emits while starting up -- which
are the ones worth having when a context refuses to open at all."
  (load-libraries)
  (let ((options '()))
    (when log-level (push (cons :log-level log-level) options))
    (when no-device-discovery (push (cons :no-device-discovery nil) options))
    (when log-callback
      (unless *log-callback-minter*
        (usage-error "OPEN-CONTEXT was given a :LOG-CALLBACK, but libusb/~
                      closures is not loaded -- (asdf:load-system :libusb/~
                      closures), which is what can mint the C function pointer ~
                      libusb_log_cb needs."))
      (push (cons :log-cb (funcall *log-callback-minter* log-callback)) options))
    (let ((n (length options)))
      (cffi:with-foreign-object (ctx-ptr :pointer)
        (cffi:with-foreign-object (opts '(:struct libusb-init-option) (max n 1))
          (loop for (option . value) in options
                for i from 0
                for slot = (cffi:mem-aptr opts '(:struct libusb-init-option) i)
                do (setf (cffi:foreign-slot-value slot '(:struct libusb-init-option)
                                                  'option)
                         option)
                   (let ((v (cffi:foreign-slot-pointer
                             slot '(:struct libusb-init-option) 'value)))
                     (cond ((cffi:pointerp value)
                            (setf (cffi:foreign-slot-value
                                   v '(:union libusb-init-option-value) 'log-cbval)
                                  value))
                           ((keywordp value)
                            (setf (cffi:foreign-slot-value
                                   v '(:union libusb-init-option-value) 'ival)
                                  (cffi:foreign-enum-value 'libusb-log-level value)))
                           (t
                            (setf (cffi:foreign-slot-value
                                   v '(:union libusb-init-option-value) 'ival)
                                  (or value 0))))))
          (check-result (%libusb-init-context ctx-ptr
                                              (if (zerop n) (cffi:null-pointer) opts)
                                              n)
                        '%libusb-init-context))
        (let ((context (%make-context (cffi:mem-ref ctx-ptr :pointer) *image-epoch*)))
          (bt:with-lock-held (*contexts-lock*) (push context *contexts*))
          ;; Hand ownership of the pointer minted above to the context, so that closing
          ;; it frees the closure. Without this the pointer is live C code that nothing
          ;; in the image knows about.
          (when (and log-callback *log-callback-recorder*)
            (funcall *log-callback-recorder* context log-callback
                     (cdr (assoc :log-cb options))))
          context)))))

(defun default-context ()
  "A context created on first use and remembered, for the REPL and for scripts.

Convenient and not free: it lives until CLOSE-CONTEXT or SHUTDOWN-ALL, so
library code should take a context argument rather than reach for this."
  (if (context-live-p *context*)
      *context*
      (setf *context* (open-context))))

(defmacro with-context ((var &rest options) &body body)
  "Bind VAR to a fresh context for the extent of BODY, and close it after.

Closing is not tidiness. libusb_exit releases every device the context
enumerated, closes the file descriptors it opened and stops its internal
threads; a context leaked in a long-running image keeps all of that. Devices,
handles and transfers created under VAR are torn down here too, in the one order
that is safe -- see CLOSE-CONTEXT."
  `(let ((,var (open-context ,@options)))
     (unwind-protect (let ((*context* ,var)) ,@body)
       (close-context ,var))))

;;; CLOSE-CONTEXT's body is filled in by the layers that know what has to be
;;; reclaimed: src/transfer.lisp and src/events.lisp add theirs, and
;;; libusb/closures adds hotplug and logging. The order is fixed here, in one
;;; place, because getting it wrong is a use-after-free rather than a leak:
;;; libusb_exit while another thread sits inside libusb_handle_events is a crash
;;; in poll() with no libusb frames on the stack.
(defvar *context-teardown-steps* '()
  "An alist of (ORDER . FUNCTION-OF-CONTEXT), run in ascending ORDER by
CLOSE-CONTEXT before libusb_exit. Registered with REGISTER-CONTEXT-TEARDOWN.

The orders in use, and why this sequence and no other:
   10  deregister hotplug callbacks -- stop new events arriving
   20  cancel in-flight transfers and drain their callbacks
   30  free transfers
   40  stop the event pump AND JOIN IT: libusb_exit must not race a thread
       inside libusb_handle_events
   50  close device handles, releasing interfaces and reattaching drivers
   60  detach the log callback (but do not free its closure yet)
   70  clear the pollfd notifiers
  then libusb_exit, and only then may any minted closure be freed: freeing one
  earlier leaves libusb holding a pointer into an unmapped page for the duration
  of exit.")

(defun register-context-teardown (order function)
  (setf *context-teardown-steps*
        (sort (cons (cons order function)
                    (remove order *context-teardown-steps* :key #'car))
              #'< :key #'car)))

(defvar *context-post-exit-steps* '()
  "Functions of a context run after libusb_exit -- where freeing minted C
callbacks belongs, and nowhere earlier.")

(defun register-context-post-exit (order function)
  (setf *context-post-exit-steps*
        (sort (cons (cons order function)
                    (remove order *context-post-exit-steps* :key #'car))
              #'< :key #'car)))

(defun close-context (context)
  "Close CONTEXT and everything created under it. Idempotent.

Each teardown step is wrapped so that one failure cannot abandon the rest: a
device unplugged mid-teardown makes a release fail, and that must not leave the
event pump running when libusb_exit is called."
  (when (and (contextp context) (context-live context))
    (dolist (step *context-teardown-steps*)
      (handler-case (funcall (cdr step) context)
        (serious-condition (e)
          (format *error-output* "~&libusb: error while closing ~S: ~A~%"
                  context e))))
    (setf (context-live context) nil)
    (unless (cffi:null-pointer-p (context-pointer context))
      (%libusb-exit (context-pointer context)))
    (setf (context-pointer context) (cffi:null-pointer))
    (dolist (step *context-post-exit-steps*)
      (ignore-errors (funcall (cdr step) context)))
    (bt:with-lock-held (*contexts-lock*)
      (setf *contexts* (remove context *contexts*)))
    (when (eq context *context*) (setf *context* nil)))
  (values))

;;; Devices are reclaimed here rather than by a finalizer. An SB-EXT:FINALIZE
;;; calling libusb_unref_device can run after libusb_exit, which is a
;;; use-after-free with no recovery; a list the context owns cannot. The cost is
;;; that a device wrapper dropped without UNREF-DEVICE lives until its context
;;; closes -- bounded, silent, and safe. WITH-DEVICE-LIST is the way not to
;;; think about it.
(register-context-teardown
 55 (lambda (context)
      (dolist (device (context-devices context))
        (ignore-errors (unref-device device)))
      (setf (context-devices context) '())))

;;; --- library-wide queries ----------------------------------------------

(defun version ()
  "The loaded libusb's version, as (VALUES MAJOR MINOR MICRO NANO RC DESCRIBE)."
  (library-version))

(defun version-string ()
  "The loaded libusb's version as a string."
  (library-version-string))

(defun has-capability-p (capability)
  "True if this libusb build has CAPABILITY, a LIBUSB-CAPABILITY keyword.

Ask before using hotplug: it is unimplemented on some backends, and
libusb_hotplug_register_callback failing is a worse way to find out."
  (load-libraries)
  (plusp (%libusb-has-capability
          (if (keywordp capability)
              (cffi:foreign-enum-value 'libusb-capability capability)
              capability))))

(defun error-name (code)
  "libusb's own name for error CODE, e.g. \"LIBUSB_ERROR_BUSY\"."
  (load-libraries)
  (%libusb-error-name code))

(defun strerror (code)
  "libusb's own description of error CODE, in whatever locale is set.

Use ERROR-CODE-MESSAGE instead when the text must not move under you:
libusb_setlocale can translate this one."
  (load-libraries)
  (%libusb-strerror code))

(defun setlocale (locale)
  "Set the language libusb's own messages are produced in, e.g. \"de\"."
  (load-libraries)
  (check-result (%libusb-setlocale locale) '%libusb-setlocale))

(defun set-log-level (context level)
  "Set CONTEXT's log verbosity to LEVEL, a LIBUSB-LOG-LEVEL keyword.

libusb emits nothing at all unless this is raised -- and a build compiled
without ENABLE_LOGGING emits nothing at any level, which is why a log-capture
test that comes back empty is a skip rather than a failure."
  (check-context context 'set-log-level)
  ;; libusb_set_debug, not libusb_set_option. The two are documented as equivalent for
  ;; the log level, and libusb_set_option is variadic -- which is broken on Apple
  ;; arm64 for the reason its docstring gives. Reaching for the deprecated entry point
  ;; here is the price of a call that works on both of this library's target machines.
  (%libusb-set-debug (context-pointer context)
                     (if (keywordp level)
                         (cffi:foreign-enum-value 'libusb-log-level level)
                         level))
  level)
