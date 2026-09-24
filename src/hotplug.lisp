;;; Hotplug callbacks.
;;;
;;; This is one of the two places in the library where a callback is a minted
;;; libffi closure rather than the single static cffi:defcallback that serves every
;;; transfer. libusb_hotplug_register_callback does take a void *user_data, so a
;;; registry-index scheme would work here too -- but registrations are few and
;;; long-lived, one mmap'd trampoline for the life of the process is nothing, and
;;; carrying the Lisp closure directly means there is no index to get wrong. The
;;; transfer path made the opposite trade for the opposite reason.
;;;
;;; The deterministic thing to know about this file: with LIBUSB_HOTPLUG_ENUMERATE,
;;; libusb invokes the callback synchronously, on the registering thread, once for
;;; every already-attached matching device, before the registration call returns.
;;; That makes the whole path -- a closure minted at runtime, libusb's C call into
;;; it, the enum translation, the device reference, the guard, the return value --
;;; exercisable with no privileges, nothing plugged or unplugged, and no waiting.

(in-package #:libusb)

(defstruct (hotplug-registration (:conc-name hp-) (:copier nil)
                                 (:predicate hotplug-registration-p)
                                 (:print-object print-hotplug-registration))
  context
  (handle 0)                            ; libusb_hotplug_callback_handle, an int
  pointer                               ; the minted C function pointer
  function                              ; user function of (device event registration)
  (events '(:device-arrived :device-left))
  (live nil)
  (epoch 0 :type fixnum))

(defun print-hotplug-registration (registration stream)
  (print-unreadable-object (registration stream :type t)
    (format stream "~D ~:[dead~;live~] ~(~A~)"
            (hp-handle registration) (hp-live registration)
            (hp-events registration))))

(defvar *hotplug-registrations* (make-hash-table :test 'eq)
  "REGISTRATION -> T, for every live registration.

Its only job is reachability. The minted closure pointer and the Lisp function
behind it must stay alive as long as libusb can call them, and
cffi-callback-closures installs no finalizers -- a collected closure is not a leak,
it is a C function pointer into memory that nobody owns any more.")

(defvar *hotplug-lock* (bt:make-lock "libusb hotplug"))

(defun live-hotplug-registration-count ()
  "How many hotplug registrations this image currently holds."
  (bt:with-lock-held (*hotplug-lock*) (hash-table-count *hotplug-registrations*)))

(defun hotplug-registration-live-p (registration)
  "True if REGISTRATION is still registered with libusb."
  (and (hotplug-registration-p registration)
       (hp-live registration)
       (= (hp-epoch registration) *image-epoch*)))

(defun %match (value)
  (if (or (null value) (eq value :any)) +hotplug-match-any+ value))

(defun register-hotplug-callback (context function
                                  &key (events '(:device-arrived :device-left))
                                       (enumerate t)
                                       (vendor-id :any) (product-id :any)
                                       (device-class :any))
  "Call FUNCTION with (DEVICE EVENT REGISTRATION) on matching hotplug events.

EVENT is :DEVICE-ARRIVED or :DEVICE-LEFT. FUNCTION returning :DEREGISTER ends the
registration; any other value continues it. Errors in FUNCTION are reported and
swallowed -- they cannot be allowed to unwind into libusb's event loop -- and a
failing callback specifically does not deregister itself, because a handler with a
bug should not also vanish.

DEVICE holds a reference of its own and is registered with CONTEXT exactly as one
from LIST-DEVICES is, so it stays valid after the callback returns; release it with
UNREF-DEVICE or let CLOSE-CONTEXT do it. For a :DEVICE-LEFT event only the cached
descriptor and the bus, address and port numbers are meaningful -- the device is
already gone.

With ENUMERATE (the default) libusb calls FUNCTION synchronously, before this
function returns, once per already-attached matching device. Note libusb's own
warning: with ENUMERATE a device may be reported twice -- once from here and once
from the event loop -- so a callback that counts must be idempotent.

Events are only delivered while somebody is calling libusb_handle_events, which for
the arrivals and departures that happen later means an event pump: see
WITH-EVENT-PUMP. The ENUMERATE pass needs none."
  (check-context context 'register-hotplug-callback)
  (unless (has-capability-p :has-hotplug)
    (error 'libusb-not-supported :code -12 :function '%libusb-hotplug-register-callback
                                 :context "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
  (let ((registration (make-hotplug-registration :context context :function function
                                                 :events events :epoch *image-epoch*)))
    (setf (hp-pointer registration)
          (cffi-callback-closures:make-foreign-callback
           (lambda (ctx device-pointer event user-data)
             (declare (ignore ctx user-data))  ; the identity is in this closure
             (with-callback-guard ("hotplug" 0)
               (%dispatch-hotplug registration device-pointer event)))
           :int '(:pointer :pointer libusb-hotplug-event :pointer)))
    (bt:with-lock-held (*hotplug-lock*)
      (setf (gethash registration *hotplug-registrations*) t))
    ;; Marked live BEFORE registering, because with LIBUSB_HOTPLUG_ENUMERATE the
    ;; callback runs during the call below -- so a callback that asks to be
    ;; deregistered sets HP-LIVE to NIL before this function returns, and setting it to
    ;; T afterwards would quietly resurrect a registration libusb has already dropped.
    (setf (hp-live registration) t)
    (cffi:with-foreign-object (handle :int)
      (let ((rc (%libusb-hotplug-register-callback
                 (context-pointer context)
                 (cffi:foreign-bitfield-value 'libusb-hotplug-events events)
                 (if enumerate +hotplug-enumerate+ +hotplug-no-flags+)
                 (%match vendor-id) (%match product-id) (%match device-class)
                 (hp-pointer registration) (cffi:null-pointer) handle)))
        (unless (zerop rc)
          ;; Registration failed, so libusb never took the pointer and freeing it
          ;; now is safe -- which it would not be a moment later.
          (setf (hp-live registration) nil)
          (%retire-hotplug-registration registration)
          (check-result rc '%libusb-hotplug-register-callback))
        (setf (hp-handle registration) (cffi:mem-ref handle :int))))
    (bt:with-lock-held ((context-lock context))
      (push registration (context-hotplug-registrations context)))
    registration))

(defun %dispatch-hotplug (registration device-pointer event)
  (let* ((context (hp-context registration))
         ;; Referenced before the user sees it. libusb lends the device for the
         ;; duration of the call only; without a reference of our own, a caller who
         ;; stashes it gets a pointer that becomes garbage at the next device-list
         ;; refresh -- and the failure would land somewhere else entirely.
         (device (%wrap-device (%libusb-ref-device device-pointer) context))
         (deregister nil))
    (setf deregister (eq :deregister
                         (funcall (hp-function registration) device event registration)))
    (cond (deregister
           ;; Returning 1 makes libusb deregister without telling us again, so the
           ;; Lisp side records it here. The closure must NOT be freed yet: we are
           ;; standing in it. Retirement is the owner's job, and
           ;; DEREGISTER-HOTPLUG-CALLBACK is idempotent for exactly this case.
           (setf (hp-live registration) nil)
           1)
          (t 0))))

(defun deregister-hotplug-callback (registration)
  "Deregister REGISTRATION and free its closure, in that order. Idempotent.

The order is the whole content of this function. Freeing the trampoline before
libusb has been told to stop calling it leaves libusb holding a pointer into an
unmapped page; libusb documents deregistering an already-deregistered handle as
safe, so doing it twice costs nothing."
  (when (hotplug-registration-p registration)
    (let ((context (hp-context registration)))
      (when (and context (context-live context)
                 (not (cffi:null-pointer-p (context-pointer context))))
        (%libusb-hotplug-deregister-callback (context-pointer context)
                                            (hp-handle registration))
        ;; Deregistration is synchronous, but an event already taken off the wire
        ;; may still be in the pump's hands. One nudge plus a short pause lets it
        ;; drain before the trampoline goes away: freeing it a microsecond early is
        ;; an unrecoverable jump into unmapped memory, and this is the cheapest
        ;; insurance available.
        (when (event-pump-running-p context)
          (%libusb-interrupt-event-handler (context-pointer context))
          (sleep 0.05))
        (bt:with-lock-held ((context-lock context))
          (setf (context-hotplug-registrations context)
                (remove registration (context-hotplug-registrations context)))))
      (setf (hp-live registration) nil)
      (%retire-hotplug-registration registration)))
  (values))

(defun %retire-hotplug-registration (registration)
  (bt:with-lock-held (*hotplug-lock*)
    (remhash registration *hotplug-registrations*))
  (let ((pointer (hp-pointer registration)))
    (when (and pointer
               (= (hp-epoch registration) *image-epoch*)
               (cffi-callback-closures:foreign-callback-live-p pointer))
      (ignore-errors (cffi-callback-closures:free-foreign-callback pointer))))
  (setf (hp-pointer registration) nil)
  (values))

;;; Step 10: first of all, so that no new events arrive during the rest of
;;; teardown. libusb_exit would deregister these itself, but silently and without
;;; freeing our closures, and the pointers must be freed after libusb_exit rather
;;; than before -- so both halves are done explicitly, in order.
(register-context-teardown
 10 (lambda (context)
      (dolist (registration (copy-list (context-hotplug-registrations context)))
        (ignore-errors (deregister-hotplug-callback registration)))
      (setf (context-hotplug-registrations context) '())))
