;;; Log callbacks: the one place a runtime-minted closure is not merely preferable
;;; but necessary.
;;;
;;;   void libusb_set_log_cb(libusb_context *ctx, libusb_log_cb cb, int mode);
;;;   typedef void (*libusb_log_cb)(libusb_context *ctx, enum libusb_log_level,
;;;                                 const char *str);
;;;
;;; There is no user_data anywhere in that. Every other callback libusb takes
;;; carries a cookie we can use as a registry index, which is how the transfer path
;;; gets away with a single static cffi:defcallback for the whole image. Here there
;;; is nowhere to put one, so a per-context Lisp handler must be a distinct C
;;; function pointer -- and minting one at runtime is exactly what
;;; cffi-callback-closures exists to do.
;;;
;;; (The ctx argument does arrive, so a static callback keyed on the context pointer
;;; would cover the common case of one handler per context. It would not cover a
;;; global handler and a context handler at once, and it would trade a closure for a
;;; second registry. Given that this library already depends on the closures for
;;; hotplug, the honest implementation is the direct one.)

(in-package #:libusb)

(defstruct (log-sink (:conc-name sink-) (:copier nil))
  context
  (mode :context)
  pointer
  function
  (epoch 0 :type fixnum))

(defvar *log-sinks* (make-hash-table :test 'eq)
  "SINK -> T, for reachability. See the note on *HOTPLUG-REGISTRATIONS*.")
(defvar *log-lock* (bt:make-lock "libusb logging"))

(defvar *in-log-callback* nil
  "True on a thread already inside a log callback.

Reentrancy here is not hypothetical. The callback runs inside libusb, possibly
holding libusb's own locks; a handler that calls into libusb -- or whose output
stream is itself implemented over a USB device, which this library makes entirely
possible -- re-enters and recurses until the stack is gone. The guard makes the
inner call a no-op instead of a crash.")

(defun live-log-sink-count ()
  "How many log callbacks this image currently has installed."
  (bt:with-lock-held (*log-lock*) (hash-table-count *log-sinks*)))

(defvar *log-messages* '()
  "Captured log messages, newest first, as (LEVEL . STRING).")
(defvar *log-message-limit* 1024)

(defun log-messages ()
  "The captured log messages, oldest first."
  (bt:with-lock-held (*log-lock*) (reverse *log-messages*)))

(defun drain-log-messages ()
  "The captured log messages, oldest first, and clear them."
  (bt:with-lock-held (*log-lock*)
    (let ((messages (reverse *log-messages*)))
      (setf *log-messages* '())
      messages)))

(defun collect-log-message (context level message)
  "The default log handler: push onto a bounded ring and nothing else.

Deliberately does not print. libusb logs from inside its own locks and from its own
threads, so a handler that formats to a stream that might block turns a debugging
aid into a deadlock. Install PRINT-LOG-MESSAGE instead if that is a trade you want
to make knowingly."
  (declare (ignore context))
  (bt:with-lock-held (*log-lock*)
    (push (cons level (string-right-trim '(#\Newline #\Return) message))
          *log-messages*)
    (when (> (length *log-messages*) *log-message-limit*)
      (setf *log-messages* (subseq *log-messages* 0 *log-message-limit*))))
  (values))

(defun print-log-message (context level message)
  "A log handler that writes to *ERROR-OUTPUT*. See COLLECT-LOG-MESSAGE's warning."
  (declare (ignore context))
  (format *error-output* "~&libusb[~(~A~)] ~A~%"
          level (string-right-trim '(#\Newline #\Return) message))
  (values))

(defun %mint-log-callback (function)
  "Mint a libusb_log_cb pointer that calls FUNCTION, with the guards it needs."
  (cffi-callback-closures:make-foreign-callback
   (lambda (ctx level message)
     (if *in-log-callback*
         nil
         (let ((*in-log-callback* t))
           (with-callback-guard ("log")
             (funcall function ctx level message)))))
   :void '(:pointer libusb-log-level :string)))

;;; Lets OPEN-CONTEXT pass LIBUSB_OPTION_LOG_CB to libusb_init_context, which is
;;; the only way to see the messages libusb produces while starting up -- and those
;;; are the ones worth having when a context refuses to open at all.
(setf *log-callback-minter* #'%mint-log-callback)

(defun %record-log-callback (context handler pointer)
  "Adopt a log closure minted before CONTEXT existed, so closing it frees the closure.

libusb_init_context installs a LIBUSB_OPTION_LOG_CB handler as that context's handler,
which is what libusb_set_log_cb(ctx, NULL, LIBUSB_LOG_CB_CONTEXT) clears -- so the sink
is recorded with :CONTEXT mode and CLEAR-LOG-CALLBACK detaches and frees it by the
ordinary path."
  (let ((sink (make-log-sink :context context :mode :context :function handler
                            :pointer pointer :epoch *image-epoch*)))
    (bt:with-lock-held (*log-lock*) (setf (gethash sink *log-sinks*) t))
    (setf (context-log-sink context) sink)))

(setf *log-callback-recorder* #'%record-log-callback)

(defun set-log-callback (context &key (function #'collect-log-message)
                                      (mode :context) (level :warning))
  "Route libusb's log messages to FUNCTION, called with (CONTEXT LEVEL MESSAGE).

FUNCTION defaults to COLLECT-LOG-MESSAGE, which captures into a bounded ring that
LOG-MESSAGES and DRAIN-LOG-MESSAGES read.

LEVEL is the verbosity to raise CONTEXT to; NIL leaves it alone. MODE is :CONTEXT
for messages attributed to CONTEXT, or :GLOBAL for everything including messages
with no context at all.

Three things to know before wondering why nothing arrives. libusb emits nothing until
the level is raised. A libusb compiled without ENABLE_DEBUG_LOGGING -- which is how
several distributions ship it -- emits nothing at any level. And most of what libusb
has to say is at :DEBUG: at :INFO an ordinary enumeration produces nothing at all.

Also worth knowing: libusb writes its own copy of every message to file descriptor 2
in addition to calling this handler, and that copy is not something Lisp can redirect.
Installing a handler captures the messages; it does not silence them.

A handler installed here cannot see the messages libusb produces while a context is
being created. Pass :LOG-CALLBACK to OPEN-CONTEXT for those -- measurably worth it:
against libusb 1.0.30 an enumeration at :DEBUG yields around a dozen messages this
way and several hundred when the handler was in place before libusb_init_context.

Replaces any handler already installed on CONTEXT."
  (check-context context 'set-log-callback)
  (clear-log-callback context)
  ;; The level first, before anything is minted: if raising it failed after the closure
  ;; existed, the unwind would leave an executable page nobody owns.
  (when level (set-log-level context level))
  (let ((sink (make-log-sink :context context :mode mode :function function
                            :epoch *image-epoch*)))
    (setf (sink-pointer sink) (%mint-log-callback function))
    (bt:with-lock-held (*log-lock*) (setf (gethash sink *log-sinks*) t))
    (setf (context-log-sink context) sink)
    (%libusb-set-log-cb (if (eq mode :global)
                            (cffi:null-pointer)
                            (context-pointer context))
                        (sink-pointer sink)
                        (cffi:foreign-bitfield-value 'libusb-log-cb-mode (list mode)))
    sink))

(defun clear-log-callback (context)
  "Detach CONTEXT's log handler and free its closure, in that order. Idempotent.

Never the other way round. libusb calls the log callback from its own threads --
macOS's darwin backend logs from its event thread -- so between a free and the
detach there is a window in which a log line jumps into an unmapped page."
  (let ((sink (and (contextp context) (context-log-sink context))))
    (when sink
      (when (and (context-live context)
                 (not (cffi:null-pointer-p (context-pointer context))))
        (%libusb-set-log-cb (if (eq (sink-mode sink) :global)
                                (cffi:null-pointer)
                                (context-pointer context))
                            (cffi:null-pointer)
                            (cffi:foreign-bitfield-value 'libusb-log-cb-mode
                                                         (list (sink-mode sink)))))
      (setf (context-log-sink context) nil)
      (bt:with-lock-held (*log-lock*) (remhash sink *log-sinks*))
      (let ((pointer (sink-pointer sink)))
        (when (and pointer
                   (= (sink-epoch sink) *image-epoch*)
                   (cffi-callback-closures:foreign-callback-live-p pointer))
          (ignore-errors (cffi-callback-closures:free-foreign-callback pointer))))
      (setf (sink-pointer sink) nil)))
  (values))

;;; Step 60: after handles are closed -- a handle being closed can itself log --
;;; and before libusb_exit.
(register-context-teardown 60 (lambda (context) (clear-log-callback context)))

;;; --- pollfd notifiers --------------------------------------------------
;;;
;;; libusb_set_pollfd_notifiers does take a user_data, so these could share a
;;; static dispatcher. They are closures for the same reason hotplug's is: there are
;;; at most two per context, they live as long as it does, and a closure is the
;;; shorter road.

(defstruct (pollfd-notifiers (:conc-name pn-) (:copier nil))
  added-pointer removed-pointer (epoch 0 :type fixnum))

(defun %install-pollfd-notifiers (context added removed)
  (%retire-pollfd-notifiers context)
  (if (or added removed)
      (let ((notifiers (make-pollfd-notifiers :epoch *image-epoch*)))
        (when added
          (setf (pn-added-pointer notifiers)
                (cffi-callback-closures:make-foreign-callback
                 (lambda (fd events user-data)
                   (declare (ignore user-data))
                   (with-callback-guard ("pollfd added")
                     (funcall added fd
                              (append (when (logtest events 1) '(:pollin))
                                      (when (logtest events 4) '(:pollout))))))
                 :void '(:int :short :pointer))))
        (when removed
          (setf (pn-removed-pointer notifiers)
                (cffi-callback-closures:make-foreign-callback
                 (lambda (fd user-data)
                   (declare (ignore user-data))
                   (with-callback-guard ("pollfd removed")
                     (funcall removed fd)))
                 :void '(:int :pointer))))
        (setf (context-pollfd-notifiers context) notifiers)
        (%libusb-set-pollfd-notifiers
         (context-pointer context)
         (or (pn-added-pointer notifiers) (cffi:null-pointer))
         (or (pn-removed-pointer notifiers) (cffi:null-pointer))
         (cffi:null-pointer))
        notifiers)
      (values)))

(defun %retire-pollfd-notifiers (context)
  "Clear CONTEXT's pollfd notifiers and free their closures, detach first."
  (let ((notifiers (and (contextp context) (context-pollfd-notifiers context))))
    (when notifiers
      (when (and (context-live context)
                 (not (cffi:null-pointer-p (context-pointer context))))
        (%libusb-set-pollfd-notifiers (context-pointer context)
                                      (cffi:null-pointer) (cffi:null-pointer)
                                      (cffi:null-pointer)))
      (setf (context-pollfd-notifiers context) nil)
      (dolist (pointer (list (pn-added-pointer notifiers) (pn-removed-pointer notifiers)))
        (when (and pointer
                   (= (pn-epoch notifiers) *image-epoch*)
                   (cffi-callback-closures:foreign-callback-live-p pointer))
          (ignore-errors (cffi-callback-closures:free-foreign-callback pointer))))))
  (values))

(setf *pollfd-notifier-installer* #'%install-pollfd-notifiers)

;;; Step 70: last before libusb_exit.
(register-context-teardown 70 (lambda (context) (%retire-pollfd-notifiers context)))
