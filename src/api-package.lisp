;;; The ergonomic layer's exports.
;;;
;;; Declared here rather than in src/package.lisp so that libusb/ffi exports
;;; exactly the symbols it implements. Loading the raw bindings on a machine
;;; that has no libusb should not advertise a device enumerator that cannot run
;;; there.

(in-package #:libusb)

(export
 '(;; contexts
   context
   contextp
   context-live-p
   context-pointer
   open-context
   close-context
   default-context
   *context*
   with-context
   set-log-level
   has-capability-p
   version
   version-string
   error-name
   strerror
   setlocale
   live-context-count

   ;; devices
   device
   devicep
   device-live-p
   list-devices
   with-device-list
   find-devices
   find-device
   unref-device
   device-context
   device-bus-number
   device-address
   device-port-number
   device-port-numbers
   device-speed
   device-parent
   device-descriptor
   device-vendor-id
   device-product-id
   device-max-packet-size
   device-max-iso-packet-size
   device-max-alt-packet-size
   active-config-descriptor
   config-descriptor-of

   ;; descriptors, as Lisp values (src/descriptors.lisp)
   device-descriptor-usb-version
   device-descriptor-device-class
   device-descriptor-device-subclass
   device-descriptor-device-protocol
   device-descriptor-max-packet-size-0
   device-descriptor-vendor-id
   device-descriptor-product-id
   device-descriptor-device-version
   device-descriptor-manufacturer-index
   device-descriptor-product-index
   device-descriptor-serial-number-index
   device-descriptor-configuration-count
   device-descriptor-p
   make-device-descriptor
   config-descriptor
   config-descriptor-p
   make-config-descriptor
   config-descriptor-configuration-value
   config-descriptor-configuration-index
   config-descriptor-total-length
   config-descriptor-attributes
   config-descriptor-self-powered-p
   config-descriptor-remote-wakeup-p
   config-descriptor-max-power-ma
   config-descriptor-interfaces
   config-descriptor-extra
   usb-interface
   usb-interface-p
   make-usb-interface
   usb-interface-alt-settings
   interface-descriptor
   interface-descriptor-p
   make-interface-descriptor
   interface-descriptor-number
   interface-descriptor-alt-setting
   interface-descriptor-interface-class
   interface-descriptor-interface-subclass
   interface-descriptor-interface-protocol
   interface-descriptor-interface-index
   interface-descriptor-endpoints
   interface-descriptor-extra
   endpoint-descriptor
   endpoint-descriptor-p
   make-endpoint-descriptor
   endpoint-descriptor-address
   endpoint-descriptor-number
   endpoint-descriptor-direction
   endpoint-descriptor-transfer-type
   endpoint-descriptor-sync-type
   endpoint-descriptor-usage-type
   endpoint-descriptor-max-packet-size
   endpoint-descriptor-interval
   endpoint-descriptor-refresh
   endpoint-descriptor-synch-address
   endpoint-descriptor-extra
   bcd-version-string
   find-endpoint

   ;; device handles
   device-handle
   device-handle-p
   handle-live-p
   handle-device
   handle-context
   handle-pointer
   open-device
   close-device-handle
   wrap-sys-device
   with-device-handle
   with-open-device
   configuration
   set-configuration
   claim-interface
   release-interface
   with-claimed-interface
   set-interface-alt-setting
   clear-halt
   reset-device
   kernel-driver-active-p
   detach-kernel-driver
   attach-kernel-driver
   with-detached-kernel-driver
   set-auto-detach-kernel-driver

   ;; string descriptors
   device-string
   string-descriptor-languages
   manufacturer
   product
   serial-number

   ;; synchronous transfers
   *default-timeout*
   control-transfer
   bulk-read
   bulk-write
   interrupt-read
   interrupt-write
   request-type

   ;; asynchronous transfers
   transfer
   transferp
   make-usb-transfer
   free-usb-transfer
   submit-transfer
   cancel-transfer
   wait-for-transfer
   with-transfer
   transfer-state
   transfer-status
   transfer-actual-length
   transfer-data
   transfer-write-data
   transfer-buffer-pointer
   transfer-callback-error
   transfer-submit-count
   transfer-live-p
   live-transfer-count
   bulk-in
   bulk-out
   interrupt-in
   interrupt-out
   set-iso-packet-lengths
   iso-packet-descriptor
   iso-packet-buffer
   transfer-stream-id
   alloc-streams
   free-streams
   dev-mem-alloc
   dev-mem-free

   ;; callbacks in general
   *callback-error-hook*
   with-callback-guard
   libusb-stale-object
   image-epoch

   ;; event handling
   handle-events
   context-event-mode
   start-event-pump
   stop-event-pump
   event-pump-running-p
   with-event-pump
   interrupt-event-handler
   event-handler-active-p
   next-timeout
   pollfds
   pollfds-handle-timeouts-p
   set-pollfd-notifiers
   libusb-event-pump-stuck
   libusb-transfer-state-error))
