;;; libusb's enumerations and loose constants.
;;;
;;; A note that applies to every enum in this file: none of them is used as the
;;; return type of a raw binding that reports something a *device* said. CFFI's
;;; FOREIGN-ENUM-KEYWORD signals on a value it was not told about, so declaring
;;; libusb_get_device_speed as returning LIBUSB-SPEED would turn a 2030 device
;;; reporting a speed we have never heard of into a Lisp error in the middle of
;;; enumeration. Those bindings return :INT and the ergonomic layer converts
;;; with ENUM-KEYWORD, which falls back to the integer. The enums are for
;;; arguments we supply, for slots libusb itself fills, and for legibility.

(in-package #:libusb)

(cffi:defcenum libusb-class-code
  (:per-interface #x00)
  (:audio #x01)
  (:comm #x02)
  (:hid #x03)
  (:physical #x05)
  ;; LIBUSB_CLASS_PTP and LIBUSB_CLASS_IMAGE are both 0x06. CFFI's value-to-
  ;; keyword map keeps the last definition of a duplicated value, so :ptp is
  ;; listed first and :image second deliberately: 0x06 decodes as :image, which
  ;; is what the USB specification calls the class, while :ptp remains an
  ;; accepted spelling on the way in.
  (:ptp #x06)
  (:image #x06)
  (:printer #x07)
  (:mass-storage #x08)
  (:hub #x09)
  (:data #x0a)
  (:smart-card #x0b)
  (:content-security #x0d)
  (:video #x0e)
  (:personal-healthcare #x0f)
  (:audio-video #x10)
  (:billboard #x11)
  (:type-c-bridge #x12)
  (:bulk-display-protocol #x13)
  (:mctp #x14)
  (:i3c #x3c)
  (:diagnostic-device #xdc)
  (:wireless #xe0)
  (:miscellaneous #xef)
  (:application #xfe)
  (:vendor-spec #xff))

(cffi:defcenum libusb-descriptor-type
  (:device #x01)
  (:config #x02)
  (:string #x03)
  (:interface #x04)
  (:endpoint #x05)
  (:interface-association #x0b)
  (:bos #x0f)
  (:device-capability #x10)
  (:hid #x21)
  (:report #x22)
  (:physical #x23)
  (:hub #x29)
  (:superspeed-hub #x2a)
  (:ss-endpoint-companion #x30))

(cffi:defcenum libusb-endpoint-direction
  (:out #x00)
  (:in #x80))

(cffi:defcenum libusb-endpoint-transfer-type
  (:control 0)
  (:isochronous 1)
  (:bulk 2)
  (:interrupt 3))

(cffi:defcenum libusb-standard-request
  (:get-status #x00)
  (:clear-feature #x01)
  (:set-feature #x03)
  (:set-address #x05)
  (:get-descriptor #x06)
  (:set-descriptor #x07)
  (:get-configuration #x08)
  (:set-configuration #x09)
  (:get-interface #x0a)
  (:set-interface #x0b)
  (:synch-frame #x0c)
  (:set-sel #x30)
  (:set-isoch-delay #x31))

;;; Already shifted into bits 5:6 of bmRequestType, exactly as the C enum is,
;;; so these values can be OR'd straight into a request type byte.
(cffi:defcenum libusb-request-type
  (:standard #x00)
  (:class #x20)
  (:vendor #x40)
  (:reserved #x60))

(cffi:defcenum libusb-request-recipient
  (:device #x00)
  (:interface #x01)
  (:endpoint #x02)
  (:other #x03))

(cffi:defcenum libusb-iso-sync-type
  (:none 0) (:async 1) (:adaptive 2) (:sync 3))

(cffi:defcenum libusb-iso-usage-type
  (:data 0) (:feedback 1) (:implicit 2))

(cffi:defbitfield libusb-supported-speed
  (:low 1) (:full 2) (:high 4) (:super 8))

(cffi:defbitfield libusb-usb-2-0-extension-attributes
  (:lpm-support 2))

(cffi:defbitfield libusb-ss-usb-device-capability-attributes
  (:ltm-support 2))

(cffi:defcenum libusb-bos-type
  (:wireless-usb-device-capability #x01)
  (:usb-2-0-extension #x02)
  (:ss-usb-device-capability #x03)
  (:container-id #x04)
  (:platform-descriptor #x05)
  (:superspeed-plus-capability #x0a))

(cffi:defcenum libusb-ssplus-sublink-type (:sym 0) (:asym 1))
(cffi:defcenum libusb-ssplus-sublink-direction (:rx 0) (:tx 1))
(cffi:defcenum libusb-ssplus-exponent (:bps 0) (:kbs 1) (:mbs 2) (:gbs 3))
(cffi:defcenum libusb-ssplus-link-protocol (:ss 0) (:ssplus 1))

(cffi:defcenum libusb-speed
  (:unknown 0) (:low 1) (:full 2) (:high 3)
  (:super 4) (:super-plus 5) (:super-plus-x2 6))

;;; Named -ENUM because LIBUSB-ERROR-CODE is the reader on LIBUSB-API-ERROR.
;;; Rarely used as a foreign type: error codes come back as :INT and go through
;;; ERROR-CODE-KEYWORD, for the reason at the top of this file.
(cffi:defcenum libusb-error-code-enum
  (:success 0) (:error-io -1) (:error-invalid-param -2) (:error-access -3)
  (:error-no-device -4) (:error-not-found -5) (:error-busy -6)
  (:error-timeout -7) (:error-overflow -8) (:error-pipe -9)
  (:error-interrupted -10) (:error-no-mem -11) (:error-not-supported -12)
  (:error-other -99))

(cffi:defcenum libusb-transfer-type
  (:control 0) (:isochronous 1) (:bulk 2) (:interrupt 3) (:bulk-stream 4))

;;; libusb fills this in itself and the set is closed, so unlike the
;;; device-reported enums it is safe as a struct slot type.
(cffi:defcenum libusb-transfer-status
  (:completed 0) (:error 1) (:timed-out 2) (:cancelled 3)
  (:stall 4) (:no-device 5) (:overflow 6))

;;; The :UINT8 base is load-bearing, not tidiness. struct libusb_transfer's
;;; flags member is a uint8_t at offset 8; a defbitfield defaulting to :int
;;; would read four bytes and take in endpoint, type and a pad byte with it.
;;; That misreads FREE_TRANSFER as set whenever the endpoint happens to be
;;; 0x04 -- a silent double free on every transfer to endpoint 4.
(cffi:defbitfield (libusb-transfer-flags :uint8)
  (:short-not-ok 1)
  (:free-buffer 2)
  (:free-transfer 4)
  (:add-zero-packet 8))

(cffi:defcenum (libusb-capability :uint32)
  (:has-capability #x0000)
  (:has-hotplug #x0001)
  (:has-hid-access #x0100)
  (:supports-detach-kernel-driver #x0101))

(cffi:defcenum libusb-log-level
  (:none 0) (:error 1) (:warning 2) (:info 3) (:debug 4))

(cffi:defbitfield libusb-log-cb-mode
  (:global 1)
  (:context 2))

(cffi:defcenum libusb-option
  (:log-level 0)
  (:use-usbdk 1)
  ;; LIBUSB_OPTION_WEAK_AUTHORITY is a #define alias for this one, not a value
  ;; of its own; :weak-authority is accepted as a synonym on the way in.
  (:weak-authority 2)
  (:no-device-discovery 2)
  (:log-cb 3))

(cffi:defcenum libusb-device-string-type
  (:manufacturer 0) (:product 1) (:serial-number 2))

;;; Single event, as handed to a hotplug callback...
(cffi:defcenum libusb-hotplug-event
  (:device-arrived 1)
  (:device-left 2))

;;; ...and the mask of events asked for at registration.
(cffi:defbitfield libusb-hotplug-events
  (:device-arrived 1)
  (:device-left 2))

(defconstant +hotplug-no-flags+ 0)
(defconstant +hotplug-enumerate+ 1
  "LIBUSB_HOTPLUG_ENUMERATE.

Makes libusb_hotplug_register_callback invoke the callback synchronously, on the
registering thread, once for every already-attached matching device, before it
returns. That is the only way to exercise a hotplug callback without physically
plugging something in, and the test suite is built on it.")

(defconstant +hotplug-match-any+ -1
  "LIBUSB_HOTPLUG_MATCH_ANY: the wildcard for the vendor, product and class
arguments of libusb_hotplug_register_callback.")

(defconstant +control-setup-size+ 8
  "sizeof(struct libusb_control_setup): the SETUP packet prefix a control
transfer's buffer carries ahead of its data.")

(defconstant +device-string-bytes-max+ 384
  "LIBUSB_DEVICE_STRING_BYTES_MAX -- 127 three-byte UTF-8 sequences plus a NUL.
The buffer size libusb_get_device_string wants (libusb 1.0.30 and later).")

(defun enum-keyword (enum-type value)
  "VALUE as a keyword of ENUM-TYPE, or VALUE itself if the enum has no such
member.

The tolerant counterpart to CFFI:FOREIGN-ENUM-KEYWORD, which signals instead.
Every value that reaches Lisp from a device's descriptors goes through here:
a class code, a speed or a descriptor type that this libusb -- or this library --
has never heard of must decode as a bare integer, not break enumeration for
every other device on the bus."
  (or (ignore-errors (cffi:foreign-enum-keyword enum-type value)) value))
