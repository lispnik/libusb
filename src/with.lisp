;;; Every remaining acquire/release pair, in one file, plus the asynchronous
;;; conveniences built on them.
;;;
;;; Last in the load order because it wraps things defined across all of the files
;;; above. Gathered together because the discipline matters more than the
;;; individual macros: everything in this library that acquires a foreign resource
;;; has a WITH- form here, so that a test or a script never has to remember a
;;; release. A leaked device handle takes a device away from the rest of the
;;; machine until the process exits, and a transfer freed while still in flight is
;;; a use-after-free -- neither is the sort of thing to leave to a caller's
;;; UNWIND-PROTECT.

(in-package #:libusb)

(defmacro with-device-handle ((var device &key auto-detach-kernel-driver) &body body)
  "Open DEVICE, bind VAR to the handle for BODY, and close it however BODY ends."
  `(let ((,var (open-device ,device
                            :auto-detach-kernel-driver ,auto-detach-kernel-driver)))
     (unwind-protect (progn ,@body)
       (close-device-handle ,var))))

(defmacro with-claimed-interface ((handle interface &key alt-setting) &body body)
  "Claim INTERFACE on HANDLE for the extent of BODY and release it after.

The release matters more than it looks. Until the interface is released, the kernel
driver that was detached to claim it cannot come back -- so a keyboard, a modem or
a mass-storage device stays dead to the rest of the machine. It runs inside
IGNORE-ERRORS because a device unplugged mid-BODY makes the release fail with
LIBUSB_ERROR_NO_DEVICE, and that must not mask whatever error is already on its way
out."
  `(progn
     (claim-interface ,handle ,interface)
     (unwind-protect
          (progn ,@(when alt-setting
                     `((set-interface-alt-setting ,handle ,interface ,alt-setting)))
                 ,@body)
       (ignore-errors (release-interface ,handle ,interface)))))

(defmacro with-detached-kernel-driver ((handle interface) &body body)
  "Detach INTERFACE's kernel driver for the extent of BODY, and reattach it after.

Reattaches only if there was something to detach, so this is safe on an interface
no driver wanted."
  (let ((detached (gensym "DETACHED")))
    `(let ((,detached (detach-kernel-driver ,handle ,interface)))
       (unwind-protect (progn ,@body)
         (when ,detached
           (ignore-errors (attach-kernel-driver ,handle ,interface)))))))

(defmacro with-open-device ((var &rest find-args) &body body)
  "Find one device matching FIND-ARGS, open it as VAR for BODY, and close it.

The script one-liner. Deliberately built from FIND-DEVICE and OPEN-DEVICE rather
than from libusb_open_device_with_vid_pid, which returns NULL with no reason: this
way \"not plugged in\" arrives as NIL and \"no write permission on
/dev/bus/usb/001/004\" arrives as LIBUSB-ACCESS-ERROR, and the two are not the same
problem."
  (let ((device (gensym "DEVICE")))
    `(let ((,device (find-device ,@find-args)))
       (unless ,device
         (usage-error "No USB device matching ~S is attached." ',find-args))
       (unwind-protect
            (with-device-handle (,var ,device) ,@body)
         (unref-device ,device)))))

(defmacro with-transfer ((var handle &rest args) &body body)
  "Bind VAR to a fresh transfer on HANDLE for BODY; cancel, drain and free after.

The drain is not optional and not tidiness: freeing a transfer libusb still owns
frees the buffer it may be writing into. So on any exit -- including a non-local
one -- an in-flight transfer is cancelled and its callback waited for before
anything is released."
  `(let ((,var (make-usb-transfer ,handle ,@args)))
     (unwind-protect (progn ,@body)
       (when (eq :submitted (transfer-state ,var))
         (ignore-errors (cancel-transfer ,var :drain t :timeout 2)))
       (ignore-errors (free-usb-transfer ,var)))))

;;; --- asynchronous transfers that read like synchronous ones ------------
;;;
;;; These are what the async core buys over libusb's own blocking functions: a
;;; Lisp-side DEADLINE, and an unwind that cleans up. libusb_bulk_transfer cannot
;;; be interrupted once entered -- not by a deadline, not by a signal, not by
;;; another thread -- so a device that stops answering takes the calling thread
;;; with it until its millisecond timeout expires. Here, C-c works.

(macrolet
    ((define-async-pair (in-name out-name type kind)
       `(progn
          (defun ,in-name (handle endpoint length
                           &key (timeout *default-timeout*) deadline)
            ,(format nil "Read up to LENGTH bytes from ~A ENDPOINT, asynchronously.~@
~@
Returns (VALUES OCTETS STATUS). TIMEOUT is libusb's own, in milliseconds;~@
DEADLINE is a Lisp-side one in seconds, and when it expires the transfer is~@
cancelled and drained before returning, so nothing is left in flight.~@
~@
On a context with no event pump the waiting thread does the event handling itself,~@
so this works in a single-threaded program as well as a threaded one." kind)
            (with-transfer (tr handle :type ,type :endpoint endpoint
                                      :length length :timeout timeout)
              (submit-transfer tr)
              (let ((status (wait-for-transfer tr :timeout deadline)))
                (when (null status)
                  (cancel-transfer tr :drain t)
                  (setf status (or (transfer-status tr) :timeout)))
                (values (transfer-data tr) status))))

          (defun ,out-name (handle endpoint data
                            &key (timeout *default-timeout*) deadline)
            ,(format nil "Write DATA to ~A ENDPOINT, asynchronously.~@
~@
Returns (VALUES COUNT STATUS). See ~A for the timeout and deadline story."
                     kind (symbol-name in-name))
            (with-transfer (tr handle :type ,type :endpoint endpoint
                                      :data data :timeout timeout)
              (submit-transfer tr)
              (let ((status (wait-for-transfer tr :timeout deadline)))
                (when (null status)
                  (cancel-transfer tr :drain t)
                  (setf status (or (transfer-status tr) :timeout)))
                (values (transfer-actual-length tr) status)))))))

  (define-async-pair bulk-in bulk-out :bulk "bulk")
  (define-async-pair interrupt-in interrupt-out :interrupt "interrupt"))
