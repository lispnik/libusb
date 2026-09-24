(in-package #:libusb/tests)
(in-suite libusb-enums)

;;; --- widths ------------------------------------------------------------

(test the-transfer-flags-bitfield-is-exactly-one-byte-wide
  "struct libusb_transfer's flags member is a uint8_t at offset 8, followed by
endpoint at 9 and type at 10. A DEFBITFIELD defaulting to :INT would read four bytes
and take all three in, so LIBUSB_TRANSFER_FREE_TRANSFER (value 4) would read as set
whenever the endpoint happened to be 0x04 -- a silent double free on every transfer
to endpoint 4. Hence the explicit :UINT8 base, and hence this test."
  (is (= 1 (cffi:foreign-type-size 'libusb::libusb-transfer-flags)))
  (cffi:with-foreign-object (transfer :uint8 64)
    (dotimes (i 64) (setf (cffi:mem-aref transfer :uint8 i) 0))
    ;; Endpoint 4, no flags: the exact arrangement that would trip an :int read.
    (setf (cffi:mem-aref transfer :uint8 9) 4)
    (is (null (cffi:foreign-slot-value transfer '(:struct libusb::libusb-transfer)
                                       'libusb::flags))
        "endpoint 0x04 leaked into the flags bitfield")))

;;; --- tolerant translation ----------------------------------------------

(test an-unknown-enum-value-comes-back-as-an-integer-instead-of-signalling
  "CFFI:FOREIGN-ENUM-KEYWORD signals on a value it was not told about. Device
descriptors are full of values nobody was told about -- a class code from a 2030
specification, a speed libusb learned this year -- and one of them must not break
enumeration for every other device on the bus. ENUM-KEYWORD is the tolerant version,
and every value that reaches Lisp from a device goes through it."
  (is (eq :hub (libusb:enum-keyword 'libusb::libusb-class-code #x09)))
  (is (eql 66 (libusb:enum-keyword 'libusb::libusb-class-code 66)))
  (is (eql 7 (libusb:enum-keyword 'libusb::libusb-speed 7))
      "a speed newer than this library must arrive as an integer")
  (signals error (cffi:foreign-enum-keyword 'libusb::libusb-class-code 66)
    "the point of ENUM-KEYWORD is that this is what it is protecting against"))

(test the-duplicated-class-code-decodes-the-way-it-was-ordered-to
  "LIBUSB_CLASS_IMAGE and LIBUSB_CLASS_PTP are both 0x06. CFFI's value-to-keyword
map keeps the last definition of a duplicated value, so the order in enums.lisp is
load-bearing rather than incidental: :PTP is listed first and :IMAGE second so that
0x06 decodes as :IMAGE, which is what the USB specification calls the class, while
:PTP still works as an input spelling."
  (is (eq :image (libusb:enum-keyword 'libusb::libusb-class-code #x06)))
  (is (= #x06 (cffi:foreign-enum-value 'libusb::libusb-class-code :ptp)))
  (is (= #x06 (cffi:foreign-enum-value 'libusb::libusb-class-code :image))))

(test request-type-assembles-the-bits-the-usb-specification-puts-them-in
  "bmRequestType is direction in bit 7, type in bits 5:6, recipient in bits 0:4.
Worth one test because every control transfer in the world depends on it and the
failure mode is a device that answers nothing at all."
  (is (= #x80 (libusb:request-type :direction :in)))
  (is (= #x00 (libusb:request-type :direction :out)))
  (is (= #xc1 (libusb:request-type :direction :in :type :vendor :recipient :interface))
      "IN | vendor | interface")
  (is (= #x21 (libusb:request-type :direction :out :type :class :recipient :interface))
      "the SET_REPORT prefix every HID device expects"))

(test the-hotplug-constants-are-the-ones-libusb-documents
  "LIBUSB_HOTPLUG_MATCH_ANY is -1, not 0, and ENUMERATE is 1. Getting MATCH_ANY
wrong would silently register a callback that matches vendor 0 and therefore
nothing, which looks exactly like hotplug not working."
  (is (= -1 libusb:+hotplug-match-any+))
  (is (= 1 libusb:+hotplug-enumerate+))
  (is (= 0 libusb:+hotplug-no-flags+))
  (is (= 8 libusb:+control-setup-size+)))
