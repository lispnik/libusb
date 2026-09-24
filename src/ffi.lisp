;;; The raw bindings: one DEFCFUN per exported libusb-1.0 entry point, in the
;;; order libusb.h declares them.
;;;
;;; Three rules hold throughout, and the reasons are worth having in front of
;;; you while reading:
;;;
;;;   - Nothing here signals. Every one of these returns exactly what C
;;;     returned, including negative error codes. CHECK-RESULT, called by the
;;;     ergonomic layer, is the single place that convention is interpreted.
;;;   - Anything a *device* reports is bound as :INT rather than as an enum.
;;;     CFFI's enum translation signals on an unknown value, and a device
;;;     reporting a speed or class this libusb has never heard of must not break
;;;     enumeration for the rest of the bus. See the note atop enums.lisp.
;;;   - Callback-typed parameters are :POINTER. Who mints the pointer, and
;;;     whether it is one static callback or a libffi closure, is a decision for
;;;     the layers above; the binding has no opinion.
;;;
;;; The five entry points added in libusb 1.0.29 and 1.0.30 are NOT here -- they
;;; are in ffi-optional.lisp behind a runtime symbol probe, because this same
;;; fasl has to run against 1.0.28 on a Raspberry Pi.

(in-package #:libusb)

(defvar *raw-bindings* '()
  "An alist of (C-NAME . LISP-SYMBOL) for every binding in this file.

Populated by DEFINE-LIBUSB-FUNCTION as a side effect of defining them. Its
purpose is tests/symbol-tests.lisp, which walks this list and probes each name
with CFFI:FOREIGN-SYMBOL-POINTER: the test reports what the installed libusb
actually exports rather than asserting a count, because 1.0.28 and 1.0.30 do not
export the same set and a binding that is merely absent is not a bug.")

(defmacro define-libusb-function ((c-name lisp-name) return-type &body args)
  "DEFCFUN against the libusb library, recorded in *RAW-BINDINGS*."
  ;; The registration is load-time only: *RAW-BINDINGS* is read at run time by
  ;; the symbol-probe test and by nothing at compile time, and a DEFVAR's value
  ;; does not exist in the compilation environment.
  `(progn
     (pushnew (cons ,c-name ',lisp-name) *raw-bindings* :test #'equal)
     (cffi:defcfun (,c-name ,lisp-name :library libusb) ,return-type ,@args)))

;;; --- library initialisation and description ----------------------------

(define-libusb-function ("libusb_init" %libusb-init) :int
  (ctx :pointer))                       ; libusb_context **

(define-libusb-function ("libusb_init_context" %libusb-init-context) :int
  (ctx :pointer)                        ; libusb_context **
  (options :pointer)                    ; const struct libusb_init_option []
  (num-options :int))

(define-libusb-function ("libusb_exit" %libusb-exit) :void
  (ctx :pointer))

;;; Deprecated in favour of libusb_set_option, and bound anyway: it is still
;;; exported, a consumer's existing code may call it, and a binding that omits
;;; what the library exports is not a complete binding.
(define-libusb-function ("libusb_set_debug" %libusb-set-debug) :void
  (ctx :pointer)
  (level :int))

(define-libusb-function ("libusb_set_log_cb" %libusb-set-log-cb) :void
  (ctx :pointer)
  (cb :pointer)                         ; libusb_log_cb -- no user_data; see logging.lisp
  (mode :int))

(define-libusb-function ("libusb_get_version" %libusb-get-version) :pointer)

(define-libusb-function ("libusb_has_capability" %libusb-has-capability) :int
  (capability :uint32))

(define-libusb-function ("libusb_error_name" %libusb-error-name) :string
  (error-code :int))

(define-libusb-function ("libusb_setlocale" %libusb-setlocale) :int
  (locale :string))

(define-libusb-function ("libusb_strerror" %libusb-strerror) :string
  (errcode :int))

;;; --- device enumeration ------------------------------------------------

(define-libusb-function ("libusb_get_device_list" %libusb-get-device-list) :ssize
  (ctx :pointer)
  (list :pointer))                      ; libusb_device ***

(define-libusb-function ("libusb_free_device_list" %libusb-free-device-list) :void
  (list :pointer)
  (unref-devices :int))

(define-libusb-function ("libusb_ref_device" %libusb-ref-device) :pointer
  (dev :pointer))

(define-libusb-function ("libusb_unref_device" %libusb-unref-device) :void
  (dev :pointer))

;;; --- descriptors -------------------------------------------------------

(define-libusb-function ("libusb_get_configuration" %libusb-get-configuration) :int
  (dev-handle :pointer)
  (config :pointer))                    ; int *

(define-libusb-function ("libusb_get_device_descriptor" %libusb-get-device-descriptor) :int
  (dev :pointer)
  (desc :pointer))                      ; struct libusb_device_descriptor *

(define-libusb-function ("libusb_get_active_config_descriptor"
                         %libusb-get-active-config-descriptor) :int
  (dev :pointer)
  (config :pointer))                    ; struct libusb_config_descriptor **

(define-libusb-function ("libusb_get_config_descriptor" %libusb-get-config-descriptor) :int
  (dev :pointer)
  (config-index :uint8)
  (config :pointer))

(define-libusb-function ("libusb_get_config_descriptor_by_value"
                         %libusb-get-config-descriptor-by-value) :int
  (dev :pointer)
  (b-configuration-value :uint8)
  (config :pointer))

(define-libusb-function ("libusb_free_config_descriptor" %libusb-free-config-descriptor) :void
  (config :pointer))

(define-libusb-function ("libusb_get_ss_endpoint_companion_descriptor"
                         %libusb-get-ss-endpoint-companion-descriptor) :int
  (ctx :pointer)
  (endpoint :pointer)
  (ep-comp :pointer))

(define-libusb-function ("libusb_free_ss_endpoint_companion_descriptor"
                         %libusb-free-ss-endpoint-companion-descriptor) :void
  (ep-comp :pointer))

(define-libusb-function ("libusb_get_bos_descriptor" %libusb-get-bos-descriptor) :int
  (dev-handle :pointer)
  (bos :pointer))

(define-libusb-function ("libusb_free_bos_descriptor" %libusb-free-bos-descriptor) :void
  (bos :pointer))

(define-libusb-function ("libusb_get_usb_2_0_extension_descriptor"
                         %libusb-get-usb-2-0-extension-descriptor) :int
  (ctx :pointer)
  (dev-cap :pointer)
  (usb-2-0-extension :pointer))

(define-libusb-function ("libusb_free_usb_2_0_extension_descriptor"
                         %libusb-free-usb-2-0-extension-descriptor) :void
  (usb-2-0-extension :pointer))

(define-libusb-function ("libusb_get_ss_usb_device_capability_descriptor"
                         %libusb-get-ss-usb-device-capability-descriptor) :int
  (ctx :pointer)
  (dev-cap :pointer)
  (ss-usb-device-cap :pointer))

(define-libusb-function ("libusb_free_ss_usb_device_capability_descriptor"
                         %libusb-free-ss-usb-device-capability-descriptor) :void
  (ss-usb-device-cap :pointer))

(define-libusb-function ("libusb_get_ssplus_usb_device_capability_descriptor"
                         %libusb-get-ssplus-usb-device-capability-descriptor) :int
  (ctx :pointer)
  (dev-cap :pointer)
  (ssplus-usb-device-cap :pointer))

(define-libusb-function ("libusb_free_ssplus_usb_device_capability_descriptor"
                         %libusb-free-ssplus-usb-device-capability-descriptor) :void
  (ssplus-usb-device-cap :pointer))

(define-libusb-function ("libusb_get_container_id_descriptor"
                         %libusb-get-container-id-descriptor) :int
  (ctx :pointer)
  (dev-cap :pointer)
  (container-id :pointer))

(define-libusb-function ("libusb_free_container_id_descriptor"
                         %libusb-free-container-id-descriptor) :void
  (container-id :pointer))

(define-libusb-function ("libusb_get_platform_descriptor"
                         %libusb-get-platform-descriptor) :int
  (ctx :pointer)
  (dev-cap :pointer)
  (platform-descriptor :pointer))

(define-libusb-function ("libusb_free_platform_descriptor"
                         %libusb-free-platform-descriptor) :void
  (platform-descriptor :pointer))

;;; --- device topology and properties ------------------------------------

(define-libusb-function ("libusb_get_bus_number" %libusb-get-bus-number) :uint8
  (dev :pointer))

(define-libusb-function ("libusb_get_port_number" %libusb-get-port-number) :uint8
  (dev :pointer))

(define-libusb-function ("libusb_get_port_numbers" %libusb-get-port-numbers) :int
  (dev :pointer)
  (port-numbers :pointer)               ; uint8_t *
  (port-numbers-len :int))

;;; LIBUSB_DEPRECATED_FOR(libusb_get_port_numbers), and bound for the same
;;; reason as libusb_set_debug: it is exported, so it is bound.
(define-libusb-function ("libusb_get_port_path" %libusb-get-port-path) :int
  (ctx :pointer)
  (dev :pointer)
  (path :pointer)
  (path-length :uint8))

(define-libusb-function ("libusb_get_parent" %libusb-get-parent) :pointer
  (dev :pointer))

(define-libusb-function ("libusb_get_device_address" %libusb-get-device-address) :uint8
  (dev :pointer))

;;; :INT, not LIBUSB-SPEED: a future speed we have no keyword for must arrive as
;;; an integer rather than signal.
(define-libusb-function ("libusb_get_device_speed" %libusb-get-device-speed) :int
  (dev :pointer))

(define-libusb-function ("libusb_get_max_packet_size" %libusb-get-max-packet-size) :int
  (dev :pointer)
  (endpoint :uchar))

(define-libusb-function ("libusb_get_max_iso_packet_size"
                         %libusb-get-max-iso-packet-size) :int
  (dev :pointer)
  (endpoint :uchar))

(define-libusb-function ("libusb_get_max_alt_packet_size"
                         %libusb-get-max-alt-packet-size) :int
  (dev :pointer)
  (interface-number :int)
  (alternate-setting :int)
  (endpoint :uchar))

(define-libusb-function ("libusb_get_interface_association_descriptors"
                         %libusb-get-interface-association-descriptors) :int
  (dev :pointer)
  (config-index :uint8)
  (iad-array :pointer))

(define-libusb-function ("libusb_get_active_interface_association_descriptors"
                         %libusb-get-active-interface-association-descriptors) :int
  (dev :pointer)
  (iad-array :pointer))

(define-libusb-function ("libusb_free_interface_association_descriptors"
                         %libusb-free-interface-association-descriptors) :void
  (iad-array :pointer))

;;; --- device handles ----------------------------------------------------

(define-libusb-function ("libusb_wrap_sys_device" %libusb-wrap-sys-device) :int
  (ctx :pointer)
  (sys-dev :intptr)
  (dev-handle :pointer))

(define-libusb-function ("libusb_open" %libusb-open) :int
  (dev :pointer)
  (dev-handle :pointer))                ; libusb_device_handle **

(define-libusb-function ("libusb_close" %libusb-close) :void
  (dev-handle :pointer))

(define-libusb-function ("libusb_get_device" %libusb-get-device) :pointer
  (dev-handle :pointer))

(define-libusb-function ("libusb_set_configuration" %libusb-set-configuration) :int
  (dev-handle :pointer)
  (configuration :int))

(define-libusb-function ("libusb_claim_interface" %libusb-claim-interface) :int
  (dev-handle :pointer)
  (interface-number :int))

(define-libusb-function ("libusb_release_interface" %libusb-release-interface) :int
  (dev-handle :pointer)
  (interface-number :int))

;;; Returns NULL on failure with no indication of why, which is why the
;;; ergonomic layer composes FIND-DEVICES and OPEN-DEVICE instead of calling
;;; this: it cannot tell "not plugged in" from "no permission".
(define-libusb-function ("libusb_open_device_with_vid_pid"
                         %libusb-open-device-with-vid-pid) :pointer
  (ctx :pointer)
  (vendor-id :uint16)
  (product-id :uint16))

(define-libusb-function ("libusb_set_interface_alt_setting"
                         %libusb-set-interface-alt-setting) :int
  (dev-handle :pointer)
  (interface-number :int)
  (alternate-setting :int))

(define-libusb-function ("libusb_clear_halt" %libusb-clear-halt) :int
  (dev-handle :pointer)
  (endpoint :uchar))

(define-libusb-function ("libusb_reset_device" %libusb-reset-device) :int
  (dev-handle :pointer))

;;; --- bulk streams and device memory ------------------------------------

(define-libusb-function ("libusb_alloc_streams" %libusb-alloc-streams) :int
  (dev-handle :pointer)
  (num-streams :uint32)
  (endpoints :pointer)
  (num-endpoints :int))

(define-libusb-function ("libusb_free_streams" %libusb-free-streams) :int
  (dev-handle :pointer)
  (endpoints :pointer)
  (num-endpoints :int))

;;; Returns an mmap'd, DMA-capable buffer on Linux and NULL everywhere else.
;;; A buffer from here must never be freed with free() -- so never combine it
;;; with LIBUSB_TRANSFER_FREE_BUFFER; see MAKE-USB-TRANSFER.
(define-libusb-function ("libusb_dev_mem_alloc" %libusb-dev-mem-alloc) :pointer
  (dev-handle :pointer)
  (length :size))

(define-libusb-function ("libusb_dev_mem_free" %libusb-dev-mem-free) :int
  (dev-handle :pointer)
  (buffer :pointer)
  (length :size))

;;; --- kernel drivers ----------------------------------------------------

(define-libusb-function ("libusb_kernel_driver_active" %libusb-kernel-driver-active) :int
  (dev-handle :pointer)
  (interface-number :int))

(define-libusb-function ("libusb_detach_kernel_driver" %libusb-detach-kernel-driver) :int
  (dev-handle :pointer)
  (interface-number :int))

(define-libusb-function ("libusb_attach_kernel_driver" %libusb-attach-kernel-driver) :int
  (dev-handle :pointer)
  (interface-number :int))

(define-libusb-function ("libusb_set_auto_detach_kernel_driver"
                         %libusb-set-auto-detach-kernel-driver) :int
  (dev-handle :pointer)
  (enable :int))

;;; --- asynchronous transfers --------------------------------------------

(define-libusb-function ("libusb_alloc_transfer" %libusb-alloc-transfer) :pointer
  (iso-packets :int))

(define-libusb-function ("libusb_submit_transfer" %libusb-submit-transfer) :int
  (transfer :pointer))

(define-libusb-function ("libusb_cancel_transfer" %libusb-cancel-transfer) :int
  (transfer :pointer))

(define-libusb-function ("libusb_free_transfer" %libusb-free-transfer) :void
  (transfer :pointer))

(define-libusb-function ("libusb_transfer_set_stream_id"
                         %libusb-transfer-set-stream-id) :void
  (transfer :pointer)
  (stream-id :uint32))

(define-libusb-function ("libusb_transfer_get_stream_id"
                         %libusb-transfer-get-stream-id) :uint32
  (transfer :pointer))

;;; --- synchronous transfers ---------------------------------------------

(define-libusb-function ("libusb_control_transfer" %libusb-control-transfer) :int
  (dev-handle :pointer)
  (bm-request-type :uint8)
  (b-request :uint8)
  (w-value :uint16)
  (w-index :uint16)
  (data :pointer)
  (w-length :uint16)
  (timeout :uint))

(define-libusb-function ("libusb_bulk_transfer" %libusb-bulk-transfer) :int
  (dev-handle :pointer)
  (endpoint :uchar)
  (data :pointer)
  (length :int)
  (transferred :pointer)                ; int *
  (timeout :uint))

(define-libusb-function ("libusb_interrupt_transfer" %libusb-interrupt-transfer) :int
  (dev-handle :pointer)
  (endpoint :uchar)
  (data :pointer)
  (length :int)
  (transferred :pointer)
  (timeout :uint))

(define-libusb-function ("libusb_get_string_descriptor_ascii"
                         %libusb-get-string-descriptor-ascii) :int
  (dev-handle :pointer)
  (desc-index :uint8)
  (data :pointer)
  (length :int))

;;; --- polling and timing ------------------------------------------------

(define-libusb-function ("libusb_try_lock_events" %libusb-try-lock-events) :int
  (ctx :pointer))

(define-libusb-function ("libusb_lock_events" %libusb-lock-events) :void
  (ctx :pointer))

(define-libusb-function ("libusb_unlock_events" %libusb-unlock-events) :void
  (ctx :pointer))

(define-libusb-function ("libusb_event_handling_ok" %libusb-event-handling-ok) :int
  (ctx :pointer))

(define-libusb-function ("libusb_event_handler_active" %libusb-event-handler-active) :int
  (ctx :pointer))

(define-libusb-function ("libusb_interrupt_event_handler"
                         %libusb-interrupt-event-handler) :void
  (ctx :pointer))

(define-libusb-function ("libusb_lock_event_waiters" %libusb-lock-event-waiters) :void
  (ctx :pointer))

(define-libusb-function ("libusb_unlock_event_waiters" %libusb-unlock-event-waiters) :void
  (ctx :pointer))

(define-libusb-function ("libusb_wait_for_event" %libusb-wait-for-event) :int
  (ctx :pointer)
  (tv :pointer))

(define-libusb-function ("libusb_handle_events_timeout"
                         %libusb-handle-events-timeout) :int
  (ctx :pointer)
  (tv :pointer))

(define-libusb-function ("libusb_handle_events_timeout_completed"
                         %libusb-handle-events-timeout-completed) :int
  (ctx :pointer)
  (tv :pointer)
  (completed :pointer))                 ; int *

(define-libusb-function ("libusb_handle_events" %libusb-handle-events) :int
  (ctx :pointer))

(define-libusb-function ("libusb_handle_events_completed"
                         %libusb-handle-events-completed) :int
  (ctx :pointer)
  (completed :pointer))

(define-libusb-function ("libusb_handle_events_locked"
                         %libusb-handle-events-locked) :int
  (ctx :pointer)
  (tv :pointer))

;;; Returns 0 on macOS, which is exactly why this library does not build an
;;; external poll loop: a caller integrating libusb's fds into their own event
;;; loop must, on a platform that answers 0 here, also drive
;;; libusb_get_next_timeout and enforce transfer timeouts themselves.
(define-libusb-function ("libusb_pollfds_handle_timeouts"
                         %libusb-pollfds-handle-timeouts) :int
  (ctx :pointer))

(define-libusb-function ("libusb_get_next_timeout" %libusb-get-next-timeout) :int
  (ctx :pointer)
  (tv :pointer))

(define-libusb-function ("libusb_get_pollfds" %libusb-get-pollfds) :pointer
  (ctx :pointer))

(define-libusb-function ("libusb_free_pollfds" %libusb-free-pollfds) :void
  (pollfds :pointer))

(define-libusb-function ("libusb_set_pollfd_notifiers"
                         %libusb-set-pollfd-notifiers) :void
  (ctx :pointer)
  (added-cb :pointer)
  (removed-cb :pointer)
  (user-data :pointer))

;;; --- hotplug -----------------------------------------------------------

(define-libusb-function ("libusb_hotplug_register_callback"
                         %libusb-hotplug-register-callback) :int
  (ctx :pointer)
  (events :int)
  (flags :int)
  (vendor-id :int)
  (product-id :int)
  (dev-class :int)
  (cb-fn :pointer)
  (user-data :pointer)
  (callback-handle :pointer))           ; libusb_hotplug_callback_handle * (int *)

(define-libusb-function ("libusb_hotplug_deregister_callback"
                         %libusb-hotplug-deregister-callback) :void
  (ctx :pointer)
  (callback-handle :int))

(define-libusb-function ("libusb_hotplug_get_user_data"
                         %libusb-hotplug-get-user-data) :pointer
  (ctx :pointer)
  (callback-handle :int))

;;; --- options -----------------------------------------------------------

;;; libusb_set_option is LIBUSB_CALLV -- variadic -- so it cannot be a DEFCFUN;
;;; CFFI needs to know the trailing argument's type at the call site. The arity
;;; is explicit rather than always passing something, because LIBUSB_OPTION_USE_
;;; USBDK and LIBUSB_OPTION_NO_DEVICE_DISCOVERY read no argument at all, and
;;; passing one where C reads none is not harmless on every ABI.
(defun %libusb-set-option (ctx option &optional (value nil valuep))
  "libusb_set_option. OPTION is a LIBUSB-OPTION keyword or its integer value.

BEWARE: this mis-passes its variadic argument on Apple arm64, and nothing here can fix
it. Apple's arm64 ABI puts variadic arguments on the stack while ordinary ones go in
registers, and neither CFFI's FOREIGN-FUNCALL nor SBCL's alien interface can express
that distinction -- so the callee reads a register nobody wrote.

Measured, with a C probe of two functions differing only in whether the callee is
variadic, called identically from Lisp:

                              macOS arm64      Linux aarch64
  probe_nonvariadic(7, 42)    42               42
  probe_variadic(7, 42)       1795794752       42
  set_option(LOG_LEVEL, 2)    -2 from Lisp,    0 from Lisp,
                              0 from C         0 from C

So libusb accepts the option; on Darwin the value simply never arrives. Linux x86-64 is
untested here and expected to behave like Linux aarch64, both passing variadic arguments
in registers.

So nothing in this library calls it. Use libusb_init_context with an option array for
anything settable at init -- that takes a struct, not varargs -- %LIBUSB-SET-DEBUG for
the log level afterwards, and %LIBUSB-SET-LOG-CB for a log callback. It is bound
because libusb exports it and a complete binding binds what the library exports."
  (load-libraries)
  (let ((opt (if (keywordp option)
                 (cffi:foreign-enum-value 'libusb-option option)
                 option)))
    (cond ((not valuep)
           (cffi:foreign-funcall "libusb_set_option"
                                 :pointer ctx :int opt :int))
          ((cffi:pointerp value)
           ;; LIBUSB_OPTION_LOG_CB takes a libusb_log_cb.
           (cffi:foreign-funcall "libusb_set_option"
                                 :pointer ctx :int opt :pointer value :int))
          ((keywordp value)
           ;; LIBUSB_OPTION_LOG_LEVEL, as a LIBUSB-LOG-LEVEL keyword.
           (cffi:foreign-funcall "libusb_set_option"
                                 :pointer ctx :int opt
                                 :int (cffi:foreign-enum-value 'libusb-log-level value)
                                 :int))
          (t
           (cffi:foreign-funcall "libusb_set_option"
                                 :pointer ctx :int opt :int value :int)))))

(pushnew (cons "libusb_set_option" '%libusb-set-option) *raw-bindings* :test #'equal)

;;; --- the version of the library we are actually loaded against ---------

(defun library-version ()
  "The loaded libusb's version, as (VALUES MAJOR MINOR MICRO NANO RC DESCRIBE).

Read from libusb_get_version rather than from a compile-time constant, because
nothing here is compiled against a header: this same fasl runs against 1.0.30 on
one machine and 1.0.28 on another, and version-dependent behaviour has to ask."
  (load-libraries)
  (let ((p (%libusb-get-version)))
    (when (cffi:null-pointer-p p)
      (error 'libusb-other-error :code -99 :function '%libusb-get-version))
    (cffi:with-foreign-slots ((major minor micro nano rc describe)
                              p (:struct libusb-version))
      (values major minor micro nano rc describe))))

(defun library-version-string ()
  "The loaded libusb's version as a string, e.g. \"1.0.30.11908\"."
  (multiple-value-bind (major minor micro nano rc) (library-version)
    (format nil "~D.~D.~D.~D~@[~A~]" major minor micro nano
            (and rc (plusp (length rc)) rc))))
