(in-package #:libusb/tests)
(in-suite libusb-structs)

;;; --- struct libusb_transfer, the one that matters ----------------------

(test the-transfer-struct-fields-are-where-c-puts-them
  "Every offset in struct libusb_transfer, pinned.

These declarations are hand-written rather than grovelled, which is the right trade
for structs this plain -- but it makes the layout an assumption, and an assumption
about foreign struct layout is exactly the kind that holds on the machine it was
written on and fails on the one it has to work on. ci/check-layout.sh compares the
same numbers against the installed libusb.h with a C compiler; this test is the half
that runs everywhere, including where no compiler is installed."
  (flet ((offset (slot)
           (cffi:foreign-slot-offset '(:struct libusb::libusb-transfer) slot)))
    (is (= 0 (offset 'libusb::dev-handle)))
    (is (= 8 (offset 'libusb::flags)))
    (is (= 9 (offset 'libusb::endpoint)))
    (is (= 10 (offset 'libusb::type)))
    (is (= 12 (offset 'libusb::timeout)))
    (is (= 16 (offset 'libusb::status)))
    (is (= 20 (offset 'libusb::length)))
    (is (= 24 (offset 'libusb::actual-length)))
    (is (= 32 (offset 'libusb::callback)))
    (is (= 40 (offset 'libusb::user-data)))
    (is (= 48 (offset 'libusb::buffer)))
    (is (= 56 (offset 'libusb::num-iso-packets)))))

(test the-iso-packet-array-begins-before-the-end-of-the-struct
  "iso_packet_desc[] is a C99 flexible array member at offset 60 on LP64, while
sizeof(struct libusb_transfer) rounds up to 64 for pointer alignment.

Those four bytes are the trap. Computing a packet's address from FOREIGN-TYPE-SIZE
instead of FOREIGN-SLOT-OFFSET lands past the start of the array and corrupts the
first packet descriptor -- and an isochronous stream whose first packet is wrong
looks like a device problem, not a binding problem. So the offset is a constant
computed from the slot, and this test asserts it is not the type size."
  (is (= 60 libusb:+transfer-iso-packet-desc-offset+))
  (is (= 60 (cffi:foreign-slot-offset '(:struct libusb::libusb-transfer)
                                      'libusb::iso-packet-desc)))
  ;; CFFI's size for this struct is 72, not C's 64, because the flexible member is
  ;; declared here as a one-element array so that FOREIGN-SLOT-OFFSET can find it. That
  ;; discrepancy is the point: FOREIGN-TYPE-SIZE of this struct is not sizeof, and
  ;; ci/check-layout.sh is what compares the offsets against a C compiler.
  (is (> (cffi:foreign-type-size '(:struct libusb::libusb-transfer))
         libusb:+transfer-iso-packet-desc-offset+)
      "the type size must be past the array's start, or the declaration is wrong")
  (is (/= libusb:+transfer-iso-packet-desc-offset+
          (cffi:foreign-type-size '(:struct libusb::libusb-transfer)))
      "if these were ever equal, nothing above would be worth saying")
  (is (= 12 (- (cffi:foreign-type-size '(:struct libusb::libusb-transfer))
               libusb:+transfer-iso-packet-desc-offset+))
      "one declared iso packet descriptor's worth, and no padding"))

(test iso-packet-descriptors-are-addressed-twelve-bytes-apart
  "Three unsigned ints, and libusb allocates them contiguously after the struct."
  (is (= 12 (cffi:foreign-type-size '(:struct libusb::libusb-iso-packet-descriptor))))
  (cffi:with-foreign-object (transfer :uint8 256)
    (let ((base (cffi:pointer-address transfer)))
      (is (= (+ base 60) (cffi:pointer-address
                          (libusb:transfer-iso-packet-descriptor transfer 0))))
      (is (= (+ base 72) (cffi:pointer-address
                          (libusb:transfer-iso-packet-descriptor transfer 1))))
      (is (= (+ base 60 (* 8 12))
             (cffi:pointer-address (libusb:transfer-iso-packet-descriptor transfer 8)))))))

;;; --- the standard descriptors ------------------------------------------

(test the-descriptor-structs-are-the-sizes-the-usb-specification-gives
  "A device descriptor is 18 bytes on the wire and 18 bytes in memory -- no padding,
because every 16-bit field in it happens to be 2-byte aligned. A control SETUP packet
is 8. Both are numbers a reader can check against chapter 9 of the specification,
which is why they are asserted rather than trusted."
  (is (= 18 (cffi:foreign-type-size '(:struct libusb::libusb-device-descriptor))))
  (is (= 8 (cffi:foreign-type-size '(:struct libusb::libusb-control-setup))))
  (is (= 8 libusb:+control-setup-size+)))

(test the-control-setup-fields-are-packed-the-way-the-wire-is
  "LIBUSB_PACKED on this struct changes nothing on any ABI this library runs on --
bmRequestType at 0, bRequest at 1, then three 16-bit fields at 2, 4 and 6 -- but the
buffer it describes goes onto the wire, so being sure is worth four lines."
  (flet ((offset (slot)
           (cffi:foreign-slot-offset '(:struct libusb::libusb-control-setup) slot)))
    (is (= 0 (offset 'libusb::bm-request-type)))
    (is (= 1 (offset 'libusb::b-request)))
    (is (= 2 (offset 'libusb::w-value)))
    (is (= 4 (offset 'libusb::w-index)))
    (is (= 6 (offset 'libusb::w-length)))))

(test a-setup-packet-written-by-this-library-has-the-bytes-the-spec-requires
  "GET_DESCRIPTOR for string index 2 in US English, byte for byte. The multi-byte
fields are little-endian on the wire, which is what %LIBUSB-CPU-TO-LE16 is for and
what this asserts -- on a big-endian host the same test would catch its absence."
  (cffi:with-foreign-object (buffer :uint8 8)
    (libusb::%libusb-fill-control-setup buffer #x80 #x06 #x0302 #x0409 255)
    (let ((bytes (loop for i below 8 collect (cffi:mem-aref buffer :uint8 i))))
      (is (equal '(#x80 #x06 #x02 #x03 #x09 #x04 #xff #x00) bytes)
          "SETUP packet was ~{#x~2,'0X~^ ~}" bytes))))

(test struct-timeval-matches-this-platforms-abi
  "The one struct whose layout genuinely differs: tv_usec is 32 bits on Darwin and
BSD, and a long on glibc. Getting it wrong gives a timeout that is either enormous or
zero depending on which half of the word the value lands in -- and it would only
misbehave on one of the two machines this library is built for."
  (is (= 16 (cffi:foreign-type-size '(:struct libusb::timeval))))
  (is (= 8 (cffi:foreign-slot-offset '(:struct libusb::timeval) 'libusb::tv-usec)))
  (cffi:with-foreign-object (tv '(:struct libusb::timeval))
    (libusb::%set-timeval tv 1.5)
    (is (= 1 (cffi:foreign-slot-value tv '(:struct libusb::timeval) 'libusb::tv-sec)))
    (is (= 500000 (cffi:foreign-slot-value tv '(:struct libusb::timeval)
                                           'libusb::tv-usec)))))
