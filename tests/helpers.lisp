;;; Helpers, and the rules the suite enforces on itself.
;;;
;;; Two of these are not conveniences. *FORBIDDEN* and ASSERT-TOUCHABLE exist
;;; because this suite runs on a Raspberry Pi whose USB bus also carries three
;;; Bluetooth adapters with the kernel's btusb driver bound to them, and the hub
;;; they hang off. Opening one, claiming its interface or resetting the hub would
;;; break somebody's running system, so the restriction is enforced in code rather
;;; than trusted to whoever edits the file next.
;;;
;;; And every resource the suite acquires is acquired by a macro with an
;;; UNWIND-PROTECT, because FiveAM has no teardown: WITH-CC2531 and WITH-FAKE-HANDLE
;;; here, plus the library's own WITH- forms. A grep for OPEN-DEVICE or
;;; CLAIM-INTERFACE across tests/ should match only this file.

(in-package #:libusb/tests)

(defconstant +cc2531-vendor-id+ #x0451)
(defconstant +cc2531-product-id+ #x16ae
  "A TI CC2531 dongle. Chosen as the one device this suite may open because it has
no kernel driver bound, exactly one interface of a vendor-specific class, and
exactly one endpoint -- 0x83, bulk IN, 64 bytes -- which when the dongle is idle
answers a read with a timeout. A timeout is a real assertion about the whole async
path, and nothing about it disturbs anything else on the bus.")

(defparameter *forbidden*
  '((#x2357 . #x0604)                   ; TP-Link Bluetooth, btusb bound
    (#x37ad . #x0600)                   ; TP-Link Bluetooth, btusb bound
    (#x1d6b . #x0002)                   ; Linux Foundation root hub, USB 2
    (#x1d6b . #x0003)                   ; Linux Foundation root hub, USB 3
    (#x2109 . #x3431))                  ; the VIA hub the adapters hang off
  "Devices this suite must never open, claim, reset or transfer to.

The Bluetooth adapters are in use by the kernel and by whatever is talking to them;
the hub is what they are plugged into, so resetting it would drop all three. Read-
only enumeration of these is fine and is what most of the suite does.")

(defun touchable-p (vendor-id product-id)
  (not (member (cons vendor-id product-id) *forbidden* :test #'equal)))

(defun assert-touchable (vendor-id product-id)
  "Signal unless this suite is allowed to open VENDOR-ID:PRODUCT-ID."
  (unless (touchable-p vendor-id product-id)
    (error "libusb/tests refuses to open ~4,'0X:~4,'0X -- see *FORBIDDEN*."
           vendor-id product-id))
  t)

(defparameter *time-scale*
  (let ((value (uiop:getenv "LIBUSB_TEST_TIME_SCALE")))
    (or (and value (ignore-errors (max 1 (read-from-string value)))) 1))
  "Multiplier on every wall-clock wait in the suite.

LIBUSB_TEST_TIME_SCALE=4 on a loaded Raspberry Pi. Only durations pass through
SCALED; no test asserts an exact time, only a band.")

(defun scaled (seconds) (* seconds *time-scale*))

(defun shuffled (sequence)
  "A shuffled copy of SEQUENCE. Written out rather than pulled from alexandria, to
keep this system's dependencies to libusb and fiveam."
  (let ((v (copy-seq (coerce sequence 'vector))))
    (loop for i from (1- (length v)) downto 1
          for j = (random (1+ i))
          do (rotatef (aref v i) (aref v j)))
    v))

;;; --- a handle that is never dereferenced -------------------------------

(defmacro with-fake-handle ((handle &optional (context (gensym "CONTEXT"))) &body body)
  "Bind HANDLE to a device handle whose libusb_device_handle * is NULL.

For the synthetic callback tier, which fills and completes transfer structs without
ever submitting one -- so the handle pointer is written into the struct and never
dereferenced by anything. Using a real handle there would make the whole tier
require a device and a permission for no gain."
  `(libusb:with-context (,context)
     (let ((,handle (libusb::%make-device-handle (cffi:null-pointer) nil ,context
                                                (libusb:image-epoch))))
       ,@body)))

;;; --- the real dongle ---------------------------------------------------

(defvar *access* :unknown
  "Cached result of probing libusb_open on the CC2531: :GRANTED, :DENIED or :ABSENT.

Probed once per image. Opening a device thirty times in a suite is thirty chances to
leave a handle behind, and the answer cannot change while the suite runs.")

(defun probe-cc2531-access ()
  "Find the CC2531 and try to open it. Returns :GRANTED, :DENIED or :ABSENT."
  (if (not (eq *access* :unknown))
      *access*
      (setf *access*
            (handler-case
                (libusb:with-context (context)
                  (let ((device (libusb:find-device :context context
                                                    :vendor-id +cc2531-vendor-id+
                                                    :product-id +cc2531-product-id+)))
                    (if (null device)
                        :absent
                        (unwind-protect
                             (handler-case
                                 (let ((handle (libusb:open-device device)))
                                   (libusb:close-device-handle handle)
                                   :granted)
                               (libusb:libusb-access-error () :denied)
                               (libusb:libusb-error () :denied))
                          (libusb:unref-device device)))))
              (serious-condition () :absent)))))

(defmacro with-cc2531 ((handle &key (claim 0)) &body body)
  "Run BODY with HANDLE open on the CC2531 and interface CLAIM claimed, or SKIP.

Skips by name rather than failing, and says which of the two reasons applies --
\"there is no dongle here\" and \"there is one and you may not open it\" are
different problems with different fixes. CLAIM NIL opens without claiming."
  (let ((context (gensym "CONTEXT")) (device (gensym "DEVICE")))
    `(ecase (probe-cc2531-access)
       (:absent
        (skip "no CC2531 (~4,'0X:~4,'0X) on this machine; this tier needs the TI ~
               dongle the README describes"
              +cc2531-vendor-id+ +cc2531-product-id+))
       (:denied
        (skip "~4,'0X:~4,'0X is attached but libusb_open returns ~
               LIBUSB_ERROR_ACCESS (on Linux /dev/bus/usb is root:root 0664); run ~
               `make pi-test-root'"
              +cc2531-vendor-id+ +cc2531-product-id+))
       (:granted
        (assert-touchable +cc2531-vendor-id+ +cc2531-product-id+)
        (libusb:with-context (,context)
          (let ((,device (libusb:find-device :context ,context
                                             :vendor-id +cc2531-vendor-id+
                                             :product-id +cc2531-product-id+)))
            (if (null ,device)
                (skip "the CC2531 went away between the access probe and now")
                (libusb:with-device-handle (,handle ,device)
                  ,@(if claim
                        `((libusb:with-claimed-interface (,handle ,claim) ,@body))
                        body)))))))))

(defun bus-has-devices-p ()
  "True if this machine has any USB devices at all.

A CI runner has none, and the tiers that need a bus skip on this rather than fail:
\"nothing to enumerate\" is the correct result there, not a defect."
  (handler-case
      (libusb:with-context (context)
        (libusb:with-device-list (devices :context context)
          (plusp (length devices))))
    (serious-condition () nil)))

(defmacro silencing-callback-errors (&body body)
  "Run BODY with the callback error reporter muted.

Several tests deliberately make a callback fail, and the whole point of those tests
is that the error is reported rather than propagated -- so the report is expected
output, and printing it would make a passing run look broken."
  `(let ((libusb:*callback-error-hook* (constantly nil))
         (*error-output* (make-broadcast-stream)))
     ,@body))
