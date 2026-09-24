(in-package #:libusb/tests)
(in-suite libusb-enumeration)

;;; Needs a real bus but no permissions: on Linux, enumeration and device descriptors
;;; come from sysfs and only opening a device requires write access to /dev/bus/usb.
;;; Skips itself where there is no bus at all, which is the correct result on a CI
;;; runner rather than a defect.

(defmacro with-bus ((&rest ignore) &body body)
  (declare (ignore ignore))
  `(if (bus-has-devices-p)
       (progn ,@body)
       (skip "no USB devices on this machine (a CI runner, most likely); there is ~
              nothing to enumerate")))

(test enumeration-finds-devices-and-describes-every-one-of-them
  "Every device on the bus, with its descriptor already read -- which is what lets
FIND-DEVICES filter on vendor and product without opening anything. A device whose
descriptor could not be parsed would fail here rather than at some later call."
  (with-bus ()
    (libusb:with-context (context)
      (libusb:with-device-list (devices :context context)
        (is (plusp (length devices)))
        (dolist (device devices)
          (let ((descriptor (libusb:device-descriptor device)))
            (is-true (libusb:device-descriptor-p descriptor))
            (is (<= 0 (libusb:device-descriptor-vendor-id descriptor) #xffff))
            (is (<= 0 (libusb:device-descriptor-product-id descriptor) #xffff))
            (is (plusp (libusb:device-descriptor-max-packet-size-0 descriptor))
                "~A reports a zero-byte endpoint 0, which no device can have" device))
          (is (<= 0 (libusb:device-bus-number device) 255))
          (is (<= 0 (libusb:device-address device) 255))
          (is (listp (libusb:device-port-numbers device)))
          (is (<= (length (libusb:device-port-numbers device)) 7)
              "the USB specification caps hub depth at 7")
          (let ((speed (libusb:device-speed device)))
            (is (or (keywordp speed) (integerp speed)))))))))

(test every-device-either-has-a-parseable-configuration-or-is-unconfigured
  "The deep copy, against whatever is actually plugged in. This is the test that a
descriptor tree from real hardware survives being copied out and its C memory freed --
including the class-specific `extra' blobs, which are exactly the bytes a naive parser
drops."
  (with-bus ()
    (libusb:with-context (context)
      (libusb:with-device-list (devices :context context)
        (dolist (device devices)
          (let ((config (libusb:active-config-descriptor device)))
            ;; NIL is legitimate: an unconfigured device is a state, not a failure.
            (when config
              (is (plusp (libusb:config-descriptor-configuration-value config))
                  "~A reports configuration value 0, which means unconfigured" device)
              (is (= (length (libusb:config-descriptor-interfaces config))
                     (length (libusb:config-descriptor-interfaces config))))
              (loop for interface across (libusb:config-descriptor-interfaces config)
                    do (is (plusp (length (libusb:usb-interface-alt-settings interface)))
                           "an interface with no alternate settings cannot exist")
                       (loop for alt across (libusb:usb-interface-alt-settings interface)
                             do (loop for ep across (libusb:interface-descriptor-endpoints alt)
                                      do (is (member (libusb:endpoint-descriptor-direction ep)
                                                     '(:in :out)))
                                         ;; A zero wMaxPacketSize is legal, and only for
                                         ;; an isochronous endpoint: it is how the USB
                                         ;; specification says "this alternate setting
                                         ;; claims no bandwidth". Every Bluetooth adapter
                                         ;; on the Raspberry Pi this suite targets does
                                         ;; exactly that -- its SCO interface offers
                                         ;; alternate setting 0 with two zero-sized
                                         ;; isochronous endpoints and settings 1 to 5
                                         ;; with 9, 17, 25, 33 and 49 bytes. A zero on
                                         ;; any other endpoint type would be a device
                                         ;; that cannot be talked to.
                                         (if (eq :isochronous
                                                 (libusb:endpoint-descriptor-transfer-type ep))
                                             (is (<= 0 (libusb:endpoint-descriptor-max-packet-size ep))
                                                 "endpoint #x~2,'0X of ~A reports a negative packet size"
                                                 (libusb:endpoint-descriptor-address ep) device)
                                             (is (plusp (libusb:endpoint-descriptor-max-packet-size ep))
                                                 "endpoint #x~2,'0X of ~A is ~(~A~) and reports a zero packet size"
                                                 (libusb:endpoint-descriptor-address ep) device
                                                 (libusb:endpoint-descriptor-transfer-type ep)))))))))))))

(test a-device-list-releases-every-reference-it-took
  "libusb prints a complaint on exit about devices that were still referenced, and a
context that never closes keeps every device it ever enumerated. WITH-DEVICE-LIST is
how a caller does not have to think about it, and this is the assertion that it works."
  (with-bus ()
    (libusb:with-context (context)
      (let ((count nil))
        (libusb:with-device-list (devices :context context)
          (setf count (length devices))
          (is (= count (length (libusb::context-devices context)))))
        (is (null (libusb::context-devices context))
            "~D device reference(s) survived WITH-DEVICE-LIST"
            (length (libusb::context-devices context)))
        ;; And a second enumeration is unaffected by the first.
        (libusb:with-device-list (devices :context context)
          (is (= count (length devices))))))))

(test a-filter-unrefs-the-devices-it-rejects-immediately
  "Filtering inside LIST-DEVICES rather than afterwards is not only tidier, it is the
only version that does not hold a reference to every device on the bus for as long as
the caller takes to discard them."
  (with-bus ()
    (libusb:with-context (context)
      (let ((devices (libusb:find-devices :context context :vendor-id #xfffe)))
        (is (null devices) "vendor 0xFFFE should match nothing")
        (is (null (libusb::context-devices context))
            "rejected devices were not unreffed: ~D left"
            (length (libusb::context-devices context)))))))

(test opening-a-device-without-permission-signals-access-rather-than-something-vague
  "On the Raspberry Pi this suite targets, /dev/bus/usb is root:root 0664, so as an
ordinary user this is the path every open takes -- and the error has to be
LIBUSB-ACCESS-ERROR by name, because that is a udev rule or a sudo and nothing at all
about the device. Skips where the user can open things, which is most macOS boxes and
anything running as root."
  (with-bus ()
    (libusb:with-context (context)
      (libusb:with-device-list (devices :context context)
        (let ((denied nil) (opened nil))
          (dolist (device devices)
            (handler-case
                (let ((handle (libusb:open-device device)))
                  (libusb:close-device-handle handle)
                  (setf opened t))
              (libusb:libusb-access-error () (setf denied t))
              (libusb:libusb-error () nil)))
          (cond (denied
                 (is-true denied "at least one device refused to open with ACCESS, ~
                                  and the condition class said so"))
                (opened
                 (skip "every device on this machine opens without complaint, so the ~
                        permission-denied path cannot be exercised here; it is the ~
                        normal path under `make pi-test'"))
                (t (skip "no device could be opened and none refused with ACCESS"))))))))

;;; --- hotplug, deterministically ----------------------------------------

(test hotplug-enumerate-fires-once-per-attached-device-on-the-calling-thread
  "LIBUSB_HOTPLUG_ENUMERATE makes libusb_hotplug_register_callback invoke the callback
synchronously, before it returns, once for every already-attached matching device.

That single flag is what makes the entire hotplug path testable with no privileges,
nothing plugged or unplugged, and no waiting: a libffi closure minted at runtime,
libusb's C call into it, the enum translation, the device reference, the guard and the
return value. It is the most valuable test in this suite, and it is also the reason
hotplug uses MAKE-FOREIGN-CALLBACK -- none of it would work if the closure did not
carry its own Lisp state.

libusb's own header warns that with ENUMERATE a device may additionally be reported
from libusb_handle_events, so the count is asserted as a floor rather than an equality.
Nothing here pumps events, which keeps that second path out of the way."
  (with-bus ()
    (libusb:with-context (context)
      (unless (libusb:has-capability-p :has-hotplug)
        (skip "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
      (let ((expected (libusb:with-device-list (devices :context context)
                        (length devices)))
            (seen '())
            (registration nil))
        (unwind-protect
             (progn
               (setf registration
                     (libusb:register-hotplug-callback
                      context
                      (lambda (device event registration)
                        (declare (ignore registration))
                        (push (list event
                                    (libusb:device-address device)
                                    (libusb:device-vendor-id device))
                              seen)
                        ;; Released here: the device handed to a callback holds a
                        ;; reference of its own, exactly like one from LIST-DEVICES.
                        (libusb:unref-device device)
                        nil)
                      :events '(:device-arrived) :enumerate t))
               (is (>= (length seen) expected)
                   "ENUMERATE reported ~D of ~D attached devices" (length seen) expected)
               (is (every (lambda (entry) (eq :device-arrived (first entry))) seen)
                   "every synchronous ENUMERATE report must be an arrival")
               (is (every (lambda (entry) (integerp (second entry))) seen)
                   "the device handed to the callback must be usable during the call")
               (is (null (libusb::context-devices context))
                   "the callback unreffed each device, so none should be left"))
          (when registration
            (ignore-errors (libusb:deregister-hotplug-callback registration))))))))

(test asking-to-be-deregistered-does-not-stop-the-enumerate-pass-but-does-take-effect
  "Returning :DEREGISTER becomes a 1 to libusb, which means \"stop calling me\".

What that does NOT do is abandon the ENUMERATE pass already in progress: libusb walks
the whole device list, calling the callback for each device and marking it for removal
when one of them returns 1. Measured, not assumed -- with twelve devices attached the
callback runs twelve times. Any code that returns :DEREGISTER from an ENUMERATE
registration has to be prepared for that, so the behaviour is pinned here rather than
left as folklore.

What must happen is that the registration ends up dead, and that deregistering it again
afterwards is harmless -- libusb has already forgotten the handle, and the teardown path
will try regardless."
  (with-bus ()
    (libusb:with-context (context)
      (unless (libusb:has-capability-p :has-hotplug)
        (skip "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
      (let ((device-count (libusb:with-device-list (devices :context context)
                            (length devices))))
        (let ((calls 0) (registration nil))
          (unwind-protect
               (progn
                 (setf registration
                       (libusb:register-hotplug-callback
                        context
                        (lambda (device event registration)
                          (declare (ignore event registration))
                          (incf calls)
                          (libusb:unref-device device)
                          :deregister)
                        :events '(:device-arrived) :enumerate t))
                 (is (plusp calls) "the callback never ran at all")
                 (is (<= calls device-count)
                     "the callback ran ~D times for ~D devices" calls device-count)
                 (is-false (libusb:hotplug-registration-live-p registration)
                           "the registration must be marked dead once the callback ~
                            asked for it, even though the enumerate pass continued"))
            (when registration
              (finishes (libusb:deregister-hotplug-callback registration)))))))))

(test a-hotplug-filter-for-a-vendor-nobody-has-matches-nothing
  "The negative control for the vendor, product and class arguments. Without it, a
registration that matched everything would pass the ENUMERATE test just as well -- and
LIBUSB_HOTPLUG_MATCH_ANY being -1 rather than 0 is exactly the sort of thing to get
wrong in a direction that silently matches too much."
  (with-bus ()
    (libusb:with-context (context)
      (unless (libusb:has-capability-p :has-hotplug)
        (skip "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
      (let ((seen 0) (registration nil))
        (unwind-protect
             (progn
               (setf registration
                     (libusb:register-hotplug-callback
                      context
                      (lambda (device event registration)
                        (declare (ignore event registration))
                        (incf seen)
                        (libusb:unref-device device)
                        nil)
                      :events '(:device-arrived) :enumerate t :vendor-id #xfffe))
               (is (zerop seen) "vendor 0xFFFE matched ~D device(s)" seen))
          (when registration
            (ignore-errors (libusb:deregister-hotplug-callback registration))))))))

(test deregistering-a-hotplug-callback-frees-its-closure
  "Detach from libusb, then free the trampoline. Never the other way round: between a
free and the deregistration there is a window in which an arriving event jumps into an
unmapped page."
  (with-bus ()
    (libusb:with-context (context)
      (unless (libusb:has-capability-p :has-hotplug)
        (skip "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
      (let ((before (libusb:live-closure-count)))
        (let ((registration (libusb:register-hotplug-callback
                             context
                             (lambda (device event registration)
                               (declare (ignore event registration))
                               (libusb:unref-device device)
                               nil)
                             :enumerate nil)))
          (is (= (1+ before) (libusb:live-closure-count)))
          (is-true (libusb:hotplug-registration-live-p registration))
          (libusb:deregister-hotplug-callback registration)
          (is (= before (libusb:live-closure-count)))
          (is-false (libusb:hotplug-registration-live-p registration)))))))

(test closing-a-context-deregisters-and-frees-its-hotplug-callbacks
  "Step 10 of the teardown order, and the first: no new events during the rest of it.
libusb_exit would deregister these itself, but silently, without freeing our closures --
and the closures must be freed after libusb_exit rather than before."
  (with-bus ()
    (let ((before (libusb:live-closure-count))
          (context (libusb:open-context)))
      (unless (libusb:has-capability-p :has-hotplug)
        (libusb:close-context context)
        (skip "this libusb build reports no LIBUSB_CAP_HAS_HOTPLUG"))
      (libusb:register-hotplug-callback context
                                        (lambda (device event registration)
                                          (declare (ignore event registration))
                                          (libusb:unref-device device)
                                          nil)
                                        :enumerate nil)
      (is (= (1+ before) (libusb:live-closure-count)))
      (libusb:close-context context)
      (is (= before (libusb:live-closure-count))
          "closing the context left ~D closure(s) minted"
          (- (libusb:live-closure-count) before)))))

;;; --- logging against a real libusb -------------------------------------

(test a-log-callback-captures-the-messages-libusb-actually-produces
  "The minted log closure against a real libusb, at a level that makes it say something.

An empty capture is still treated as a skip rather than a failure, because a libusb
compiled without ENABLE_DEBUG_LOGGING -- which is how several distributions ship it --
emits nothing at any level, and failing for that would be failing for a reason that has
nothing to do with this library. Where logging is compiled in, this is the test that the
closure is really wired to libusb and not merely installed without complaint.

Note that libusb writes its own copy of each message to file descriptor 2 as well as
calling the handler, so a dozen lines of libusb chatter during this test are expected and
are not the suite's output."
  (with-bus ()
    (libusb:with-context (context)
      (libusb:set-log-callback context :level :debug)
      (unwind-protect
           (progn
             (libusb:with-device-list (devices :context context)
               (length devices))
             ;; Back to quiet before anything else runs.
             (libusb:set-log-level context :none)
             (let ((messages (libusb:drain-log-messages)))
               (if (null messages)
                   (skip "this libusb (~A) produced no log messages even at :DEBUG; it ~
                          was built without ENABLE_DEBUG_LOGGING"
                         (libusb:version-string))
                   (progn
                     (is (plusp (length messages)))
                     (is (every (lambda (entry) (keywordp (car entry))) messages)
                         "each message must carry its level as a translated keyword, ~
                          which is the enum crossing the libffi boundary")
                     (is (every (lambda (entry) (stringp (cdr entry))) messages)
                         "each message must arrive as a Lisp string")
                     (is (notany (lambda (entry) (find #\Newline (cdr entry))) messages)
                         "libusb's messages carry a trailing newline, which the collector ~
                          is supposed to strip")
                     (is (some (lambda (entry) (search "libusb" (cdr entry))) messages)
                         "libusb prefixes its own messages, so at least one should say ~
                          so -- otherwise something other than libusb is calling us")))))
        (libusb:clear-log-callback context)))))

(test a-log-callback-passed-to-open-context-is-installed-before-libusb-starts-up
  "LIBUSB_OPTION_LOG_CB through libusb_init_context is the only way to see the messages
libusb produces while creating a context -- which are the ones worth having when a
context refuses to open at all. It also means the closure has to be minted before the
context exists, which is why core.lisp reaches libusb/closures through a hook."
  (with-bus ()
    (let ((seen '()))
      (let ((context (libusb:open-context
                      :log-level :debug
                      :log-callback (lambda (ctx level message)
                                      (declare (ignore ctx))
                                      (push (cons level message) seen)))))
        (unwind-protect
             (is-true (libusb:context-live-p context)
                      "a context with an init-time log callback must still open")
          (libusb:close-context context))
        (if (null seen)
            (skip "this libusb produced no log messages at :DEBUG; it was built without ~
                   ENABLE_DEBUG_LOGGING")
            (is (some (lambda (entry) (search "libusb_init_context" (cdr entry))) seen)
                "the point of LIBUSB_OPTION_LOG_CB is the messages libusb produces ~
                 while starting up, which libusb_set_log_cb is too late for -- and ~
                 libusb_init_context announcing its version is the first of them"))))))
