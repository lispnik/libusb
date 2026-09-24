(in-package #:libusb/tests)
(in-suite libusb-conditions)

(test every-libusb-error-code-maps-to-its-own-condition-class
  "A caller should be able to write (handler-case ... (libusb-busy ...)) rather than
comparing integers, and LIBUSB-ACCESS-ERROR in particular is worth catching by name:
on Linux it almost always means the /dev/bus/usb node is not writable, which is a
different conversation from anything about the device."
  (loop for (code class) in '((-1 libusb:libusb-io-error)
                              (-2 libusb:libusb-invalid-param)
                              (-3 libusb:libusb-access-error)
                              (-4 libusb:libusb-no-device)
                              (-5 libusb:libusb-not-found)
                              (-6 libusb:libusb-busy)
                              (-7 libusb:libusb-timeout)
                              (-8 libusb:libusb-overflow)
                              (-9 libusb:libusb-pipe-error)
                              (-10 libusb:libusb-interrupted)
                              (-11 libusb:libusb-no-memory)
                              (-12 libusb:libusb-not-supported)
                              (-99 libusb:libusb-other-error))
        do (let ((condition (handler-case (libusb:check-result code 'test-function)
                              (libusb:libusb-error (e) e))))
             (is (typep condition class) "code ~D gave ~S" code (type-of condition))
             (is (typep condition 'libusb:libusb-error)
                 "every one of these must also be trappable as LIBUSB-ERROR")
             (is (= code (libusb:libusb-error-code condition))))))

(test an-error-code-from-a-newer-libusb-is-reported-rather-than-crashing
  "A libusb 1.0.31 with a new error value must not turn a device problem into a bug
in this library: an unrecognised negative code is a device error we cannot name, so it
maps to LIBUSB-OTHER-ERROR and keeps its integer."
  (let ((condition (handler-case (libusb:check-result -77 'test-function)
                     (libusb:libusb-error (e) e))))
    (is (typep condition 'libusb:libusb-other-error))
    (is (= -77 (libusb:libusb-error-code condition)))
    (is (eql -77 (libusb:error-code-keyword -77))
        "ERROR-CODE-KEYWORD keeps the integer when it has no keyword for it"))
  (is (search "unrecognised" (libusb:error-code-message -77))))

(test check-result-passes-success-and-non-negative-counts-straight-through
  "libusb returns a transferred byte count from several entry points, so \"not
negative\" is the test and not \"zero\"."
  (is (= 0 (libusb:check-result 0 'test-function)))
  (is (= 64 (libusb:check-result 64 'test-function)))
  (is (= 12345 (libusb:check-result 12345 'test-function))))

(test an-error-report-names-the-function-it-came-from
  "\"libusb: %LIBUSB-CLAIM-INTERFACE: resource busy (-6)\" is a bug report;
\"error -6\" is a scavenger hunt. The context string carries what the caller knew and
libusb did not -- which interface, which endpoint."
  (let ((text (handler-case (libusb:check-result -6 '%libusb-claim-interface
                                                 "interface 0")
                (libusb:libusb-error (e) (princ-to-string e)))))
    (is (search "%LIBUSB-CLAIM-INTERFACE" text))
    (is (search "resource busy" text))
    (is (search "-6" text))
    (is (search "interface 0" text))))

(test the-message-table-does-not-depend-on-libusb-being-loaded
  "Deliberately not libusb_strerror. This file must be able to report a failure before
the shared library has been opened -- including the failure to open it -- and
libusb_setlocale can translate libusb's own text out from under a caller who matched
on it."
  (is (string= "resource busy" (libusb:error-code-message -6)))
  (is (string= "success" (libusb:error-code-message 0)))
  (is (eq :error-busy (libusb:error-code-keyword -6)))
  (is (eq :success (libusb:error-code-keyword 0))))

(test using-a-closed-context-signals-instead-of-dereferencing-freed-memory
  "This is the condition that earns its keep. Without the liveness check, every one of
these calls reads through a pointer libusb_exit has already freed -- and the
difference between LIBUSB-INVALID-OBJECT and a segmentation fault is the difference
between a minute and an afternoon."
  (let ((context (libusb:open-context)))
    (libusb:close-context context)
    (is-false (libusb:context-live-p context))
    (signals libusb:libusb-invalid-object (libusb:list-devices :context context))
    (signals libusb:libusb-invalid-object (libusb:handle-events context))
    ;; Idempotent: closing twice must be harmless, because teardown paths do it.
    (finishes (libusb:close-context context))))

(test a-usage-error-is-distinct-from-a-libusb-error
  "Nothing was asked of libusb in these cases: the call was rejected here, before it
could become undefined behaviour in C. A caller handling LIBUSB-API-ERROR is handling
device problems and should not also catch their own mistakes."
  (let ((context (libusb:open-context)))
    (unwind-protect
         (progn
           (signals libusb:libusb-usage-error
             (libusb:control-transfer (libusb::%make-device-handle
                                       (cffi:null-pointer) nil context
                                       (libusb:image-epoch))
                                      :data #(1 2 3) :length 4))
           (is (not (subtypep 'libusb:libusb-usage-error 'libusb:libusb-api-error))))
      (libusb:close-context context))))
