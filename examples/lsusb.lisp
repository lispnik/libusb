;;; A listing of everything on the bus, and one real transfer.
;;;
;;; Run it with:
;;;
;;;   sbcl --noinform --non-interactive --no-userinit --no-sysinit \
;;;     --eval '(require :asdf)' \
;;;     --eval '(asdf:initialize-source-registry `(:source-registry (:tree ,(truename "./")) (:directory ,(truename "../cffi-callback-closures/")) :ignore-inherited-configuration))' \
;;;     --eval '(asdf:load-system :libusb/closures)' --load examples/lsusb.lisp
;;;
;;; Enumeration needs no permissions on Linux. Reading a string descriptor does, because
;;; it means opening the device, so those lines are blank as an ordinary user and filled
;;; in under sudo.

(in-package #:libusb)

(defun endpoint-line (endpoint)
  (format nil "~2,'0X/~(~A~)/~(~A~)/~D"
          (endpoint-descriptor-address endpoint)
          (endpoint-descriptor-direction endpoint)
          (endpoint-descriptor-transfer-type endpoint)
          (endpoint-descriptor-max-packet-size endpoint)))

(defun describe-device (device)
  (let ((descriptor (device-descriptor device)))
    (format t "~&Bus ~3,'0D Device ~3,'0D: ~4,'0X:~4,'0X  USB ~A, ~(~A~), class ~S~%"
            (device-bus-number device) (device-address device)
            (device-descriptor-vendor-id descriptor)
            (device-descriptor-product-id descriptor)
            (bcd-version-string (device-descriptor-usb-version descriptor))
            (device-speed device)
            (device-descriptor-device-class descriptor))
    ;; Strings need an open handle, which needs write access to the device node. Denied
    ;; is the ordinary answer for an unprivileged process, and not worth a backtrace.
    (handler-case
        (with-device-handle (handle device)
          (format t "    ~@[~A~]~@[ ~A~]~@[ (serial ~A)~]~%"
                  (manufacturer handle) (product handle) (serial-number handle)))
      (libusb-access-error () (format t "    (no permission to open)~%"))
      (libusb-error (e) (format t "    (~A)~%" (error-code-message
                                                (libusb-error-code e)))))
    (let ((config (active-config-descriptor device)))
      (when config
        (loop for interface across (config-descriptor-interfaces config)
              do (loop for alt across (usb-interface-alt-settings interface)
                       do (format t "    interface ~D alt ~D class ~S~@[: ~{~A~^ ~}~]~%"
                                  (interface-descriptor-number alt)
                                  (interface-descriptor-alt-setting alt)
                                  (interface-descriptor-interface-class alt)
                                  (map 'list #'endpoint-line
                                       (interface-descriptor-endpoints alt)))))))))

(with-context (context)
  (format t "~&libusb ~A, hotplug ~:[unsupported~;supported~]~%~%"
          (version-string) (has-capability-p :has-hotplug))
  (with-device-list (devices :context context)
    (mapc #'describe-device devices)

    ;; Hotplug, without unplugging anything: LIBUSB_HOTPLUG_ENUMERATE makes libusb call
    ;; the callback synchronously, once per attached device, before registration returns.
    (let ((arrivals 0))
      (let ((registration (register-hotplug-callback
                           context
                           (lambda (device event registration)
                             (declare (ignore event registration))
                             (incf arrivals)
                             (unref-device device)
                             nil)
                           :events '(:device-arrived) :enumerate t)))
        (format t "~%hotplug ENUMERATE: ~D arrival~:P for ~D device~:P~%"
                arrivals (length devices))
        (deregister-hotplug-callback registration)))

    ;; And one real asynchronous transfer, if the CC2531 is here and openable. An idle
    ;; dongle sends nothing, so this times out -- which is libusb completing a transfer
    ;; we submitted and calling back into Lisp, and is the whole machinery working.
    (let ((dongle (find-device :context context :vendor-id #x0451 :product-id #x16ae)))
      (when dongle
        (handler-case
            (with-device-handle (handle dongle)
              (with-claimed-interface (handle 0)
                (with-event-pump (context)
                  (let ((start (get-internal-real-time)))
                    (multiple-value-bind (data status) (bulk-in handle #x83 64 :timeout 300)
                      (format t "~%bulk IN 0x83, 64 bytes, 300 ms timeout: ~S after ~
                                 ~,3F s, ~D byte~:P~%"
                              status
                              (/ (- (get-internal-real-time) start)
                                 (float internal-time-units-per-second))
                              (length data)))))))
          (libusb-access-error ()
            (format t "~%bulk IN: no permission to open the CC2531; try under sudo~%")))
        (unref-device dongle)))))
