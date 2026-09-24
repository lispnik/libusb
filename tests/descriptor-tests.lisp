(in-package #:libusb/tests)
(in-suite libusb-descriptors)

;;; The parser takes pointers and returns Lisp values, touching no context and no
;;; handle. That is what lets these tests build descriptors in foreign memory by hand
;;; and assert on what comes back -- on a machine with no USB devices, and with
;;; values no real device would produce, which is where the interesting cases are.

(defmacro with-built-device-descriptor ((pointer &rest slots) &body body)
  `(cffi:with-foreign-object (,pointer '(:struct libusb::libusb-device-descriptor))
     (cffi:with-foreign-slots ((libusb::b-length libusb::b-descriptor-type
                                libusb::bcd-usb libusb::b-device-class
                                libusb::b-device-sub-class libusb::b-device-protocol
                                libusb::b-max-packet-size-0 libusb::id-vendor
                                libusb::id-product libusb::bcd-device
                                libusb::i-manufacturer libusb::i-product
                                libusb::i-serial-number
                                libusb::b-num-configurations)
                               ,pointer (:struct libusb::libusb-device-descriptor))
       (setf libusb::b-length 18 libusb::b-descriptor-type 1
             libusb::bcd-usb 0 libusb::b-device-class 0 libusb::b-device-sub-class 0
             libusb::b-device-protocol 0 libusb::b-max-packet-size-0 0
             libusb::id-vendor 0 libusb::id-product 0 libusb::bcd-device 0
             libusb::i-manufacturer 0 libusb::i-product 0 libusb::i-serial-number 0
             libusb::b-num-configurations 0)
       (setf ,@slots))
     ,@body))

(test a-device-descriptor-is-copied-field-for-field
  "The straightforward case, asserted once so the interesting ones below can be read
as deviations from it."
  (with-built-device-descriptor (p libusb::bcd-usb #x0210
                                   libusb::b-device-class 9
                                   libusb::id-vendor #x2109
                                   libusb::id-product #x3431
                                   libusb::bcd-device #x0421
                                   libusb::b-max-packet-size-0 64
                                   libusb::i-manufacturer 1
                                   libusb::i-product 2
                                   libusb::b-num-configurations 1)
    (let ((d (libusb::parse-device-descriptor p)))
      (is (= #x0210 (libusb:device-descriptor-usb-version d)))
      (is (eq :hub (libusb:device-descriptor-device-class d)))
      (is (= #x2109 (libusb:device-descriptor-vendor-id d)))
      (is (= #x3431 (libusb:device-descriptor-product-id d)))
      (is (= 64 (libusb:device-descriptor-max-packet-size-0 d)))
      (is (= 1 (libusb:device-descriptor-manufacturer-index d)))
      (is (= 2 (libusb:device-descriptor-product-index d)))
      (is (= 0 (libusb:device-descriptor-serial-number-index d))
          "index 0 means the device has no such string, and must survive as 0")
      (is (= 1 (libusb:device-descriptor-configuration-count d))))))

(test a-device-class-nobody-has-defined-yet-parses-as-an-integer
  "This is the whole reason the parser uses ENUM-KEYWORD rather than CFFI's own
translation. A device reporting class 0x7B would otherwise signal here, and it would
signal inside LIST-DEVICES -- so one strange device on the bus would make every
device on the bus unenumerable."
  (with-built-device-descriptor (p libusb::b-device-class #x7b)
    (let ((d (libusb::parse-device-descriptor p)))
      (is (eql #x7b (libusb:device-descriptor-device-class d))))))

(test a-bcd-version-is-kept-as-an-integer-and-formatted-on-demand
  "bcdUSB is BCD by convention and arbitrary in practice, so the parser keeps the
raw integer and BCD-VERSION-STRING formats it. A device reporting 0x0299 gets a
slightly odd string rather than an error, which is the right way round."
  (is (string= "2.10" (libusb:bcd-version-string #x0210)))
  (is (string= "1.00" (libusb:bcd-version-string #x0100)))
  (is (string= "3.20" (libusb:bcd-version-string #x0320)))
  (is (string= "2.99" (libusb:bcd-version-string #x0299))))

;;; --- endpoints, where bmAttributes is decoded --------------------------

(defun build-endpoint (pointer address attributes max-packet-size
                       &key (interval 0) extra extra-length)
  (cffi:with-foreign-slots ((libusb::b-length libusb::b-descriptor-type
                             libusb::b-endpoint-address libusb::bm-attributes
                             libusb::w-max-packet-size libusb::b-interval
                             libusb::b-refresh libusb::b-synch-address
                             libusb::extra libusb::extra-length)
                            pointer (:struct libusb::libusb-endpoint-descriptor))
    (setf libusb::b-length 7 libusb::b-descriptor-type 5
          libusb::b-endpoint-address address
          libusb::bm-attributes attributes
          libusb::w-max-packet-size max-packet-size
          libusb::b-interval interval
          libusb::b-refresh 0 libusb::b-synch-address 0
          libusb::extra (or extra (cffi:null-pointer))
          libusb::extra-length (or extra-length 0)))
  pointer)

(test an-endpoint-address-is-split-into-a-number-and-a-direction
  "Bit 7 of bEndpointAddress is the direction and bits 0:3 the number. Every caller
would otherwise write that mask themselves, and endpoint 0x83 being \"endpoint 3, IN\"
is the single most looked-up fact in USB."
  (cffi:with-foreign-object (p '(:struct libusb::libusb-endpoint-descriptor))
    (let ((ep (libusb::parse-endpoint-descriptor (build-endpoint p #x83 #x02 64))))
      (is (= #x83 (libusb:endpoint-descriptor-address ep)))
      (is (= 3 (libusb:endpoint-descriptor-number ep)))
      (is (eq :in (libusb:endpoint-descriptor-direction ep)))
      (is (eq :bulk (libusb:endpoint-descriptor-transfer-type ep)))
      (is (= 64 (libusb:endpoint-descriptor-max-packet-size ep))))
    (let ((ep (libusb::parse-endpoint-descriptor (build-endpoint p #x02 #x02 512))))
      (is (= 2 (libusb:endpoint-descriptor-number ep)))
      (is (eq :out (libusb:endpoint-descriptor-direction ep))))))

(test an-isochronous-endpoint-also-yields-its-sync-and-usage-types
  "bmAttributes bits 2:3 are the synchronisation type and 4:5 the usage type, and
they are only meaningful for an isochronous endpoint. USB 2.0 table 9-13, decoded
once here rather than at every call site -- and left NIL for the endpoint types where
those bits mean nothing, so a caller cannot read significance into a zero."
  (cffi:with-foreign-object (p '(:struct libusb::libusb-endpoint-descriptor))
    ;; 0x01 isochronous | 0x04 asynchronous sync | 0x20 implicit-feedback usage
    (let ((ep (libusb::parse-endpoint-descriptor (build-endpoint p #x81 #x25 192))))
      (is (eq :isochronous (libusb:endpoint-descriptor-transfer-type ep)))
      (is (eq :async (libusb:endpoint-descriptor-sync-type ep)))
      (is (eq :implicit (libusb:endpoint-descriptor-usage-type ep))))
    (let ((ep (libusb::parse-endpoint-descriptor (build-endpoint p #x81 #x03 8))))
      (is (eq :interrupt (libusb:endpoint-descriptor-transfer-type ep)))
      (is (null (libusb:endpoint-descriptor-sync-type ep))
          "an interrupt endpoint has no synchronisation type, so NIL and not :NONE")
      (is (null (libusb:endpoint-descriptor-usage-type ep))))))

(test class-specific-descriptor-blobs-are-copied-rather-than-referenced
  "The `extra' bytes are HID report descriptors, UVC and audio class descriptors --
things libusb does not parse and neither does this library. They still have to be
copied, because the C memory they live in is freed by
libusb_free_config_descriptor before the caller sees anything; and they have to be
copied rather than dropped, because they are the whole content of exactly the devices
people write bindings for."
  (cffi:with-foreign-object (blob :uint8 4)
    (loop for i below 4 do (setf (cffi:mem-aref blob :uint8 i) (+ 10 i)))
    (cffi:with-foreign-object (p '(:struct libusb::libusb-endpoint-descriptor))
      (let ((ep (libusb::parse-endpoint-descriptor
                 (build-endpoint p #x81 #x03 8 :extra blob :extra-length 4))))
        (is (equalp #(10 11 12 13) (libusb:endpoint-descriptor-extra ep)))
        ;; Scribble over the C memory: a copy is unaffected, a reference is not.
        (dotimes (i 4) (setf (cffi:mem-aref blob :uint8 i) 0))
        (is (equalp #(10 11 12 13) (libusb:endpoint-descriptor-extra ep))
            "the extra bytes were referenced, not copied -- they would be garbage by ~
             the time the caller read them")))))

(test an-endpoint-with-no-extra-data-gets-nil-rather-than-an-empty-vector
  "So that (when (endpoint-descriptor-extra ep) ...) is the test a reader expects."
  (cffi:with-foreign-object (p '(:struct libusb::libusb-endpoint-descriptor))
    (is (null (libusb:endpoint-descriptor-extra
               (libusb::parse-endpoint-descriptor (build-endpoint p #x81 #x03 8)))))))

;;; --- a whole configuration tree ----------------------------------------

(test a-configuration-tree-is-copied-whole-including-alternate-settings
  "The shape libusb hands back is a config, an array of interfaces, an array of
alternate settings per interface and an array of endpoints per setting -- four levels
of pointer, all of it freed by libusb_free_config_descriptor. This builds that shape
by hand, parses it, and then frees nothing: what comes back must be independent of
every one of those allocations."
  (cffi:with-foreign-object (endpoints '(:struct libusb::libusb-endpoint-descriptor) 2)
    (build-endpoint (cffi:mem-aptr endpoints
                                   '(:struct libusb::libusb-endpoint-descriptor) 0)
                    #x83 #x02 64)
    (build-endpoint (cffi:mem-aptr endpoints
                                   '(:struct libusb::libusb-endpoint-descriptor) 1)
                    #x04 #x02 64)
    (cffi:with-foreign-object (alts '(:struct libusb::libusb-interface-descriptor) 2)
      (dotimes (j 2)
        (let ((alt (cffi:mem-aptr alts
                                  '(:struct libusb::libusb-interface-descriptor) j)))
          (cffi:with-foreign-slots ((libusb::b-length libusb::b-descriptor-type
                                     libusb::b-interface-number
                                     libusb::b-alternate-setting
                                     libusb::b-num-endpoints
                                     libusb::b-interface-class
                                     libusb::b-interface-sub-class
                                     libusb::b-interface-protocol
                                     libusb::i-interface libusb::endpoint
                                     libusb::extra libusb::extra-length)
                                    alt (:struct libusb::libusb-interface-descriptor))
            (setf libusb::b-length 9 libusb::b-descriptor-type 4
                  libusb::b-interface-number 0
                  libusb::b-alternate-setting j
                  ;; Alt setting 0 has no endpoints, alt 1 has both -- which is how a
                  ;; real UVC or audio device is arranged, and a shape that catches a
                  ;; parser that assumes every setting looks the same.
                  libusb::b-num-endpoints (if (zerop j) 0 2)
                  libusb::b-interface-class #xff
                  libusb::b-interface-sub-class 0 libusb::b-interface-protocol 0
                  libusb::i-interface 0
                  libusb::endpoint endpoints
                  libusb::extra (cffi:null-pointer) libusb::extra-length 0))))
      (cffi:with-foreign-object (interfaces '(:struct libusb::libusb-interface))
        (setf (cffi:foreign-slot-value interfaces '(:struct libusb::libusb-interface)
                                       'libusb::altsetting)
              alts
              (cffi:foreign-slot-value interfaces '(:struct libusb::libusb-interface)
                                       'libusb::num-altsetting)
              2)
        (cffi:with-foreign-object (config '(:struct libusb::libusb-config-descriptor))
          (cffi:with-foreign-slots ((libusb::b-length libusb::b-descriptor-type
                                     libusb::w-total-length
                                     libusb::b-num-interfaces
                                     libusb::b-configuration-value
                                     libusb::i-configuration libusb::bm-attributes
                                     libusb::max-power libusb::interface-array
                                     libusb::extra libusb::extra-length)
                                    config (:struct libusb::libusb-config-descriptor))
            (setf libusb::b-length 9 libusb::b-descriptor-type 2
                  libusb::w-total-length 32 libusb::b-num-interfaces 1
                  libusb::b-configuration-value 1 libusb::i-configuration 0
                  ;; 0xC0: self-powered (bit 6) and remote wakeup (bit 5).
                  libusb::bm-attributes #xe0
                  libusb::max-power 250   ; 2 mA units -> 500 mA
                  libusb::interface-array interfaces
                  libusb::extra (cffi:null-pointer) libusb::extra-length 0))
          (let ((c (libusb::parse-config-descriptor config)))
            (is (= 1 (libusb:config-descriptor-configuration-value c)))
            (is (= 500 (libusb:config-descriptor-max-power-ma c))
                "bMaxPower is in 2 mA units and must be doubled")
            (is-true (libusb:config-descriptor-self-powered-p c))
            (is-true (libusb:config-descriptor-remote-wakeup-p c))
            (is (= 1 (length (libusb:config-descriptor-interfaces c))))
            (let* ((iface (svref (libusb:config-descriptor-interfaces c) 0))
                   (settings (libusb:usb-interface-alt-settings iface)))
              (is (= 2 (length settings)))
              (is (= 0 (length (libusb:interface-descriptor-endpoints (svref settings 0))))
                  "alternate setting 0 has no endpoints, as a real one often does not")
              (is (= 2 (length (libusb:interface-descriptor-endpoints (svref settings 1)))))
              (is (eq :vendor-spec (libusb:interface-descriptor-interface-class
                                    (svref settings 1)))
                  "0xFF is in libusb_class_code, so it decodes rather than staying an ~
                   integer -- the integer fallback is for values the enum lacks")
              (let ((ep (svref (libusb:interface-descriptor-endpoints
                                (svref settings 1)) 0)))
                (is (= #x83 (libusb:endpoint-descriptor-address ep)))
                (is (eq :in (libusb:endpoint-descriptor-direction ep)))))
            ;; FIND-ENDPOINT is the everyday question -- "how big are packets on
            ;; 0x83?" -- and the reason it takes an alt setting is the shape above.
            (is (null (libusb:find-endpoint c #x83))
                "alternate setting 0 really has no 0x83")
            (let ((found (libusb:find-endpoint c #x83 :alt-setting 1)))
              (is-true found)
              (is (= 64 (libusb:endpoint-descriptor-max-packet-size found))))
            (is (null (libusb:find-endpoint c #x99 :alt-setting 1)))))))))
