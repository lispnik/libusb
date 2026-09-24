;;; Event handling: the pump thread, and libusb's polling primitives.
;;;
;;; libusb has no thread of its own for this. Somebody must call
;;; libusb_handle_events or nothing ever completes: transfer timeouts are enforced
;;; inside it, hotplug callbacks are dispatched from it, and a transfer nobody is
;;; waiting on simply never finishes. There are three ways to arrange that, and
;;; this library offers two of them:
;;;
;;;   :THREAD  a Lisp thread per context, running handle_events in a loop. The
;;;            default, because a library whose hotplug callbacks silently never
;;;            fire until the caller builds a pump has no hotplug feature at all.
;;;            It also means completions arrive on a *Lisp* thread -- SBCL's
;;;            thread, SBCL's floating-point state -- which removes a whole class
;;;            of foreign-thread hazard from transfer callbacks.
;;;   :MANUAL  nobody pumps; a thread that waits for a transfer does the pumping
;;;            itself (see %PUMP-UNTIL-COMPLETE). Zero threads, completions on the
;;;            caller's thread, perfectly deterministic ordering -- which is why
;;;            most of the test suite runs this way. It costs hotplug delivery and
;;;            timeout enforcement whenever nobody is inside handle_events.
;;;
;;; The third way -- libusb_get_pollfds plus libusb_set_pollfd_notifiers, folded
;;; into a caller's own epoll or select loop -- is exposed here as primitives and
;;; deliberately not built into a loop. The reason is one trap:
;;; libusb_pollfds_handle_timeouts returns false on macOS, so an external loop
;;; there must also drive libusb_get_next_timeout and enforce transfer timeouts
;;; itself. Get that wrong and everything works until a device stops answering.

(in-package #:libusb)

(define-condition libusb-event-pump-stuck (libusb-error)
  ((context :initarg :context :reader libusb-event-pump-stuck-context)
   (timeout :initarg :timeout :reader libusb-event-pump-stuck-timeout))
  (:report (lambda (c stream)
             (format stream "libusb: the event pump for ~S did not stop within ~
                             ~A second~:P, so libusb_exit has NOT been called"
                     (libusb-event-pump-stuck-context c)
                     (libusb-event-pump-stuck-timeout c))))
  (:documentation "An event pump would not leave libusb_handle_events.

Signalled rather than pressing on, because pressing on means calling libusb_exit
while another thread is inside the context -- a use-after-free that surfaces as a
crash in poll() with no libusb frames on the stack. Refusing to continue leaves a
leaked context and a live thread, which is recoverable; the alternative is not."))

(defstruct (event-pump (:conc-name pump-) (:copier nil) (:print-object print-pump))
  context
  thread
  ;; A foreign int that doubles as the `completed' argument to
  ;; handle_events_completed: setting it makes libusb itself short-circuit the
  ;; poll rather than waiting for our timeout to expire.
  (stop (cffi:null-pointer))
  (exited nil)
  (tick 1.0)
  (error nil))

(defun print-pump (pump stream)
  (print-unreadable-object (pump stream :type t)
    (format stream "~:[stopped~;running~]~@[ (error ~A)~]"
            (and (pump-thread pump) (bt:thread-alive-p (pump-thread pump)))
            (pump-error pump))))

(defun event-pump-running-p (context)
  "True if CONTEXT has an event pump thread running."
  (let ((pump (context-pump context)))
    (and pump (pump-thread pump) (bt:thread-alive-p (pump-thread pump)))))

(defun start-event-pump (context &key (tick 1.0))
  "Start an event-handling thread for CONTEXT and switch it to :THREAD mode.

TICK bounds how long the thread sits in one libusb_handle_events call. The stop
flag and libusb_interrupt_event_handler already wake it, so this is belt and
braces -- but a bounded wait means a pump can never be stuck for the sixty seconds
libusb would otherwise poll for, on any libusb version and in any signal weather."
  (check-context context 'start-event-pump)
  (when (event-pump-running-p context)
    (return-from start-event-pump (context-pump context)))
  (let* ((stop (cffi:foreign-alloc :int :initial-element 0))
         (pump (make-event-pump :context context :stop stop :tick tick
                                :exited (bt:make-semaphore :count 0))))
    (setf (context-pump context) pump
          (context-event-mode context) :thread)
    (setf (pump-thread pump)
          (bt:make-thread
           (lambda ()
             (unwind-protect
                  (with-callback-guard ("event pump")
                    (%event-loop pump))
               (bt:signal-semaphore (pump-exited pump))))
           :name (format nil "libusb event pump ~A" (context-pointer context))))
    pump))

(defun %event-loop (pump)
  (let ((ctx (context-pointer (pump-context pump)))
        (stop (pump-stop pump)))
    (cffi:with-foreign-object (tv '(:struct timeval))
      (loop until (plusp (cffi:mem-ref stop :int))
            do (%set-timeval tv (pump-tick pump))
               (let ((rc (%libusb-handle-events-timeout-completed ctx tv stop)))
                 (cond ((zerop rc))
                       ;; A signal arrived mid-poll. Ordinary; go round again.
                       ((= rc -10))     ; LIBUSB_ERROR_INTERRUPTED
                       (t (setf (pump-error pump) (error-code-keyword rc))
                          (return))))))))

(defun stop-event-pump (context &key (timeout 5))
  "Stop CONTEXT's event pump and do not return until its thread has left libusb.

The join is mandatory, and this function signals rather than giving up on it. This
is libusb's classic footgun: libusb_exit while another thread sits inside
libusb_handle_events tears the context out from under it. Returning normally here
is a promise that libusb_exit is now safe, so if the thread cannot be joined the
promise is refused -- see LIBUSB-EVENT-PUMP-STUCK.

Idempotent, and safe on a context that never had a pump."
  (let ((pump (context-pump context)))
    (when pump
      ;; Flag first, then interrupt. libusb_interrupt_event_handler wakes a thread
      ;; already inside handle_events and, if none is inside yet, leaves a flag
      ;; that makes the next call return at once -- so in this order there is no
      ;; window in which the pump can miss the request and settle in for a full
      ;; tick.
      (unless (cffi:null-pointer-p (pump-stop pump))
        (setf (cffi:mem-ref (pump-stop pump) :int) 1))
      (unless (cffi:null-pointer-p (context-pointer context))
        (%libusb-interrupt-event-handler (context-pointer context)))
      (cond ((or (null (pump-thread pump))
                 ;; MAX: bordeaux-threads rejects a zero timeout, and a caller passing
                 ;; 0 means "do not wait", which a millisecond is close enough to.
                 (bt:wait-on-semaphore (pump-exited pump)
                                       :timeout (max timeout 0.001)))
             (ignore-errors (bt:join-thread (pump-thread pump)))
             (unless (cffi:null-pointer-p (pump-stop pump))
               (cffi:foreign-free (pump-stop pump))
               (setf (pump-stop pump) (cffi:null-pointer)))
             (setf (context-pump context) nil
                   (context-event-mode context) :manual))
            (t (error 'libusb-event-pump-stuck :context context :timeout timeout)))))
  (values))

;;; Step 40: after transfers are cancelled, drained and freed -- the drain needs
;;; the pump to deliver those cancellations -- and before libusb_exit, which must
;;; not race a thread inside handle_events.
(register-context-teardown 40 (lambda (context) (stop-event-pump context)))

(defmacro with-event-pump ((context &key (tick 1.0)) &body body)
  "Run BODY with an event pump on CONTEXT, and stop it afterwards.

Leaves the context in :MANUAL mode on the way out, and the stop is not optional:
an abandoned pump thread makes the eventual libusb_exit a use-after-free."
  (let ((ctx (gensym "CONTEXT")))
    `(let ((,ctx ,context))
       (start-event-pump ,ctx :tick ,tick)
       (unwind-protect (progn ,@body)
         (stop-event-pump ,ctx)))))

;;; --- driving events by hand --------------------------------------------

(defun handle-events (context &key (timeout 0.1) completed)
  "Handle whatever events are pending on CONTEXT, for up to TIMEOUT seconds.

TIMEOUT NIL blocks until something happens, which on an idle context can be as
long as libusb's own sixty-second poll. COMPLETED is a foreign int pointer that
libusb checks before blocking and again on wake-up; it is how a waiter arranges to
return the moment its own transfer finishes.

Returns the libusb status keyword -- :SUCCESS, or :ERROR-INTERRUPTED if a signal
arrived, which is not a failure."
  (check-context context 'handle-events)
  (let* ((ctx (context-pointer context))
         (rc (cond ((and timeout completed)
                    (cffi:with-foreign-object (tv '(:struct timeval))
                      (%set-timeval tv timeout)
                      (%libusb-handle-events-timeout-completed ctx tv completed)))
                   (timeout
                    (cffi:with-foreign-object (tv '(:struct timeval))
                      (%set-timeval tv timeout)
                      (%libusb-handle-events-timeout ctx tv)))
                   (completed (%libusb-handle-events-completed ctx completed))
                   (t (%libusb-handle-events ctx)))))
    (if (or (zerop rc) (= rc -10))
        (error-code-keyword rc)
        (check-result rc '%libusb-handle-events))))

(defun interrupt-event-handler (context)
  "Wake whatever thread is inside libusb_handle_events on CONTEXT.

If none is, libusb remembers, and the next call returns immediately -- which is
what makes the flag-then-interrupt order in STOP-EVENT-PUMP race-free."
  (check-context context 'interrupt-event-handler)
  (%libusb-interrupt-event-handler (context-pointer context))
  (values))

(defun event-handler-active-p (context)
  "True if some thread is currently handling events on CONTEXT."
  (check-context context 'event-handler-active-p)
  (plusp (%libusb-event-handler-active (context-pointer context))))

(defun next-timeout (context)
  "Seconds until libusb next needs attention on CONTEXT, or NIL if never.

NIL means there is no pending timeout, so an external event loop may block
indefinitely on the pollfds. 0 means libusb needs handling right now."
  (check-context context 'next-timeout)
  (cffi:with-foreign-object (tv '(:struct timeval))
    (let ((rc (check-result (%libusb-get-next-timeout (context-pointer context) tv)
                            '%libusb-get-next-timeout)))
      (when (plusp rc)
        (+ (cffi:foreign-slot-value tv '(:struct timeval) 'tv-sec)
           (/ (cffi:foreign-slot-value tv '(:struct timeval) 'tv-usec) 1000000.0))))))

(defun pollfds (context)
  "CONTEXT's file descriptors, as a list of (FD . EVENTS) conses.

EVENTS is a list of :POLLIN and/or :POLLOUT. libusb's own array is freed before
this returns. Every context has at least one -- the internal pipe libusb_interrupt_
event_handler writes to -- so an empty list means something is wrong."
  (check-context context 'pollfds)
  (let ((array (%libusb-get-pollfds (context-pointer context))))
    (when (cffi:null-pointer-p array)
      (error 'libusb-not-supported :code -12 :function '%libusb-get-pollfds))
    (unwind-protect
         (loop for i from 0
               for entry = (cffi:mem-aref array :pointer i)
               until (cffi:null-pointer-p entry)
               collect (cffi:with-foreign-slots ((fd events) entry
                                                 (:struct libusb-pollfd))
                         ;; POLLIN is 1 and POLLOUT 4 on both Linux and Darwin.
                         ;; Decoded here rather than exposing the mask, because a
                         ;; caller is about to hand these to their own poll and
                         ;; the numbers are not the interesting part.
                         (cons fd (append (when (logtest events 1) '(:pollin))
                                          (when (logtest events 4) '(:pollout))))))
      (%libusb-free-pollfds array))))

(defun pollfds-handle-timeouts-p (context)
  "True if libusb's file descriptors alone are enough to drive timeouts.

True on Linux, where libusb uses timerfd. FALSE ON macOS -- and an external event
loop there must additionally call NEXT-TIMEOUT and wake itself, or transfer
timeouts will never be enforced. Worth asserting on rather than assuming."
  (check-context context 'pollfds-handle-timeouts-p)
  (plusp (%libusb-pollfds-handle-timeouts (context-pointer context))))

(defvar *pollfd-notifier-installer* nil
  "Set by libusb/closures to a function of (CONTEXT ADDED REMOVED).

A hook rather than a direct call, and a hook rather than a function this system
defines and that one redefines: libusb_set_pollfd_notifiers takes two C function
pointers, minting them needs cffi-callback-closures, and this system deliberately
does not depend on it. Redefining a function across systems would work and would
also warn on every load, which trains people to ignore warnings.")

(defun set-pollfd-notifiers (context &key added removed)
  "Install callbacks for file descriptors libusb starts and stops watching.

ADDED is called with (FD EVENTS) and REMOVED with (FD); pass neither to clear both.
Only useful when integrating libusb into an external event loop -- read
POLLFDS-HANDLE-TIMEOUTS-P first, because on macOS the descriptors alone will not
drive transfer timeouts.

Needs libusb/closures loaded: the notifiers are C function pointers minted at
runtime, one per Lisp closure."
  (check-context context 'set-pollfd-notifiers)
  (unless *pollfd-notifier-installer*
    (usage-error "SET-POLLFD-NOTIFIERS needs libusb/closures loaded: ~
                  (asdf:load-system :libusb/closures)."))
  (funcall *pollfd-notifier-installer* context added removed))
