;;; Devices: enumeration, topology and descriptors.

(in-package #:libusb)

(defstruct (device (:constructor %make-device (pointer context epoch))
                   (:predicate devicep)
                   (:copier nil)
                   (:print-object print-device))
  (pointer (cffi:null-pointer))
  context
  (epoch 0 :type fixnum)
  (live t)
  ;; Fetched once, eagerly. A device descriptor cannot change for the life of
  ;; the device and reading it needs no open handle, which is what lets
  ;; FIND-DEVICES filter on vendor and product without opening anything -- on
  ;; Linux, the difference between working as an ordinary user and needing root.
  (descriptor nil))

(defun print-device (device stream)
  (print-unreadable-object (device stream :type t)
    (if (device-live device)
        (let ((d (device-descriptor device)))
          (format stream "~3,'0D:~3,'0D ~4,'0X:~4,'0X~@[ ~(~A~)~]"
                  (device-bus-number device) (device-address device)
                  (device-descriptor-vendor-id d) (device-descriptor-product-id d)
                  (let ((speed (device-speed device)))
                    (and (keywordp speed) (not (eq speed :unknown)) speed))))
        (format stream "unreffed"))))

(defun device-live-p (device)
  "True if DEVICE still holds a reference and its context is open."
  (and (devicep device)
       (device-live device)
       (= (device-epoch device) *image-epoch*)
       (context-live-p (device-context device))))

(defun check-device (device &optional operation)
  (unless (devicep device)
    (usage-error "~S is not a libusb device." device))
  (unless (and (device-live device) (context-live (device-context device)))
    (error 'libusb-invalid-object :object device :operation operation))
  (unless (= (device-epoch device) *image-epoch*)
    (error 'libusb-stale-object :object device :operation operation))
  device)

(defun %wrap-device (pointer context)
  "Wrap an already-referenced libusb_device POINTER, and register it with CONTEXT.

The caller must have taken the reference; this function does not, because the two
callers differ -- LIST-DEVICES refs what libusb is about to free, while a hotplug
callback refs a device libusb is only lending it."
  (let ((device (%make-device pointer context *image-epoch*)))
    (setf (device-descriptor device)
          (cffi:with-foreign-object (desc '(:struct libusb-device-descriptor))
            (check-result (%libusb-get-device-descriptor pointer desc)
                          '%libusb-get-device-descriptor)
            (parse-device-descriptor desc)))
    (bt:with-lock-held ((context-lock context))
      (push device (context-devices context)))
    device))

(defun unref-device (device)
  "Drop this library's reference to DEVICE. Idempotent.

Every device from LIST-DEVICES or FIND-DEVICES holds a reference and needs one of
these, or WITH-DEVICE-LIST, or the context to close. Nothing here uses a GC
finalizer: a finalizer calling libusb_unref_device can run after libusb_exit,
which is a use-after-free with no recovery, so the reference is the context's to
reclaim and not the collector's."
  (when (and (devicep device) (device-live device))
    (let ((context (device-context device)))
      (when (context-live context)
        (bt:with-lock-held ((context-lock context))
          (setf (context-devices context) (remove device (context-devices context))))
        (unless (cffi:null-pointer-p (device-pointer device))
          (%libusb-unref-device (device-pointer device)))))
    (setf (device-live device) nil
          (device-pointer device) (cffi:null-pointer)))
  (values))

(defun list-devices (&key (context (default-context)) filter)
  "Every USB device CONTEXT can see, as a list of DEVICE objects.

FILTER, if given, is called with each device and only those it accepts are kept;
the rest are unreffed immediately, so filtering here is cheaper than filtering
afterwards.

Each returned device holds a reference and must be released with UNREF-DEVICE, or
by WITH-DEVICE-LIST, or by closing CONTEXT. libusb's own array is referenced and
freed before this function returns, so there is no window in which a caller holds
a pointer into libusb's memory and no FREE-DEVICE-LIST in this API for anyone to
forget.

Needs no permissions on Linux: enumeration and device descriptors come from
sysfs, and only opening a device requires write access to /dev/bus/usb."
  (check-context context 'list-devices)
  (cffi:with-foreign-object (list-ptr :pointer)
    (let ((n (check-result (%libusb-get-device-list (context-pointer context) list-ptr)
                           '%libusb-get-device-list))
          (array nil)
          (devices '()))
      (setf array (cffi:mem-ref list-ptr :pointer))
      (unwind-protect
           (dotimes (i n)
             (let* ((p (cffi:mem-aref array :pointer i))
                    (device (%wrap-device (%libusb-ref-device p) context)))
               (if (or (null filter) (funcall filter device))
                   (push device devices)
                   (unref-device device))))
        ;; unref_devices = 1: drop libusb's own references. Ours are separate,
        ;; taken above.
        (%libusb-free-device-list array 1))
      (nreverse devices))))

(defmacro with-device-list ((var &rest args) &body body)
  "Bind VAR to (LIST-DEVICES . ARGS) for the extent of BODY and unref them after."
  `(let ((,var (list-devices ,@args)))
     (unwind-protect (progn ,@body)
       (mapc #'unref-device ,var))))

(defun find-devices (&key (context (default-context)) vendor-id product-id
                          device-class bus-number address)
  "Devices matching every keyword given, as a list. Unmatched devices are unreffed.

Matching is done on the eagerly-fetched device descriptor, so this opens nothing
and needs no permissions."
  (list-devices
   :context context
   :filter (lambda (device)
             (let ((d (device-descriptor device)))
               (and (or (null vendor-id)
                        (= vendor-id (device-descriptor-vendor-id d)))
                    (or (null product-id)
                        (= product-id (device-descriptor-product-id d)))
                    (or (null device-class)
                        (eql device-class (device-descriptor-device-class d)))
                    (or (null bus-number)
                        (= bus-number (device-bus-number device)))
                    (or (null address)
                        (= address (device-address device))))))))

(defun find-device (&rest args)
  "The first device matching ARGS, or NIL. The others are unreffed.

Convenient for the common case of one known dongle; ambiguity is silently
resolved in favour of whichever libusb listed first, so use FIND-DEVICES when two
of the same model may be plugged in."
  (let ((devices (apply #'find-devices args)))
    (when devices
      (mapc #'unref-device (rest devices))
      (first devices))))

;;; --- topology ----------------------------------------------------------

(defun device-bus-number (device)
  "The number of the bus DEVICE is on."
  (check-device device 'device-bus-number)
  (%libusb-get-bus-number (device-pointer device)))

(defun device-address (device)
  "DEVICE's address on its bus. Reassigned when a device is re-plugged."
  (check-device device 'device-address)
  (%libusb-get-device-address (device-pointer device)))

(defun device-port-number (device)
  "The number of the port on its parent hub that DEVICE is plugged into, or 0."
  (check-device device 'device-port-number)
  (%libusb-get-port-number (device-pointer device)))

(defun device-port-numbers (device)
  "The chain of port numbers from the root hub down to DEVICE, as a list.

The USB specification caps hub depth at 7, so a buffer of 8 is always enough; the
LIBUSB_ERROR_OVERFLOW branch exists anyway because a wrong buffer size here is a
truncated topology rather than an error, and silently reporting the wrong path is
worse than asking twice."
  (check-device device 'device-port-numbers)
  (loop with size = 8
        repeat 4
        do (cffi:with-foreign-object (buffer :uint8 size)
             (let ((n (%libusb-get-port-numbers (device-pointer device) buffer size)))
               (cond ((and (minusp n) (= n -8))   ; LIBUSB_ERROR_OVERFLOW
                      (setf size (* 2 size)))
                     (t (check-result n '%libusb-get-port-numbers)
                        (return (loop for i below n
                                      collect (cffi:mem-aref buffer :uint8 i)))))))))

(defun device-parent (device)
  "The hub DEVICE is plugged into, as a DEVICE, or NIL for a root hub.

Only valid while the device list that produced DEVICE is still alive -- that is
libusb's rule, not this library's: the parent is not referenced, and libusb may
free it when the list it came from is freed. Inside WITH-DEVICE-LIST it is safe;
squirrelled away for later it is not."
  (check-device device 'device-parent)
  (let ((parent (%libusb-get-parent (device-pointer device))))
    (unless (cffi:null-pointer-p parent)
      ;; Referenced so that the wrapper is as safe as any other device object,
      ;; which costs one refcount and removes the sharpest edge above.
      (%wrap-device (%libusb-ref-device parent) (device-context device)))))

(defun device-speed (device)
  "DEVICE's negotiated speed: :LOW :FULL :HIGH :SUPER :SUPER-PLUS :SUPER-PLUS-X2,
:UNKNOWN, or an integer if this libusb reports a speed newer than this library."
  (check-device device 'device-speed)
  (enum-keyword 'libusb-speed (%libusb-get-device-speed (device-pointer device))))

(defun device-vendor-id (device)
  "DEVICE's idVendor."
  (device-descriptor-vendor-id (device-descriptor device)))

(defun device-product-id (device)
  "DEVICE's idProduct."
  (device-descriptor-product-id (device-descriptor device)))

(defun device-max-packet-size (device endpoint)
  "wMaxPacketSize of ENDPOINT on DEVICE, from the active configuration."
  (check-device device 'device-max-packet-size)
  (check-result (%libusb-get-max-packet-size (device-pointer device) endpoint)
                '%libusb-get-max-packet-size))

(defun device-max-iso-packet-size (device endpoint)
  "The maximum an isochronous ENDPOINT can carry per microframe, bursts included."
  (check-device device 'device-max-iso-packet-size)
  (check-result (%libusb-get-max-iso-packet-size (device-pointer device) endpoint)
                '%libusb-get-max-iso-packet-size))

(defun device-max-alt-packet-size (device interface alt-setting endpoint)
  "Like DEVICE-MAX-ISO-PACKET-SIZE, but for an endpoint in a given alt setting."
  (check-device device 'device-max-alt-packet-size)
  (check-result (%libusb-get-max-alt-packet-size (device-pointer device)
                                                 interface alt-setting endpoint)
                '%libusb-get-max-alt-packet-size))

;;; --- configuration descriptors -----------------------------------------

(defun active-config-descriptor (device)
  "DEVICE's active configuration, as a CONFIG-DESCRIPTOR, or NIL.

NIL rather than an error when the device is unconfigured: that is a state a
device can legitimately be in -- freshly plugged, or its driver not yet bound --
and not something a caller should have to handle."
  (check-device device 'active-config-descriptor)
  (cffi:with-foreign-object (holder :pointer)
    (let ((rc (%libusb-get-active-config-descriptor (device-pointer device) holder)))
      (cond ((= rc -5) nil)             ; LIBUSB_ERROR_NOT_FOUND: unconfigured
            (t (check-result rc '%libusb-get-active-config-descriptor)
               (let ((p (cffi:mem-ref holder :pointer)))
                 (unwind-protect (parse-config-descriptor p)
                   (%libusb-free-config-descriptor p))))))))

(defun config-descriptor-of (device &key index value)
  "One of DEVICE's configurations, by INDEX (0-based) or by bConfigurationValue.

Reads from the device rather than from a cache, so it needs the device but not an
open handle."
  (check-device device 'config-descriptor-of)
  (when (and index value)
    (usage-error "CONFIG-DESCRIPTOR-OF takes :INDEX or :VALUE, not both."))
  (cffi:with-foreign-object (holder :pointer)
    (let ((rc (if value
                  (%libusb-get-config-descriptor-by-value
                   (device-pointer device) value holder)
                  (%libusb-get-config-descriptor
                   (device-pointer device) (or index 0) holder))))
      (check-result rc (if value
                           '%libusb-get-config-descriptor-by-value
                           '%libusb-get-config-descriptor))
      (let ((p (cffi:mem-ref holder :pointer)))
        (unwind-protect (parse-config-descriptor p)
          (%libusb-free-config-descriptor p))))))
