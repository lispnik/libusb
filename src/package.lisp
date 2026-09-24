;;; The #:libusb package. Two layers, one package.
;;;
;;;   %libusb-*    a 1:1 binding of every exported libusb-1.0 entry point, plus
;;;                the header's static-inline functions rewritten in Lisp.
;;;                Mechanical and complete. Exported rather than internal
;;;                because bulk streams, dev_mem and the BOS/SuperSpeed
;;;                descriptors have no ergonomic wrapper by design, so reaching
;;;                them must not require a double colon.
;;;   everything   the ergonomic layer, whose exports are declared in
;;;   else         src/api-package.lisp and src/closures-package.lisp -- in the
;;;                systems that implement them, so that loading libusb/ffi on
;;;                its own advertises exactly what it provides and no more.
;;;
;;; A wrapper of the same shape as its binding is named without the %: plain
;;; OPEN-DEVICE signals a condition, %LIBUSB-OPEN returns libusb's integer.
;;; Nothing exported under a plain name returns a raw libusb error code.
;;;
;;; Foreign type names keep the C spelling (LIBUSB-DEVICE-DESCRIPTOR,
;;; LIBUSB-TRANSFER, LIBUSB-SPEED) so they grep against libusb.h, and struct
;;; slots transliterate their C field (B-LENGTH, ID-VENDOR, W-MAX-PACKET-SIZE)
;;; so a reader can check them against chapter 9 of the USB specification
;;; without a decoder ring. One deviation: the error enum is
;;; LIBUSB-ERROR-CODE, because LIBUSB-ERROR is the condition class.

(defpackage #:libusb
  (:use #:cl)
  (:documentation "Bindings to libusb-1.0.

The raw layer -- every %LIBUSB- function, the foreign structs and the enums --
is provided by the LIBUSB/FFI system and is complete. The ergonomic layer on
top of it is provided by LIBUSB, and the two callback subsystems that need
runtime-minted closures by LIBUSB/CLOSURES.")
  (:export
   ;; conditions (src/conditions.lisp). The root lives in the raw system so
   ;; that one handler covers both layers.
   #:libusb-error
   #:libusb-api-error
   #:libusb-error-code
   #:libusb-error-function
   #:libusb-error-context
   #:libusb-io-error
   #:libusb-invalid-param
   #:libusb-access-error
   #:libusb-no-device
   #:libusb-not-found
   #:libusb-busy
   #:libusb-timeout
   #:libusb-overflow
   #:libusb-pipe-error
   #:libusb-interrupted
   #:libusb-no-memory
   #:libusb-not-supported
   #:libusb-other-error
   #:libusb-unsupported-function
   #:libusb-unsupported-function-name
   #:libusb-unsupported-function-since
   #:libusb-invalid-object
   #:libusb-usage-error
   #:check-result
   #:error-code-keyword
   #:error-code-message

   ;; library loading (src/library.lisp)
   #:*library-directories*
   #:load-libraries
   #:libraries-loaded-p
   #:foreign-function-available-p
   #:library-version
   #:library-version-string

   ;; enums and bitfields (src/enums.lisp)
   #:libusb-class-code
   #:libusb-descriptor-type
   #:libusb-endpoint-direction
   #:libusb-endpoint-transfer-type
   #:libusb-standard-request
   #:libusb-request-type
   #:libusb-request-recipient
   #:libusb-iso-sync-type
   #:libusb-iso-usage-type
   #:libusb-supported-speed
   #:libusb-usb-2-0-extension-attributes
   #:libusb-ss-usb-device-capability-attributes
   #:libusb-bos-type
   #:libusb-ssplus-sublink-type
   #:libusb-ssplus-sublink-direction
   #:libusb-ssplus-exponent
   #:libusb-ssplus-link-protocol
   #:libusb-speed
   #:libusb-error-code-enum
   #:libusb-transfer-type
   #:libusb-transfer-status
   #:libusb-transfer-flags
   #:libusb-capability
   #:libusb-log-level
   #:libusb-log-cb-mode
   #:libusb-option
   #:libusb-device-string-type
   #:libusb-hotplug-event
   #:libusb-hotplug-events
   #:enum-keyword
   #:+hotplug-enumerate+
   #:+hotplug-no-flags+
   #:+hotplug-match-any+
   #:+control-setup-size+
   #:+device-string-bytes-max+

   ;; foreign structs (src/structs.lisp)
   #:libusb-device-descriptor
   #:libusb-endpoint-descriptor
   #:libusb-interface-descriptor
   #:libusb-interface
   #:libusb-config-descriptor
   #:libusb-control-setup
   #:libusb-version
   #:libusb-iso-packet-descriptor
   #:libusb-transfer
   #:libusb-pollfd
   #:libusb-init-option
   #:libusb-init-option-value
   #:libusb-ss-endpoint-companion-descriptor
   #:libusb-bos-dev-capability-descriptor
   #:libusb-bos-descriptor
   #:libusb-usb-2-0-extension-descriptor
   #:libusb-ss-usb-device-capability-descriptor
   #:libusb-ssplus-sublink-attribute
   #:libusb-ssplus-usb-device-capability-descriptor
   #:libusb-container-id-descriptor
   #:libusb-platform-descriptor
   #:libusb-interface-association-descriptor
   #:libusb-interface-association-descriptor-array
   #:timeval
   #:transfer-iso-packet-descriptor
   #:+transfer-iso-packet-desc-offset+

   ;; raw bindings, in header order (src/ffi.lisp)
   #:%libusb-init
   #:%libusb-init-context
   #:%libusb-exit
   #:%libusb-set-debug
   #:%libusb-set-log-cb
   #:%libusb-get-version
   #:%libusb-has-capability
   #:%libusb-error-name
   #:%libusb-setlocale
   #:%libusb-strerror
   #:%libusb-get-device-list
   #:%libusb-free-device-list
   #:%libusb-ref-device
   #:%libusb-unref-device
   #:%libusb-get-device-string
   #:%libusb-get-configuration
   #:%libusb-get-device-descriptor
   #:%libusb-get-active-config-descriptor
   #:%libusb-get-config-descriptor
   #:%libusb-get-config-descriptor-by-value
   #:%libusb-free-config-descriptor
   #:%libusb-get-ss-endpoint-companion-descriptor
   #:%libusb-free-ss-endpoint-companion-descriptor
   #:%libusb-get-bos-descriptor
   #:%libusb-free-bos-descriptor
   #:%libusb-get-usb-2-0-extension-descriptor
   #:%libusb-free-usb-2-0-extension-descriptor
   #:%libusb-get-ss-usb-device-capability-descriptor
   #:%libusb-free-ss-usb-device-capability-descriptor
   #:%libusb-get-ssplus-usb-device-capability-descriptor
   #:%libusb-free-ssplus-usb-device-capability-descriptor
   #:%libusb-get-container-id-descriptor
   #:%libusb-free-container-id-descriptor
   #:%libusb-get-platform-descriptor
   #:%libusb-free-platform-descriptor
   #:%libusb-get-session-data
   #:%libusb-get-bus-number
   #:%libusb-get-port-number
   #:%libusb-get-port-numbers
   #:%libusb-get-port-path
   #:%libusb-get-parent
   #:%libusb-get-device-address
   #:%libusb-get-device-speed
   #:%libusb-get-max-packet-size
   #:%libusb-get-max-iso-packet-size
   #:%libusb-get-max-alt-packet-size
   #:%libusb-get-interface-association-descriptors
   #:%libusb-get-active-interface-association-descriptors
   #:%libusb-free-interface-association-descriptors
   #:%libusb-wrap-sys-device
   #:%libusb-open
   #:%libusb-close
   #:%libusb-get-device
   #:%libusb-set-configuration
   #:%libusb-claim-interface
   #:%libusb-release-interface
   #:%libusb-open-device-with-vid-pid
   #:%libusb-set-interface-alt-setting
   #:%libusb-clear-halt
   #:%libusb-reset-device
   #:%libusb-alloc-streams
   #:%libusb-free-streams
   #:%libusb-dev-mem-alloc
   #:%libusb-dev-mem-free
   #:%libusb-kernel-driver-active
   #:%libusb-detach-kernel-driver
   #:%libusb-attach-kernel-driver
   #:%libusb-set-auto-detach-kernel-driver
   #:%libusb-endpoint-supports-raw-io
   #:%libusb-endpoint-set-raw-io
   #:%libusb-get-max-raw-io-transfer-size
   #:%libusb-alloc-transfer
   #:%libusb-submit-transfer
   #:%libusb-cancel-transfer
   #:%libusb-free-transfer
   #:%libusb-transfer-set-stream-id
   #:%libusb-transfer-get-stream-id
   #:%libusb-control-transfer
   #:%libusb-bulk-transfer
   #:%libusb-interrupt-transfer
   #:%libusb-get-string-descriptor-ascii
   #:%libusb-try-lock-events
   #:%libusb-lock-events
   #:%libusb-unlock-events
   #:%libusb-event-handling-ok
   #:%libusb-event-handler-active
   #:%libusb-interrupt-event-handler
   #:%libusb-lock-event-waiters
   #:%libusb-unlock-event-waiters
   #:%libusb-wait-for-event
   #:%libusb-handle-events-timeout
   #:%libusb-handle-events-timeout-completed
   #:%libusb-handle-events
   #:%libusb-handle-events-completed
   #:%libusb-handle-events-locked
   #:%libusb-pollfds-handle-timeouts
   #:%libusb-get-next-timeout
   #:%libusb-get-pollfds
   #:%libusb-free-pollfds
   #:%libusb-set-pollfd-notifiers
   #:%libusb-hotplug-register-callback
   #:%libusb-hotplug-deregister-callback
   #:%libusb-hotplug-get-user-data
   #:%libusb-set-option

   ;; the header's static inlines, reimplemented in Lisp (src/inline.lisp)
   #:%libusb-cpu-to-le16
   #:%libusb-le16-to-cpu
   #:%libusb-fill-control-setup
   #:%libusb-fill-control-transfer
   #:%libusb-fill-bulk-transfer
   #:%libusb-fill-bulk-stream-transfer
   #:%libusb-fill-interrupt-transfer
   #:%libusb-fill-iso-transfer
   #:%libusb-set-iso-packet-lengths
   #:%libusb-get-iso-packet-buffer
   #:%libusb-get-iso-packet-buffer-simple
   #:%libusb-control-transfer-get-data
   #:%libusb-control-transfer-get-setup
   #:%libusb-get-descriptor
   #:%libusb-get-string-descriptor
   #:*raw-bindings*))

(in-package #:libusb)
