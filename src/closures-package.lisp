;;; Exports of the libusb/closures system.
;;;
;;; Separate from src/api-package.lisp for the same reason that system is separate
;;; from libusb/ffi's: loading libusb without cffi-callback-closures should not
;;; advertise a hotplug registrar that cannot be built.

(in-package #:libusb)

(export
 '(;; hotplug
   hotplug-registration
   hotplug-registration-p
   hotplug-registration-live-p
   register-hotplug-callback
   deregister-hotplug-callback
   live-hotplug-registration-count

   ;; logging
   set-log-callback
   clear-log-callback
   log-messages
   drain-log-messages
   print-log-message
   live-log-sink-count

   ;; teardown and images
   shutdown-all
   live-closure-count))
