;;; Entry points that may not exist in the libusb we are loaded against.
;;;
;;; libusb 1.0.29 added the raw-I/O trio, and 1.0.30 added
;;; libusb_get_device_string and libusb_get_session_data. The Raspberry Pi this
;;; library is verified on runs 1.0.28, which has none of them, while the
;;; machine it is developed on runs 1.0.30, which has all five.
;;;
;;; The guard is a runtime CFFI:FOREIGN-SYMBOL-POINTER probe rather than a
;;; read-time feature, and that is the whole point of this file: which libusb we
;;; are loaded against is not known when this code is compiled. The same fasl
;;; has to work on both machines, and a saved image can be restored on a third.
;;; A missing symbol signals LIBUSB-UNSUPPORTED-FUNCTION -- which names the
;;; function and the version that introduced it -- instead of dying in SBCL's
;;; undefined-alien handler, which reports an address.

(in-package #:libusb)

(defmacro define-optional-libusb-function ((c-name lisp-name since) return-type
                                           &body args)
  "Bind C-NAME if the loaded libusb exports it, and signal if it does not.

Expands to a function that probes once, memoises the pointer, and calls through
CFFI:FOREIGN-FUNCALL-POINTER. The probe is one hash lookup after the first call,
which is the right trade for an entry point nobody calls in a hot loop."
  (let ((arg-names (mapcar #'first args))
        (arg-types (mapcar #'second args))
        (pointer (gensym "POINTER")))
    `(progn
       (pushnew (cons ,c-name ',lisp-name) *raw-bindings* :test #'equal)
       (defun ,lisp-name ,arg-names
         ,(format nil "~A. Present only in libusb ~A and later; signals~@
                       LIBUSB-UNSUPPORTED-FUNCTION otherwise. Test with~@
                       (FOREIGN-FUNCTION-AVAILABLE-P ~S) to branch instead."
                  c-name since c-name)
         (unless (foreign-function-available-p ,c-name)
           (error 'libusb-unsupported-function :name ,c-name :since ,since))
         (let ((,pointer (cffi:foreign-symbol-pointer ,c-name)))
           (cffi:foreign-funcall-pointer
            ,pointer ()
            ,@(loop for name in arg-names
                    for type in arg-types
                    append (list type name))
            ,return-type))))))

;;; libusb 1.0.30. Answers manufacturer / product / serial without opening the
;;; device at all, which on Linux is the difference between needing write
;;; permission on /dev/bus/usb and not. Worth reaching for when it is there --
;;; see the note in strings.lisp.
(define-optional-libusb-function ("libusb_get_device_string"
                                  %libusb-get-device-string "1.0.30") :int
  (dev :pointer)
  (string-type libusb-device-string-type)
  (data :pointer)
  (length :int))

;;; libusb 1.0.30.
(define-optional-libusb-function ("libusb_get_session_data"
                                  %libusb-get-session-data "1.0.30") :ulong
  (dev :pointer))

;;; libusb 1.0.29: the Windows/Linux raw-I/O fast path.
(define-optional-libusb-function ("libusb_endpoint_supports_raw_io"
                                  %libusb-endpoint-supports-raw-io "1.0.29") :int
  (dev-handle :pointer)
  (endpoint :uint8))

(define-optional-libusb-function ("libusb_endpoint_set_raw_io"
                                  %libusb-endpoint-set-raw-io "1.0.29") :int
  (dev-handle :pointer)
  (endpoint :uint8)
  (enable :int))

(define-optional-libusb-function ("libusb_get_max_raw_io_transfer_size"
                                  %libusb-get-max-raw-io-transfer-size "1.0.29") :int
  (dev-handle :pointer)
  (endpoint :uint8))
