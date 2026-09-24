(in-package #:libusb/tests)
(in-suite libusb-hardware)

;;; Tests that open a device and move bytes. Everything here goes through WITH-CC2531,
;;; which skips by name when the dongle is absent or /dev/bus/usb is not writable, and
;;; which releases and closes on every exit -- FiveAM has no teardown, and a claimed
;;; interface left behind makes the next run fail with LIBUSB_ERROR_BUSY somewhere else
;;; entirely.
;;;
;;; The device is a TI CC2531: one vendor-specific interface, one endpoint -- 0x83, bulk
;;; IN, 64 bytes -- and no kernel driver bound. Idle, it sends nothing, so a read of it
;;; times out. That is not a weak test: a timeout is libusb deciding, inside
;;; libusb_handle_events, to complete a transfer we submitted, and invoking our one
;;; static callback with status TIMED_OUT. Every part of the machinery is exercised
;;; except the bytes themselves.
;;;
;;; Nothing here resets anything, and nothing touches the Bluetooth adapters or the hub
;;; they hang off -- see *FORBIDDEN* in helpers.lisp, which is enforced in code.

(test the-forbidden-devices-really-are-refused
  "The guard itself, tested. It is the only thing standing between a careless edit and
somebody's working Bluetooth, so it gets an assertion rather than a comment."
  (dolist (entry *forbidden*)
    (signals error (assert-touchable (car entry) (cdr entry))))
  (is-true (assert-touchable +cc2531-vendor-id+ +cc2531-product-id+)))

(test an-open-handle-reports-the-device-it-was-opened-on
  "The cheapest possible check that opening worked, and that the wrappers point at each
other correctly."
  (with-cc2531 (handle :claim nil)
    (is-true (libusb:handle-live-p handle))
    (is (= +cc2531-vendor-id+ (libusb:device-vendor-id (libusb:handle-device handle))))
    (is (= +cc2531-product-id+ (libusb:device-product-id (libusb:handle-device handle))))
    (is-true (libusb:context-live-p (libusb:handle-context handle)))))

(test a-control-transfer-reads-the-product-string-off-the-dongle
  "A synchronous control transfer on endpoint 0, all the way to the device and back:
GET_DESCRIPTOR for the string index the device descriptor named. \"CC2531 USB Dongle\"
is what this dongle answers, and asserting the actual text rather than merely
\"something came back\" is what makes this a test of the SETUP packet layout and the
UTF-16 decoding rather than of the plumbing alone."
  (with-cc2531 (handle :claim nil)
    (multiple-value-bind (product reason) (libusb:product handle)
      (is-true product "the dongle would not give up its product string: ~S" reason)
      (when product
        (is (search "CC2531" product) "iProduct was ~S" product)))
    ;; The same string through the raw language-aware path, which decodes UTF-16LE
    ;; properly rather than flattening to ASCII. Both must agree.
    (let ((languages (libusb:string-descriptor-languages handle)))
      (is-true languages "the dongle reports no string languages at all")
      (when languages
        (multiple-value-bind (product reason)
            (libusb:product handle :langid (first languages))
          (is-true product "UTF-16 path failed: ~S" reason)
          (when product (is (search "CC2531" product))))))))

(test a-string-index-of-zero-is-no-string-rather-than-string-zero
  "The CC2531 reports iSerialNumber 0, which in a USB descriptor means the device has no
serial number. Returning NIL for it -- without going near the wire -- is the difference
between a listing loop that works and one that signals on the first device without a
serial."
  (with-cc2531 (handle :claim nil)
    (let ((descriptor (libusb:device-descriptor (libusb:handle-device handle))))
      (if (zerop (libusb:device-descriptor-serial-number-index descriptor))
          (is (null (libusb:serial-number handle))
              "index 0 must give NIL, not an attempt to read string 0")
          (skip "this dongle does report a serial number index, so the index-0 path ~
                 cannot be exercised on it")))))

(test the-active-configuration-matches-what-this-dongle-is-known-to-have
  "One interface, one endpoint, 0x83 bulk IN of 64 bytes. Asserted against the real
device because the descriptor parser is otherwise only tested against descriptors this
suite built itself -- and a parser that agrees with its own fixtures proves less than
one that agrees with hardware."
  (with-cc2531 (handle :claim nil)
    (let ((config (libusb:active-config-descriptor (libusb:handle-device handle))))
      (is-true config)
      (when config
        (is (= 1 (length (libusb:config-descriptor-interfaces config))))
        (let* ((interface (svref (libusb:config-descriptor-interfaces config) 0))
               (alt (svref (libusb:usb-interface-alt-settings interface) 0)))
          (is (eq :vendor-spec (libusb:interface-descriptor-interface-class alt))
              "the CC2531's interface is vendor-specific, which is why no kernel ~
               driver claims it and why this suite may use it")
          (let ((endpoint (libusb:find-endpoint config #x83)))
            (is-true endpoint "endpoint 0x83 is missing from the configuration")
            (when endpoint
              (is (eq :in (libusb:endpoint-descriptor-direction endpoint)))
              (is (eq :bulk (libusb:endpoint-descriptor-transfer-type endpoint)))
              (is (= 64 (libusb:endpoint-descriptor-max-packet-size endpoint))))))))))

(test claiming-an-interface-and-releasing-it-leaves-it-claimable-again
  "Not a formality: an interface left claimed is the failure that makes the *next* run
fail, with an error that points at the wrong place. So it is claimed, released, and
claimed again in one test."
  (with-cc2531 (handle :claim nil)
    (libusb:with-claimed-interface (handle 0)
      (is (member 0 (libusb::device-handle-claimed-interfaces handle))))
    (is (null (libusb::device-handle-claimed-interfaces handle)))
    (finishes (libusb:with-claimed-interface (handle 0) t))))

(test a-claimed-interface-is-released-even-when-the-body-signals
  "The unwind path, which is the one that actually matters -- a test that fails
mid-transfer must not take the interface with it."
  (with-cc2531 (handle :claim nil)
    (signals simple-error
      (libusb:with-claimed-interface (handle 0)
        (error "deliberate")))
    (is (null (libusb::device-handle-claimed-interfaces handle)))
    (finishes (libusb:with-claimed-interface (handle 0) t))))

;;; --- the asynchronous path, against real silicon -----------------------

(test an-async-bulk-read-from-an-idle-dongle-completes-through-the-callback
  "The end-to-end test this whole library is for: submit a transfer, let libusb's event
handling complete it, and have our one static callback find the right Lisp record.

The status is asserted as a set rather than a value. If the dongle has been left running
a sniffer firmware it will deliver a packet instead of timing out, and a suite that
failed for that would be asserting the state of somebody's flash rather than the state
of this library. What is asserted unconditionally is that the callback fired exactly
once and that the record agrees with it."
  (with-cc2531 (handle)
    (libusb:with-event-pump ((libusb:handle-context handle) :tick 0.1)
      (let ((calls 0))
        (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 64
                                         :timeout (round (* 1000 (scaled 0.3)))
                                         :function (lambda (transfer)
                                                     (declare (ignore transfer))
                                                     (incf calls)))
          (let ((start (get-internal-real-time)))
            (libusb:submit-transfer tr)
            (let* ((status (libusb:wait-for-transfer tr :timeout (scaled 5)))
                   (elapsed (/ (- (get-internal-real-time) start)
                               (float internal-time-units-per-second))))
              (is-true status "the completion callback never fired in ~,2F s" elapsed)
              (is (member status '(:timed-out :completed))
                  "unexpected status ~S from an idle bulk IN" status)
              (is (= 1 calls) "the callback fired ~D times, not once" calls)
              (is (eq :done (libusb:transfer-state tr)))
              (when (eq status :timed-out)
                (is (zerop (libusb:transfer-actual-length tr)))
                (is (>= elapsed (* 0.8 (scaled 0.3)))
                    "completed in ~,3F s, sooner than the ~,1F s timeout asked for"
                    elapsed (scaled 0.3))
                (is (<= elapsed (scaled 5))
                    "a 0.3 s timeout took ~,2F s to be enforced" elapsed)))))))))

(test cancelling-an-in-flight-transfer-yields-a-cancelled-callback-and-not-a-lost-one
  "Cancellation is asynchronous: libusb_cancel_transfer only asks, and the callback
still runs. Nothing may be reclaimed until it has -- which is why CANCEL-TRANSFER drains
by default and why freeing an in-flight transfer is refused. A five-second transfer
cancelled after a tenth of a second should come back as :CANCELLED almost immediately."
  (with-cc2531 (handle)
    (libusb:with-event-pump ((libusb:handle-context handle) :tick 0.1)
      (let ((calls 0) (statuses '()))
        (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 64
                                         :timeout (round (* 1000 (scaled 5)))
                                         :function (lambda (transfer)
                                                     (incf calls)
                                                     (push (libusb:transfer-status transfer)
                                                           statuses)))
          (libusb:submit-transfer tr)
          (sleep (scaled 0.1))
          (is (eq :submitted (libusb:transfer-state tr)))
          (let ((start (get-internal-real-time)))
            (libusb:cancel-transfer tr :drain t :timeout (scaled 3))
            (let ((elapsed (/ (- (get-internal-real-time) start)
                              (float internal-time-units-per-second))))
              (is (= 1 calls) "the callback fired ~D times for one cancellation" calls)
              (is (eq :cancelled (libusb:transfer-status tr))
                  "status after cancellation was ~S" (libusb:transfer-status tr))
              (is (equal '(:cancelled) statuses)
                  "the callback saw ~S rather than the cancellation" statuses)
              (is (< elapsed (scaled 2))
                  "the cancellation took ~,2F s, far longer than the request should" 
                  elapsed))))))))

(test a-transfer-can-be-resubmitted-after-it-completes
  "Reusing one transfer -- its struct, its buffer and its registry entry -- is how a
stream is kept running, and it is the case that would break if SUBMIT-TRANSFER reset
the wrong state or the completion flag were not cleared."
  (with-cc2531 (handle)
    (libusb:with-event-pump ((libusb:handle-context handle) :tick 0.1)
      (let ((calls 0))
        (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 64
                                         :timeout (round (* 1000 (scaled 0.2)))
                                         :function (lambda (transfer)
                                                     (declare (ignore transfer))
                                                     (incf calls)))
          (dotimes (round 2)
            (libusb:submit-transfer tr)
            (is-true (libusb:wait-for-transfer tr :timeout (scaled 5))
                     "round ~D never completed" round))
          (is (= 2 calls) "the callback fired ~D times for two submissions" calls)
          (is (= 2 (libusb:transfer-submit-count tr))))))))

(test sixteen-concurrent-transfers-each-get-their-own-completion
  "The demultiplexer against real hardware and a real event thread. Sixteen transfers in
flight at once, all on one endpoint, all completing through one static callback: if the
user_data indexing were wrong under concurrency, this is where a transfer would receive
another transfer's result -- and doing it with one endpoint and identical timeouts makes
that the only thing being tested."
  (with-cc2531 (handle)
    (libusb:with-event-pump ((libusb:handle-context handle) :tick 0.05)
      (let* ((count 16)
             (seen (make-hash-table :test 'eq))
             (lock (bt:make-lock "hw test"))
             (transfers '()))
        (unwind-protect
             (progn
               (dotimes (i count)
                 (let ((tr (libusb:make-usb-transfer
                            handle :type :bulk :endpoint #x83 :length 64
                                   :timeout (round (* 1000 (scaled 0.3)))
                                   :function (lambda (transfer)
                                               (bt:with-lock-held (lock)
                                                 (incf (gethash transfer seen 0)))))))
                   (push tr transfers)))
               (mapc #'libusb:submit-transfer transfers)
               (dolist (tr transfers)
                 (is-true (libusb:wait-for-transfer tr :timeout (scaled 10))
                          "~S never completed" tr))
               (is (= count (hash-table-count seen))
                   "~D of ~D transfers were completed" (hash-table-count seen) count)
               (is (every (lambda (tr) (= 1 (gethash tr seen 0))) transfers)
                   "some transfer was completed more than once, or another's completion ~
                    landed on it")
               (is (every (lambda (tr) (member (libusb:transfer-status tr)
                                               '(:timed-out :completed)))
                          transfers)))
          (dolist (tr transfers)
            (when (eq :submitted (libusb:transfer-state tr))
              (ignore-errors (libusb:cancel-transfer tr :drain t :timeout 2)))
            (ignore-errors (libusb:free-usb-transfer tr))))))))

(test an-async-control-transfer-reads-the-device-descriptor-back-off-the-wire
  "The control path through the asynchronous machinery, which fills a SETUP packet by
hand and lets libusb take the length from it. Asked for the device descriptor because
the answer is known exactly -- eighteen bytes whose idVendor and idProduct must match
the ones enumeration already reported, which makes this a check of the SETUP layout and
not merely of the plumbing."
  (with-cc2531 (handle :claim nil)
    (libusb:with-event-pump ((libusb:handle-context handle) :tick 0.1)
      (let ((length 18))
        (libusb:with-transfer (tr handle :type :control
                                         :length (+ libusb:+control-setup-size+ length)
                                         :timeout (round (* 1000 (scaled 1))))
          ;; bmRequestType 0x80 (IN, standard, device), GET_DESCRIPTOR, DEVICE|index 0.
          (libusb::%libusb-fill-control-setup (libusb:transfer-buffer-pointer tr)
                                             #x80 #x06 #x0100 0 length)
          ;; The fill helper takes the transfer's length from the SETUP packet, so it has
          ;; to be refilled after the SETUP packet is written.
          (libusb::%fill-transfer tr (round (* 1000 (scaled 1))))
          (libusb:submit-transfer tr)
          (is (eq :completed (libusb:wait-for-transfer tr :timeout (scaled 5))))
          (is (= length (libusb:transfer-actual-length tr)))
          (let ((data (libusb:transfer-data tr :all t)))
            ;; Past the 8-byte SETUP packet: bLength, bDescriptorType, then the fields.
            (is (= 18 (aref data libusb:+control-setup-size+))
                "bLength should be 18")
            (is (= 1 (aref data (+ 1 libusb:+control-setup-size+)))
                "bDescriptorType should be 1 (DEVICE)")
            (let ((vendor (logior (aref data (+ 8 libusb:+control-setup-size+))
                                  (ash (aref data (+ 9 libusb:+control-setup-size+)) 8)))
                  (product (logior (aref data (+ 10 libusb:+control-setup-size+))
                                   (ash (aref data (+ 11 libusb:+control-setup-size+)) 8))))
              (is (= +cc2531-vendor-id+ vendor) "idVendor off the wire was ~4,'0X" vendor)
              (is (= +cc2531-product-id+ product)
                  "idProduct off the wire was ~4,'0X" product))))))))

(test a-synchronous-bulk-read-reports-its-timeout-without-signalling
  "libusb's own blocking path, for contrast with the async one above. A timeout here is
not an error: libusb fills in how much arrived before giving up, and a short read plus
:TIMEOUT is more useful to a caller than an unwind that discards the count."
  (with-cc2531 (handle)
    (multiple-value-bind (data status count)
        (libusb:bulk-read handle #x83 64 :timeout (round (* 1000 (scaled 0.2))))
      (is (member status '(:timed-out :timeout :completed))
          "synchronous bulk read gave ~S" status)
      (is (typep data '(vector (unsigned-byte 8))))
      (is (= (length data) count)))))

(test submitting-an-iso-transfer-to-a-bulk-endpoint-fails-cleanly
  "No isochronous hardware is available to this suite, so what can be checked is the
error path: an iso transfer on a bulk endpoint must be refused by libusb or the kernel,
no callback may fire, and the transfer must come back to a state it can be freed from.
A transfer left stuck in :SUBMITTED after a failed submit could never be reclaimed."
  (with-cc2531 (handle)
    (let ((calls 0))
      (libusb:with-transfer (tr handle :type :isochronous :endpoint #x83
                                       :length 192 :num-iso-packets 1
                                       :timeout 100
                                       :function (lambda (transfer)
                                                   (declare (ignore transfer))
                                                   (incf calls)))
        (libusb:set-iso-packet-lengths tr 192)
        (handler-case
            (progn (libusb:submit-transfer tr)
                   ;; Some backends accept the submission and fail it later; either way
                   ;; the transfer has to reach a terminal state, not hang.
                   (libusb:wait-for-transfer tr :timeout (scaled 2))
                   (is (member (libusb:transfer-state tr) '(:done :fresh))))
          (libusb:libusb-error (e)
            (is (member (libusb:error-code-keyword (libusb:libusb-error-code e))
                        '(:error-invalid-param :error-not-found :error-not-supported
                          :error-io))
                "unexpected error from an iso submit on a bulk endpoint: ~A" e)
            (is (eq :fresh (libusb:transfer-state tr))
                "a failed submit must roll the state back so the transfer can be freed")
            (is (zerop calls) "no callback may fire for a submission that failed")))))))
