;;; libusb's foreign structures.
;;;
;;; Hand-written rather than grovelled, on purpose. Every one of these is a
;;; plain C struct of fixed-width integers and pointers, so CFFI's own
;;; alignment rules reproduce the C layout exactly, and a grovel file would
;;; mean a C compiler and a header at build time for no information we do not
;;; already have. The one place that assumption genuinely fails -- struct
;;; timeval, whose tv_usec is 32 bits on Darwin and 64 on glibc -- is handled
;;; with a read-time conditional below, and tests/struct-tests.lisp pins the
;;; offsets that matter so the assumption cannot rot silently.
;;;
;;; Struct slot names transliterate their C field: bLength is B-LENGTH,
;;; idVendor is ID-VENDOR, wMaxPacketSize is W-MAX-PACKET-SIZE. It reads oddly
;;; in Lisp and that is the trade: chapter 9 of the USB specification is the
;;; reference for all of this, and a reader holding it should not need a
;;; translation table.

(in-package #:libusb)

;;; --- standard USB descriptors -----------------------------------------

(cffi:defcstruct libusb-device-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (bcd-usb :uint16)
  (b-device-class :uint8)
  (b-device-sub-class :uint8)
  (b-device-protocol :uint8)
  (b-max-packet-size-0 :uint8)
  (id-vendor :uint16)
  (id-product :uint16)
  (bcd-device :uint16)
  (i-manufacturer :uint8)
  (i-product :uint8)
  (i-serial-number :uint8)
  (b-num-configurations :uint8))

(cffi:defcstruct libusb-endpoint-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-endpoint-address :uint8)
  (bm-attributes :uint8)
  (w-max-packet-size :uint16)
  (b-interval :uint8)
  (b-refresh :uint8)
  (b-synch-address :uint8)
  (extra :pointer)
  (extra-length :int))

(cffi:defcstruct libusb-interface-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-interface-number :uint8)
  (b-alternate-setting :uint8)
  (b-num-endpoints :uint8)
  (b-interface-class :uint8)
  (b-interface-sub-class :uint8)
  (b-interface-protocol :uint8)
  (i-interface :uint8)
  (endpoint :pointer)
  (extra :pointer)
  (extra-length :int))

(cffi:defcstruct libusb-interface
  (altsetting :pointer)
  (num-altsetting :int))

(cffi:defcstruct libusb-config-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (w-total-length :uint16)
  (b-num-interfaces :uint8)
  (b-configuration-value :uint8)
  (i-configuration :uint8)
  (bm-attributes :uint8)
  (max-power :uint8)
  ;; Named INTERFACE-ARRAY, not INTERFACE: the C field is `interface', which
  ;; would give a slot accessor colliding with nothing but reads as a type name
  ;; in Lisp. The array is of struct libusb_interface, one per interface.
  (interface-array :pointer)
  (extra :pointer)
  (extra-length :int))

;;; LIBUSB_PACKED in the header, but every field is already naturally aligned
;;; (0, 1, 2, 4, 6; size 8), so the attribute changes nothing on any ABI this
;;; library runs on and CFFI reproduces the layout as written.
(cffi:defcstruct libusb-control-setup
  (bm-request-type :uint8)
  (b-request :uint8)
  (w-value :uint16)
  (w-index :uint16)
  (w-length :uint16))

(cffi:defcstruct libusb-version
  (major :uint16)
  (minor :uint16)
  (micro :uint16)
  (nano :uint16)
  (rc :string)
  (describe :string))

;;; --- transfers ---------------------------------------------------------

(cffi:defcstruct libusb-iso-packet-descriptor
  (length :uint)
  (actual-length :uint)
  (status libusb-transfer-status))

;;; The trailing iso_packet_desc[] is a C99 flexible array member, declared here
;;; as a one-element array so that CFFI:FOREIGN-SLOT-OFFSET can find its base.
;;;
;;; The consequence is a trap worth stating plainly: FOREIGN-TYPE-SIZE of this
;;; struct is NOT sizeof(struct libusb_transfer). The C sizeof is 64 on LP64
;;; while the array begins at offset 60, so computing a packet's address from
;;; the type size lands one packet's worth of padding too far in and corrupts
;;; the first descriptor. Nothing here ever allocates one of these anyway --
;;; only libusb_alloc_transfer may, because libusb sizes it for the packet count
;;; -- and tests/struct-tests.lisp pins the offset so this cannot drift.
(cffi:defcstruct libusb-transfer
  (dev-handle :pointer)
  (flags libusb-transfer-flags)         ; uint8_t; see the note in enums.lisp
  (endpoint :uint8)
  (type :uint8)
  (timeout :uint)
  (status libusb-transfer-status)
  (length :int)
  (actual-length :int)
  (callback :pointer)
  (user-data :pointer)
  (buffer :pointer)
  (num-iso-packets :int)
  (iso-packet-desc (:array (:struct libusb-iso-packet-descriptor) 1)))

(defconstant +transfer-iso-packet-desc-offset+
  (cffi:foreign-slot-offset '(:struct libusb-transfer) 'iso-packet-desc)
  "Byte offset of struct libusb_transfer's flexible iso_packet_desc[] member.

60 on LP64. Not FOREIGN-TYPE-SIZE of the struct, which rounds up to 64 -- see
the comment above LIBUSB-TRANSFER.")

(declaim (inline transfer-iso-packet-descriptor))
(defun transfer-iso-packet-descriptor (transfer-pointer index)
  "A pointer to iso packet descriptor INDEX of the transfer at TRANSFER-POINTER."
  (cffi:inc-pointer transfer-pointer
                    (+ +transfer-iso-packet-desc-offset+
                       (* index (cffi:foreign-type-size
                                 '(:struct libusb-iso-packet-descriptor))))))

;;; --- event handling ----------------------------------------------------

(cffi:defcstruct libusb-pollfd
  (fd :int)
  (events :short))

;;; The one struct whose layout genuinely differs by platform: tv_usec is
;;; __int32_t on Darwin and BSD, and suseconds_t -- a long, so 64 bits on LP64
;;; -- with glibc. Getting this wrong gives a timeout that is either enormous
;;; or zero depending on which half of the word the value lands in, and it
;;; would only show up on one of the two machines this library is built for.
(cffi:defcstruct timeval
  (tv-sec :long)
  #+(or darwin freebsd openbsd netbsd) (tv-usec :int32)
  #-(or darwin freebsd openbsd netbsd) (tv-usec :long))

;;; --- initialisation options --------------------------------------------

(cffi:defcunion libusb-init-option-value
  (ival :int)
  (log-cbval :pointer))

(cffi:defcstruct libusb-init-option
  (option libusb-option)
  (value (:union libusb-init-option-value)))

;;; --- BOS and SuperSpeed capability descriptors -------------------------
;;;
;;; Raw-only by design: these are parsed by libusb into allocated trees, each
;;; with its own free function, and a consumer of USB 3 link attributes is
;;; better served by the C shape than by a Lisp translation nobody has a device
;;; to test.

(cffi:defcstruct libusb-ss-endpoint-companion-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-max-burst :uint8)
  (bm-attributes :uint8)
  (w-bytes-per-interval :uint16))

(cffi:defcstruct libusb-bos-dev-capability-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-dev-capability-type :uint8)
  ;; Flexible array member; read it with CFFI:MEM-AREF off a pointer to this
  ;; slot, for (- b-length 3) bytes.
  (dev-capability-data (:array :uint8 1)))

(cffi:defcstruct libusb-bos-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (w-total-length :uint16)
  (b-num-device-caps :uint8)
  ;; Flexible array of pointers, b-num-device-caps of them.
  (dev-capability (:array :pointer 1)))

(cffi:defcstruct libusb-usb-2-0-extension-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-dev-capability-type :uint8)
  (bm-attributes :uint32))

(cffi:defcstruct libusb-ss-usb-device-capability-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-dev-capability-type :uint8)
  (bm-attributes :uint8)
  (w-speed-supported :uint16)
  (b-functionality-support :uint8)
  (b-u1-dev-exit-lat :uint8)
  (b-u2-dev-exit-lat :uint16))

;;; Note the enum-typed members: each is a full int, so this struct is 24 bytes
;;; and not the 8 the wire format would suggest. libusb hands back a parsed
;;; form here, not the descriptor as it arrived.
(cffi:defcstruct libusb-ssplus-sublink-attribute
  (ssid :uint8)
  (exponent libusb-ssplus-exponent)
  (type libusb-ssplus-sublink-type)
  (direction libusb-ssplus-sublink-direction)
  (protocol libusb-ssplus-link-protocol)
  (mantissa :uint16))

;;; Likewise parsed, which is why it has no bLength or bDescriptorType.
(cffi:defcstruct libusb-ssplus-usb-device-capability-descriptor
  (num-sublink-speed-attributes :uint8)
  (num-sublink-speed-ids :uint8)
  (ssid :uint8)
  (min-rx-lane-count :uint8)
  (min-tx-lane-count :uint8)
  (sublink-speed-attributes (:array (:struct libusb-ssplus-sublink-attribute) 1)))

(cffi:defcstruct libusb-container-id-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-dev-capability-type :uint8)
  (b-reserved :uint8)
  (container-id (:array :uint8 16)))

(cffi:defcstruct libusb-platform-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-dev-capability-type :uint8)
  (b-reserved :uint8)
  (platform-capability-uuid (:array :uint8 16))
  (capability-data (:array :uint8 1)))

(cffi:defcstruct libusb-interface-association-descriptor
  (b-length :uint8)
  (b-descriptor-type :uint8)
  (b-first-interface :uint8)
  (b-interface-count :uint8)
  (b-function-class :uint8)
  (b-function-sub-class :uint8)
  (b-function-protocol :uint8)
  (i-function :uint8))

(cffi:defcstruct libusb-interface-association-descriptor-array
  (iad :pointer)
  (length :int))
