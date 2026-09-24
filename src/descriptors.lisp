;;; USB descriptors as Lisp values.
;;;
;;; Everything here is a deep copy, and that is not a performance choice made
;;; carelessly -- it is forced. libusb_get_active_config_descriptor hands back a
;;; tree of allocations (a config, an array of interfaces, an array of alt
;;; settings per interface, an array of endpoints per alt setting, plus `extra'
;;; blobs hanging off several of them) which must be returned to
;;; libusb_free_config_descriptor. Handing a caller a pointer into that tree
;;; would make the lifetime of every descriptor their problem, and the first
;;; mistake would be a read of freed memory rather than an error.
;;;
;;; So the rule for the whole ergonomic layer: it owns no foreign memory across a
;;; function boundary except the three handles -- context, device and device
;;; handle. There is no FREE-CONFIG-DESCRIPTOR in this API because after
;;; CONFIG-DESCRIPTOR returns there is nothing left to free.
;;;
;;; This file touches no context and no handle, only pointers handed to it. That
;;; is what makes the parser testable on a machine with no USB devices: a test
;;; can build a descriptor in foreign memory by hand and assert on what comes
;;; back.

(in-package #:libusb)

(defstruct (device-descriptor (:copier nil))
  "A USB device descriptor, as Lisp values. See USB 2.0 section 9.6.1."
  (usb-version 0 :type (unsigned-byte 16))    ; bcdUSB, raw; see BCD-VERSION-STRING
  device-class device-subclass device-protocol
  (max-packet-size-0 0)
  (vendor-id 0 :type (unsigned-byte 16))
  (product-id 0 :type (unsigned-byte 16))
  (device-version 0 :type (unsigned-byte 16)) ; bcdDevice
  (manufacturer-index 0)
  (product-index 0)
  (serial-number-index 0)
  (configuration-count 0))

(defstruct (endpoint-descriptor (:copier nil))
  "A USB endpoint descriptor. See USB 2.0 section 9.6.6."
  (address 0)
  (number 0)             ; address with the direction bit masked off
  (direction :out)       ; :IN or :OUT, from bit 7 of the address
  (transfer-type :control)
  sync-type              ; isochronous endpoints only
  usage-type             ; isochronous endpoints only
  (max-packet-size 0)
  (interval 0)
  (refresh 0)
  (synch-address 0)
  extra)                 ; class-specific descriptors, as an octet vector

(defstruct (interface-descriptor (:copier nil))
  "One alternate setting of a USB interface. See USB 2.0 section 9.6.5."
  (number 0)
  (alt-setting 0)
  interface-class interface-subclass interface-protocol
  (interface-index 0)
  (endpoints #() :type simple-vector)
  extra)

(defstruct (usb-interface (:copier nil))
  "A USB interface: one or more alternate settings.

Named USB-INTERFACE rather than INTERFACE because the latter reads as a type
name in Lisp and this is a two-slot record around an array."
  (alt-settings #() :type simple-vector))

(defstruct (config-descriptor (:copier nil))
  "A USB configuration descriptor and everything beneath it. See USB 2.0 9.6.3."
  (configuration-value 0)
  (configuration-index 0)
  (total-length 0)
  (attributes 0)
  (self-powered-p nil)
  (remote-wakeup-p nil)
  (max-power-ma 0)       ; already doubled from bMaxPower's 2 mA units
  (interfaces #() :type simple-vector)
  extra)

(defun bcd-version-string (bcd)
  "Format a bcdUSB / bcdDevice field, e.g. #x0210 as \"2.10\".

The field stays an integer in the struct and is formatted on demand, because a
device reporting #x0299 should not make the parser signal: these fields are BCD
by convention and arbitrary in practice."
  (format nil "~X.~2,'0X" (ash bcd -8) (logand bcd #xff)))

(defun %copy-extra (pointer length)
  "Copy LENGTH bytes of class-specific descriptor data out of POINTER.

These blobs are HID report descriptors, UVC and audio class descriptors and the
like: libusb does not parse them and neither do we, but dropping them would make
this library useless for exactly the devices that have them."
  (if (or (cffi:null-pointer-p pointer) (not (plusp length)))
      nil
      (let ((v (make-array length :element-type '(unsigned-byte 8))))
        (dotimes (i length v)
          (setf (aref v i) (cffi:mem-aref pointer :uint8 i))))))

(defun parse-device-descriptor (pointer)
  "Copy the struct libusb_device_descriptor at POINTER into Lisp."
  (cffi:with-foreign-slots ((bcd-usb b-device-class b-device-sub-class
                             b-device-protocol b-max-packet-size-0
                             id-vendor id-product bcd-device
                             i-manufacturer i-product i-serial-number
                             b-num-configurations)
                            pointer (:struct libusb-device-descriptor))
    (make-device-descriptor
     :usb-version bcd-usb
     ;; ENUM-KEYWORD, not FOREIGN-ENUM-KEYWORD: a class byte off a device is
     ;; whatever the device says it is, and an unrecognised one must arrive as
     ;; an integer rather than signal. See the note atop enums.lisp.
     :device-class (enum-keyword 'libusb-class-code b-device-class)
     :device-subclass b-device-sub-class
     :device-protocol b-device-protocol
     :max-packet-size-0 b-max-packet-size-0
     :vendor-id id-vendor
     :product-id id-product
     :device-version bcd-device
     :manufacturer-index i-manufacturer
     :product-index i-product
     :serial-number-index i-serial-number
     :configuration-count b-num-configurations)))

(defun parse-endpoint-descriptor (pointer)
  "Copy the struct libusb_endpoint_descriptor at POINTER into Lisp.

bmAttributes is decoded here rather than left as a byte: bits 0:1 are the
transfer type, and for an isochronous endpoint bits 2:3 are the synchronisation
type and 4:5 the usage type. Every caller would otherwise write that shift
themselves, and USB 2.0 table 9-13 is not the sort of thing one wants written
twice."
  (cffi:with-foreign-slots ((b-endpoint-address bm-attributes w-max-packet-size
                             b-interval b-refresh b-synch-address
                             extra extra-length)
                            pointer (:struct libusb-endpoint-descriptor))
    (let ((transfer-type (enum-keyword 'libusb-endpoint-transfer-type
                                       (ldb (byte 2 0) bm-attributes))))
      (make-endpoint-descriptor
       :address b-endpoint-address
       :number (ldb (byte 4 0) b-endpoint-address)
       :direction (if (logbitp 7 b-endpoint-address) :in :out)
       :transfer-type transfer-type
       :sync-type (when (eq transfer-type :isochronous)
                    (enum-keyword 'libusb-iso-sync-type (ldb (byte 2 2) bm-attributes)))
       :usage-type (when (eq transfer-type :isochronous)
                     (enum-keyword 'libusb-iso-usage-type (ldb (byte 2 4) bm-attributes)))
       :max-packet-size w-max-packet-size
       :interval b-interval
       :refresh b-refresh
       :synch-address b-synch-address
       :extra (%copy-extra extra extra-length)))))

(defun parse-interface-descriptor (pointer)
  "Copy one struct libusb_interface_descriptor, and its endpoints, into Lisp."
  (cffi:with-foreign-slots ((b-interface-number b-alternate-setting b-num-endpoints
                             b-interface-class b-interface-sub-class
                             b-interface-protocol i-interface
                             endpoint extra extra-length)
                            pointer (:struct libusb-interface-descriptor))
    (make-interface-descriptor
     :number b-interface-number
     :alt-setting b-alternate-setting
     :interface-class (enum-keyword 'libusb-class-code b-interface-class)
     :interface-subclass b-interface-sub-class
     :interface-protocol b-interface-protocol
     :interface-index i-interface
     :endpoints (let ((v (make-array b-num-endpoints)))
                  (dotimes (i b-num-endpoints v)
                    (setf (svref v i)
                          (parse-endpoint-descriptor
                           (cffi:mem-aptr endpoint
                                          '(:struct libusb-endpoint-descriptor) i)))))
     :extra (%copy-extra extra extra-length))))

(defun parse-config-descriptor (pointer)
  "Copy the whole struct libusb_config_descriptor tree at POINTER into Lisp.

Does not free POINTER: the caller owns it, because the caller is the only one who
knows whether libusb allocated it or a test built it."
  (cffi:with-foreign-slots ((w-total-length b-num-interfaces b-configuration-value
                             i-configuration bm-attributes max-power
                             interface-array extra extra-length)
                            pointer (:struct libusb-config-descriptor))
    (make-config-descriptor
     :configuration-value b-configuration-value
     :configuration-index i-configuration
     :total-length w-total-length
     :attributes bm-attributes
     ;; USB 2.0 table 9-10: bit 6 is self-powered, bit 5 remote wakeup.
     :self-powered-p (logbitp 6 bm-attributes)
     :remote-wakeup-p (logbitp 5 bm-attributes)
     ;; bMaxPower is in 2 mA units on USB 2.0. (On SuperSpeed it is 8 mA units,
     ;; which libusb does not tell us about, so this is the 2 mA reading and the
     ;; slot is named for what it is rather than pretending to be exact.)
     :max-power-ma (* 2 max-power)
     :interfaces
     (let ((v (make-array b-num-interfaces)))
       (dotimes (i b-num-interfaces v)
         (let ((iface (cffi:mem-aptr interface-array '(:struct libusb-interface) i)))
           (cffi:with-foreign-slots ((altsetting num-altsetting)
                                     iface (:struct libusb-interface))
             (setf (svref v i)
                   (make-usb-interface
                    :alt-settings
                    (let ((a (make-array num-altsetting)))
                      (dotimes (j num-altsetting a)
                        (setf (svref a j)
                              (parse-interface-descriptor
                               (cffi:mem-aptr
                                altsetting
                                '(:struct libusb-interface-descriptor) j)))))))))))
     :extra (%copy-extra extra extra-length))))

(defun find-endpoint (config address &key (alt-setting 0))
  "The ENDPOINT-DESCRIPTOR in CONFIG with endpoint ADDRESS, or NIL.

Searches ALT-SETTING of every interface. The everyday question -- \"what is the
packet size of endpoint 0x83?\" -- otherwise takes three nested loops at every
call site."
  (loop for interface across (config-descriptor-interfaces config)
        for settings = (usb-interface-alt-settings interface)
        when (< alt-setting (length settings))
          do (let ((found (find address (interface-descriptor-endpoints
                                         (svref settings alt-setting))
                                :key #'endpoint-descriptor-address)))
               (when found (return found)))))
