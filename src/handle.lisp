;;; Device handles: opening a device, and everything that needs one open.
;;;
;;; An open handle is a claim on the device for the whole machine, not merely a
;;; file descriptor in this process. On Linux it holds the /dev/bus/usb node open
;;; and, with a kernel driver detached, leaves the device bound to nothing at all.
;;; Leaking one takes the device away from whatever was using it until this
;;; process exits, which is why every acquisition in this file has a WITH- macro
;;; beside it in src/with.lisp and why CLOSE-DEVICE-HANDLE reattaches drivers it
;;; detached.

(in-package #:libusb)

(defstruct (device-handle (:constructor %make-device-handle (pointer device context epoch))
                          (:predicate device-handle-p)
                          (:copier nil)
                          (:print-object print-device-handle))
  (pointer (cffi:null-pointer))
  device
  context
  (epoch 0 :type fixnum)
  (live t)
  (claimed-interfaces '())
  ;; Interfaces whose kernel driver WE detached, so CLOSE-DEVICE-HANDLE can put
  ;; it back. libusb_close does not: with LIBUSB_OPTION auto-detach it reattaches,
  ;; but a driver detached explicitly stays detached, and a keyboard that stops
  ;; working until reboot is a poor way to learn that.
  (detached-interfaces '()))

(defun print-device-handle (handle stream)
  (print-unreadable-object (handle stream :type t)
    (if (device-handle-live handle)
        (format stream "~A~@[ claiming ~{~D~^,~}~]"
                (device-handle-device handle)
                (device-handle-claimed-interfaces handle))
        (format stream "closed"))))

(defun handle-live-p (handle)
  "True if HANDLE is open and belongs to this image."
  (and (device-handle-p handle)
       (device-handle-live handle)
       (= (device-handle-epoch handle) *image-epoch*)
       (context-live-p (device-handle-context handle))))

(defun handle-pointer (handle)
  "HANDLE's libusb_device_handle *. Signals if HANDLE is closed."
  (check-handle handle 'handle-pointer)
  (device-handle-pointer handle))

(defun handle-device (handle)
  "The DEVICE that HANDLE was opened on."
  (device-handle-device handle))

(defun handle-context (handle)
  "The CONTEXT that HANDLE belongs to."
  (device-handle-context handle))

(defun check-handle (handle &optional operation)
  (unless (device-handle-p handle)
    (usage-error "~S is not a libusb device handle." handle))
  (unless (and (device-handle-live handle)
               (context-live (device-handle-context handle)))
    (error 'libusb-invalid-object :object handle :operation operation))
  (unless (= (device-handle-epoch handle) *image-epoch*)
    (error 'libusb-stale-object :object handle :operation operation))
  handle)

;;; --- opening and closing -----------------------------------------------

(defun open-device (device &key auto-detach-kernel-driver)
  "Open DEVICE and return a DEVICE-HANDLE.

On Linux this needs read/write permission on the device's /dev/bus/usb node,
which is root-owned by default; failure arrives as LIBUSB-ACCESS-ERROR, and it is
worth catching by name, because it means a udev rule or a sudo and nothing about
the device.

AUTO-DETACH-KERNEL-DRIVER asks libusb to unbind and rebind the kernel driver
around each CLAIM-INTERFACE / RELEASE-INTERFACE. Convenient and abrupt: it takes
the device away from the kernel for as long as the interface is claimed."
  (check-device device 'open-device)
  (let ((context (device-context device)))
    (cffi:with-foreign-object (holder :pointer)
      (check-result (%libusb-open (device-pointer device) holder)
                    '%libusb-open
                    (format nil "~A" device))
      (let ((handle (%make-device-handle (cffi:mem-ref holder :pointer)
                                         device context *image-epoch*)))
        (when auto-detach-kernel-driver
          (set-auto-detach-kernel-driver handle t))
        (bt:with-lock-held ((context-lock context))
          (push handle (context-handles context)))
        handle))))

(defun wrap-sys-device (context fd)
  "Wrap an already-open platform file descriptor FD as a DEVICE-HANDLE.

The Android idiom: an application that was handed a usbfs descriptor by the
system, and has no permission to enumerate at all, opens it this way. Pair it with
OPEN-CONTEXT's :NO-DEVICE-DISCOVERY."
  (check-context context 'wrap-sys-device)
  (cffi:with-foreign-object (holder :pointer)
    (check-result (%libusb-wrap-sys-device (context-pointer context) fd holder)
                  '%libusb-wrap-sys-device)
    (let ((handle (%make-device-handle (cffi:mem-ref holder :pointer)
                                       nil context *image-epoch*)))
      (bt:with-lock-held ((context-lock context)) (push handle (context-handles context)))
      handle)))

(defun close-device-handle (handle)
  "Release everything HANDLE holds and close it. Idempotent.

Releases claimed interfaces and reattaches kernel drivers we detached, then
closes. Each step is guarded: a device unplugged while claimed makes the release
fail with LIBUSB_ERROR_NO_DEVICE, and that must not stop the close."
  (when (and (device-handle-p handle) (device-handle-live handle))
    (let ((pointer (device-handle-pointer handle))
          (context (device-handle-context handle)))
      (dolist (interface (copy-list (device-handle-claimed-interfaces handle)))
        (ignore-errors (release-interface handle interface)))
      (dolist (interface (copy-list (device-handle-detached-interfaces handle)))
        (ignore-errors (attach-kernel-driver handle interface)))
      (setf (device-handle-live handle) nil
            (device-handle-pointer handle) (cffi:null-pointer))
      (unless (cffi:null-pointer-p pointer)
        (%libusb-close pointer))
      (when (context-live context)
        (bt:with-lock-held ((context-lock context))
          (setf (context-handles context)
                (remove handle (context-handles context)))))))
  (values))

;;; Step 50: after transfers are cancelled, drained and freed, and after the
;;; event pump has stopped -- a handle closed under an in-flight transfer is a
;;; use-after-free inside libusb.
(register-context-teardown
 50 (lambda (context)
      (dolist (handle (copy-list (context-handles context)))
        (ignore-errors (close-device-handle handle)))
      (setf (context-handles context) '())))

;;; --- configurations and interfaces -------------------------------------

(defun configuration (handle)
  "The bConfigurationValue of HANDLE's device's active configuration, or NIL.

NIL means unconfigured, which libusb reports as 0 -- a value that is not a legal
configuration number, so it is translated rather than passed on."
  (check-handle handle 'configuration)
  (cffi:with-foreign-object (value :int)
    (check-result (%libusb-get-configuration (handle-pointer handle) value)
                  '%libusb-get-configuration)
    (let ((v (cffi:mem-ref value :int)))
      (unless (zerop v) v))))

(defun set-configuration (handle configuration)
  "Activate CONFIGURATION on HANDLE's device, or NIL to leave it unconfigured.

Cannot be done while any interface is claimed, and libusb will say so with
LIBUSB_ERROR_BUSY. Most devices have exactly one configuration and never need
this."
  (check-handle handle 'set-configuration)
  (check-result (%libusb-set-configuration (handle-pointer handle)
                                           (or configuration -1))
                '%libusb-set-configuration)
  configuration)

(defun claim-interface (handle interface)
  "Claim INTERFACE on HANDLE. Required before any transfer on its endpoints.

LIBUSB-BUSY here means a kernel driver or another process holds the interface;
see DETACH-KERNEL-DRIVER and OPEN-DEVICE's :AUTO-DETACH-KERNEL-DRIVER."
  (check-handle handle 'claim-interface)
  (check-result (%libusb-claim-interface (handle-pointer handle) interface)
                '%libusb-claim-interface
                (format nil "interface ~D" interface))
  (pushnew interface (device-handle-claimed-interfaces handle))
  interface)

(defun release-interface (handle interface)
  "Release INTERFACE on HANDLE, letting its kernel driver back in."
  (check-handle handle 'release-interface)
  (unwind-protect
       (check-result (%libusb-release-interface (handle-pointer handle) interface)
                     '%libusb-release-interface
                     (format nil "interface ~D" interface))
    ;; Forgotten even if the release failed. If libusb could not release it, it
    ;; is not ours any more either -- the usual cause is the device being gone --
    ;; and retrying on close would only fail again.
    (setf (device-handle-claimed-interfaces handle)
          (remove interface (device-handle-claimed-interfaces handle))))
  interface)

(defun set-interface-alt-setting (handle interface alt-setting)
  "Select ALT-SETTING on INTERFACE, which must already be claimed."
  (check-handle handle 'set-interface-alt-setting)
  (check-result (%libusb-set-interface-alt-setting (handle-pointer handle)
                                                   interface alt-setting)
                '%libusb-set-interface-alt-setting)
  alt-setting)

(defun clear-halt (handle endpoint)
  "Clear a stall condition on ENDPOINT.

A stalled endpoint answers every transfer with LIBUSB-PIPE-ERROR until this is
called; it is the device's way of reporting a protocol error, not a transport
fault, so the usual recovery is to clear the halt and resynchronise."
  (check-handle handle 'clear-halt)
  (check-result (%libusb-clear-halt (handle-pointer handle) endpoint)
                '%libusb-clear-halt
                (format nil "endpoint #x~2,'0X" endpoint))
  (values))

(defun reset-device (handle)
  "Reset HANDLE's device by re-enumerating it.

Disruptive in a way worth spelling out: every other process's handle on this
device is invalidated, a hub's downstream devices all drop, and if the device
comes back with a different descriptor libusb returns LIBUSB_ERROR_NOT_FOUND and
HANDLE is dead -- reopen from a fresh LIST-DEVICES."
  (check-handle handle 'reset-device)
  (check-result (%libusb-reset-device (handle-pointer handle)) '%libusb-reset-device)
  (values))

;;; --- kernel drivers ----------------------------------------------------

(defun kernel-driver-active-p (handle interface)
  "True if a kernel driver has claimed INTERFACE.

Returns NIL rather than signalling on a platform that cannot answer
(LIBUSB_ERROR_NOT_SUPPORTED, which is every non-Linux backend): \"no kernel
driver is in the way\" is the right answer for a caller deciding whether to
detach one."
  (check-handle handle 'kernel-driver-active-p)
  (let ((rc (%libusb-kernel-driver-active (handle-pointer handle) interface)))
    (case rc
      (0 nil)
      (1 t)
      (-12 nil)                         ; LIBUSB_ERROR_NOT_SUPPORTED
      (t (check-result rc '%libusb-kernel-driver-active) nil))))

(defun detach-kernel-driver (handle interface)
  "Unbind the kernel driver from INTERFACE, if one is bound. Returns T if it was.

NIL and no error when nothing was attached: detaching a driver that is not there
is success by another name. The interface is remembered so CLOSE-DEVICE-HANDLE can
put the driver back."
  (check-handle handle 'detach-kernel-driver)
  (let ((rc (%libusb-detach-kernel-driver (handle-pointer handle) interface)))
    (case rc
      (0 (pushnew interface (device-handle-detached-interfaces handle)) t)
      (-5 nil)                          ; LIBUSB_ERROR_NOT_FOUND: nothing bound
      (t (check-result rc '%libusb-detach-kernel-driver
                       (format nil "interface ~D" interface))
         t))))

(defun attach-kernel-driver (handle interface)
  "Rebind the kernel driver to INTERFACE. Returns T if a driver took it."
  (check-handle handle 'attach-kernel-driver)
  (let ((rc (%libusb-attach-kernel-driver (handle-pointer handle) interface)))
    (setf (device-handle-detached-interfaces handle)
          (remove interface (device-handle-detached-interfaces handle)))
    (case rc
      (0 t)
      ((-5 -6) nil)                     ; nothing to attach, or still claimed
      (t (check-result rc '%libusb-attach-kernel-driver) t))))

(defun set-auto-detach-kernel-driver (handle enable)
  "Have libusb detach and reattach kernel drivers around claim and release.

Unsupported outside Linux, where it returns LIBUSB_ERROR_NOT_SUPPORTED; that is
passed through rather than swallowed, because a caller who asked for this and did
not get it is about to fail at CLAIM-INTERFACE for a reason that will look
unrelated."
  (check-handle handle 'set-auto-detach-kernel-driver)
  (check-result (%libusb-set-auto-detach-kernel-driver (handle-pointer handle)
                                                        (if enable 1 0))
                '%libusb-set-auto-detach-kernel-driver)
  enable)
