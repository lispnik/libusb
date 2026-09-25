(in-package #:libusb/tests)
(in-suite libusb-symbols)

;;; --- what the installed libusb actually has ----------------------------

(test every-binding-either-resolves-or-is-a-known-later-addition
  "Walk all ~100 bindings and probe each with CFFI:FOREIGN-SYMBOL-POINTER.

This is the test that catches a typo in a C function name, which is otherwise
invisible until somebody calls that one function and gets an undefined-alien error
naming an address. It deliberately does not assert a count: libusb 1.0.28 on the
Raspberry Pi exports five fewer entry points than 1.0.30 on a development machine,
and 1.0.27 on CI's Ubuntu 24.04 two fewer again. Those seven are bound behind a
runtime probe precisely so that the library loads on all three. So the assertion is
the narrower and truer one -- anything missing must be one of the seven we already
know about."
  (let* ((known-later '("libusb_get_ssplus_usb_device_capability_descriptor"
                        "libusb_free_ssplus_usb_device_capability_descriptor"
                        "libusb_get_device_string" "libusb_get_session_data"
                        "libusb_endpoint_supports_raw_io" "libusb_endpoint_set_raw_io"
                        "libusb_get_max_raw_io_transfer_size"))
         (missing (remove-if (lambda (binding)
                               (libusb:foreign-function-available-p (car binding)))
                             libusb::*raw-bindings*))
         (unexpected (remove-if (lambda (binding)
                                  (member (car binding) known-later :test #'string=))
                                missing)))
    (is (null unexpected)
        "these bindings name symbols the installed libusb ~A does not export: ~{~A~^ ~}"
        (libusb:version-string) (mapcar #'car unexpected))
    (format t "~&; libusb ~A: ~D of ~D bindings resolve~@[; absent: ~{~A~^ ~}~]~%"
            (libusb:version-string)
            (- (length libusb::*raw-bindings*) (length missing))
            (length libusb::*raw-bindings*)
            (mapcar #'car missing))))

(test a-missing-version-guarded-function-signals-rather-than-crashing
  "libusb_get_device_string exists in 1.0.30 and not in 1.0.28, and this library has
to run against both. Calling one that is absent must signal a condition that names
the function and the version that introduced it -- not die in SBCL's undefined-alien
handler, which reports an address and leaves you grepping."
  (if (libusb:foreign-function-available-p "libusb_get_device_string")
      (pass "libusb ~A has libusb_get_device_string; the absent path is exercised ~
             on the Raspberry Pi, which runs 1.0.28"
            (libusb:version-string))
      (signals libusb:libusb-unsupported-function
        (libusb::%libusb-get-device-string (cffi:null-pointer) :product
                                          (cffi:null-pointer) 0))))

(test the-library-reports-a-plausible-version
  "A sanity check on the one piece of information every version guard depends on.
If libusb_get_version were mis-bound -- a wrong struct layout, say -- everything
downstream would branch on nonsense."
  (multiple-value-bind (major minor micro nano) (libusb:version)
    (is (= 1 major) "libusb major version ~D" major)
    (is (= 0 minor) "libusb minor version ~D" minor)
    (is (<= 24 micro 99) "libusb micro version ~D is outside anything released" micro)
    (is (integerp nano))))
