(in-package #:libusb/tests)
(in-suite libusb-callbacks)

;;; libusb calls our completion callback with one argument, a
;;; struct libusb_transfer *. Nothing stops us calling it the same way -- and that is
;;; what makes this tier exhaustive on a machine with no USB devices at all: fill the
;;; struct as the kernel would have, invoke the real entry point through its own
;;; function pointer, and assert on the Lisp side of the bridge. No permissions, no
;;; hardware, no timing.

(defun invoke-completion (transfer &key (status :timed-out) (actual 0))
  "Do to TRANSFER's struct what libusb does on completion, then call our dispatcher."
  (let ((p (libusb::transfer-pointer transfer)))
    (setf (cffi:foreign-slot-value p '(:struct libusb::libusb-transfer) 'libusb::status)
          status
          (cffi:foreign-slot-value p '(:struct libusb::libusb-transfer)
                                   'libusb::actual-length)
          actual)
    (cffi:foreign-funcall-pointer
     (cffi:callback libusb::%transfer-complete) () :pointer p :void)))

(defun transfer-user-data-index (transfer)
  (cffi:pointer-address
   (cffi:foreign-slot-value (libusb::transfer-pointer transfer)
                            '(:struct libusb::libusb-transfer) 'libusb::user-data)))

;;; --- the demultiplexer -------------------------------------------------

(test a-transfers-registry-index-reaches-the-c-struct-user-data-field
  "The whole scheme rests on this one assignment. If the index did not reach
user_data, every completion would arrive as \"unknown transfer\" -- and index 0 is
reserved for \"not ours\", so it must never be handed out."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8)
      (is (plusp (libusb::transfer-index tr)) "index 0 is reserved for 'not ours'")
      (is (= (libusb::transfer-index tr) (transfer-user-data-index tr))))))

(test the-dispatcher-finds-the-right-transfer-out-of-a-thousand
  "The reason for one static callback plus an integer in user_data, rather than a
libffi closure per transfer, is that the demultiplex is exact and costs nothing. If
the index arithmetic were ever wrong the symptom would be one transfer's bytes
delivered to another transfer's waiter: silent, rare, and indistinguishable from a
device misbehaving. So: a thousand live transfers, completed in shuffled order, each
landing in exactly its own record."
  (with-fake-handle (handle)
    (let ((transfers (loop repeat 1000
                           collect (libusb:make-usb-transfer handle :type :bulk
                                                                    :endpoint #x83
                                                                    :length 8))))
      (unwind-protect
           (let ((order (shuffled transfers)))
             (loop for tr across order
                   for n from 1
                   do (invoke-completion tr :status :completed :actual (mod n 9)))
             (is (every (lambda (tr) (eq :done (libusb:transfer-state tr))) transfers))
             (let ((wrong (loop for tr across order
                                for n from 1
                                unless (= (mod n 9) (libusb:transfer-actual-length tr))
                                  collect (libusb::transfer-index tr))))
               (is (null wrong)
                   "~D transfer(s) received another transfer's actual_length: ~S"
                   (length wrong) wrong)))
        (mapc #'libusb:free-usb-transfer transfers)))))

(test the-dispatcher-ignores-a-completion-that-is-not-ours
  "Another library sharing this context, or a struct somebody else filled: user_data
is zero or unknown, and the only safe thing to do is nothing. Reading further from a
struct whose owner we cannot identify is how a binding corrupts a neighbour."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8)
      (setf (cffi:foreign-slot-value (libusb::transfer-pointer tr)
                                     '(:struct libusb::libusb-transfer)
                                     'libusb::user-data)
            (cffi:null-pointer))
      (silencing-callback-errors
        (finishes (invoke-completion tr :status :completed :actual 8)))
      (is (eq :fresh (libusb:transfer-state tr))
          "the record must be untouched -- the dispatcher could not know it was ours"))))

(test a-registry-index-is-never-reused
  "A recycled index would let a completion arriving late for a freed transfer resolve
to a live one and corrupt it, which is the entire class of bug this registry exists to
prevent. Indices are monotonic, and a dispatch on a forgotten one does nothing."
  (with-fake-handle (handle)
    (let ((seen '()))
      (dotimes (i 50)
        (let ((tr (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 4)))
          (push (libusb::transfer-index tr) seen)
          (libusb:free-usb-transfer tr)))
      (is (= 50 (length (remove-duplicates seen)))
          "~D of 50 indices were reused" (- 50 (length (remove-duplicates seen))))
      (is (apply #'> seen) "indices must be monotonic"))))

;;; --- what a completion records -----------------------------------------

(test a-completion-copies-status-and-actual-length-into-the-lisp-record
  "Mirrored into Lisp rather than read from C on demand, because with
LIBUSB_TRANSFER_FREE_TRANSFER the struct is gone the moment the dispatcher returns,
and without it the struct's status is only meaningful until the next submit. A caller
reading TRANSFER-STATUS after WAIT-FOR-TRANSFER must get the value that belonged to
that completion."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 64)
      (invoke-completion tr :status :stall :actual 17)
      (is (eq :stall (libusb:transfer-status tr)))
      (is (= 17 (libusb:transfer-actual-length tr)))
      (is (eq :done (libusb:transfer-state tr))))))

(test the-completion-flag-is-set-and-the-waiter-released
  "libusb's own sync.c sets its completion int from the callback, and a :MANUAL-mode
waiter watches only that flag -- so the flag must be set before the semaphore, and
both must happen."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8)
      (is (zerop (cffi:mem-ref (libusb::transfer-completed tr) :int)))
      (invoke-completion tr :status :completed :actual 8)
      (is (= 1 (cffi:mem-ref (libusb::transfer-completed tr) :int)))
      ;; With the flag already set, a wait must return at once and with the status
      ;; that belongs to this completion.
      (is (eq :completed (libusb:wait-for-transfer tr :timeout 1))))))

(test an-error-in-a-user-completion-function-does-not-unwind-into-c
  "Neither cffi:defcallback nor cffi-callback-closures contains an error: a condition
signalled here propagates out through the native dispatcher into libusb's frame --
the debugger entered while holding a libusb lock, or process death on a foreign
thread. WITH-CALLBACK-GUARD is what stands between a typo in somebody's completion
function and a dead image.

And the waiter must still be released, because a thread blocked forever is a worse
outcome than a reported backtrace."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8
                                     :function (lambda (transfer)
                                                 (declare (ignore transfer))
                                                 (error "deliberate")))
      (silencing-callback-errors
        (finishes (invoke-completion tr :status :completed :actual 8)))
      (is (eq :done (libusb:transfer-state tr)))
      (is (typep (libusb:transfer-callback-error tr) 'simple-error)
          "the condition is kept on the transfer so a caller can find out")
      (is (= 1 (cffi:mem-ref (libusb::transfer-completed tr) :int))
          "the waiter must be released even though the user function failed")
      (is (eq :completed (libusb:transfer-status tr))))))

(test a-completion-function-that-resubmits-does-not-wake-a-waiter
  "Resubmitting from the callback is how a stream is kept running. A completion that
has already been superseded is not a waiter's business, so the flag must stay clear --
otherwise the next WAIT-FOR-TRANSFER returns immediately with a stale status."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8
                                     :function
                                     (lambda (transfer)
                                       ;; What a resubmit does to the state, without a
                                       ;; real submit: this tier never touches the bus.
                                       (setf (libusb::transfer-state transfer) :submitted)))
      (invoke-completion tr :status :completed :actual 8)
      (is (eq :submitted (libusb:transfer-state tr)))
      (is (zerop (cffi:mem-ref (libusb::transfer-completed tr) :int))
          "a superseded completion must not release a waiter")
      ;; Put it back so WITH-TRANSFER can reclaim it without a cancel.
      (setf (libusb::transfer-state tr) :done))))

;;; --- the state machine -------------------------------------------------

(test freeing-an-in-flight-transfer-signals-rather-than-corrupting-memory
  "Freeing a transfer libusb still owns frees the buffer it may be writing into. There
is no recovery from that and no way to notice it afterwards, so the operation is
refused instead."
  (with-fake-handle (handle)
    (let ((tr (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 8)))
      (unwind-protect
           (progn
             (setf (libusb::transfer-state tr) :submitted)
             (signals libusb:libusb-transfer-state-error (libusb:free-usb-transfer tr))
             (signals libusb:libusb-transfer-state-error (libusb:submit-transfer tr)))
        (setf (libusb::transfer-state tr) :done)
        (libusb:free-usb-transfer tr)))))

(test freeing-a-transfer-twice-is-harmless-and-drops-it-from-the-registry
  "Teardown paths free things that may already be freed, so this has to be idempotent
-- and the registry entry has to go, or the count the hygiene suite checks never
returns to zero."
  (with-fake-handle (handle)
    (let* ((before (libusb:live-transfer-count))
           (tr (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 8)))
      (is (= (1+ before) (libusb:live-transfer-count)))
      (libusb:free-usb-transfer tr)
      (is (= before (libusb:live-transfer-count)))
      (finishes (libusb:free-usb-transfer tr))
      (is (eq :freed (libusb:transfer-state tr)))
      (is-false (libusb:transfer-live-p tr)))))

(test the-free-transfer-flag-unregisters-the-transfer-before-the-dispatcher-returns
  "With LIBUSB_TRANSFER_FREE_TRANSFER libusb destroys the struct as soon as the
callback returns. So the index has to stop resolving to this record during the
callback, not after -- and the record must be marked :FREED, because there is nothing
left to inspect or resubmit. This is also why such a transfer gets no completion cell
and cannot be waited on."
  (with-fake-handle (handle)
    (let ((tr (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 8
                                               :flags '(:free-transfer))))
      (is (cffi:null-pointer-p (libusb::transfer-completed tr))
          "a self-freeing transfer needs no completion cell")
      (signals libusb:libusb-usage-error (libusb:wait-for-transfer tr :timeout 0.1))
      (let ((index (libusb::transfer-index tr)))
        ;; The dispatcher will not free the libusb_transfer itself -- libusb does that,
        ;; and here nothing did -- so the struct is released below rather than leaked.
        (let ((pointer (libusb::transfer-pointer tr)))
          (invoke-completion tr :status :completed :actual 8)
          (is (null (libusb::%find-transfer index))
              "the registry entry must be gone by the time the dispatcher returns")
          (is (eq :freed (libusb:transfer-state tr)))
          (libusb::%libusb-free-transfer pointer))))))

(test the-transfer-flags-we-asked-for-are-the-flags-in-the-struct
  "libusb_alloc_transfer zeroes the struct and none of the fill helpers touch flags,
so this library writes them itself -- and a flag that failed to arrive would change
who frees what."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8
                                     :flags '(:short-not-ok :add-zero-packet))
      (let ((flags (cffi:foreign-slot-value (libusb::transfer-pointer tr)
                                            '(:struct libusb::libusb-transfer)
                                            'libusb::flags)))
        (is (member :short-not-ok flags))
        (is (member :add-zero-packet flags))
        (is (not (member :free-transfer flags))
            "the flag that decides whether libusb frees the struct must not appear ~
             by accident")))))

(test free-buffer-on-a-dev-mem-buffer-is-refused-before-libusb-can-free-an-mmap
  "libusb_dev_mem_alloc returns mmap'd memory and LIBUSB_TRANSFER_FREE_BUFFER makes
libusb call free() on the buffer. Combining them is not a subtle bug, it is a heap
corruption, and libusb's own header says so -- so the combination is rejected here
rather than passed on."
  (with-fake-handle (handle)
    (signals libusb:libusb-usage-error
      (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 8
                                       :dev-mem t :flags '(:free-buffer)))))

(test contradictory-buffer-arguments-are-rejected-rather-than-guessed
  "Which of :DATA, :LENGTH and :BUFFER-POINTER was meant decides where the bytes come
from. Guessing would silently send or receive the wrong thing."
  (with-fake-handle (handle)
    (signals libusb:libusb-usage-error
      (libusb:make-usb-transfer handle :data #(1 2 3) :length 3))
    (cffi:with-foreign-object (buffer :uint8 8)
      (signals libusb:libusb-usage-error
        (libusb:make-usb-transfer handle :data #(1 2 3) :buffer-pointer buffer)))))

(test a-transfer-given-a-caller-owned-buffer-does-not-free-it
  "The escape hatch for a caller with their own foreign memory -- static-vectors, an
mmap'd ring -- without this library growing a dependency on either. The contract is
that we do not free what we did not allocate; if we did, the second free would be
theirs."
  (with-fake-handle (handle)
    (let ((buffer (cffi:foreign-alloc :uint8 :count 16)))
      (unwind-protect
           (libusb:with-transfer (tr handle :type :bulk :endpoint #x83
                                            :length 16 :buffer-pointer buffer)
             (is-false (libusb::transfer-owns-buffer tr))
             (is (cffi:pointer-eq buffer (libusb:transfer-buffer-pointer tr))))
        ;; Still ours to free, and still valid -- which is the assertion.
        (cffi:foreign-free buffer)))))

(test data-written-into-a-transfer-comes-back-out-of-it
  "The copy in and the copy out, and the length that libusb reads. Boring and worth
having: the async path copies rather than pins -- SBCL's pinning is dynamic-extent and
an async buffer must outlive the submitting form -- so these two functions are on the
path of every byte the library moves asynchronously."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x02 :length 8)
      (libusb:transfer-write-data tr #(1 2 3 4))
      (is (= 4 (cffi:foreign-slot-value (libusb::transfer-pointer tr)
                                        '(:struct libusb::libusb-transfer)
                                        'libusb::length))
          "libusb reads the length from the struct, not from us")
      (invoke-completion tr :status :completed :actual 4)
      (is (equalp #(1 2 3 4) (libusb:transfer-data tr)))
      (is (= 8 (length (libusb:transfer-data tr :all t)))
          ":ALL returns the whole buffer, which is what an iso caller wants")
      (signals libusb:libusb-usage-error
        (libusb:transfer-write-data tr #(1 2 3 4 5 6 7 8 9))))))

;;; --- isochronous arithmetic, with no isochronous device ----------------

(test iso-packet-buffers-are-addressed-the-way-libusbs-inline-function-does
  "libusb_get_iso_packet_buffer is a static inline, so there is no symbol to bind and
this library reimplements it. Two forms: the accumulating one, correct for packets of
differing lengths, and libusb's O(1) shortcut that assumes they are all the size of
the first. They must agree when the lengths are equal and differ when they are not --
otherwise one of the two is wrong and it is not obvious which."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :isochronous :endpoint #x81
                                     :length (* 8 192) :num-iso-packets 8)
      (libusb:set-iso-packet-lengths tr 192)
      (let ((base (cffi:pointer-address (libusb:transfer-buffer-pointer tr))))
        (dotimes (i 8)
          (is (= (+ base (* i 192))
                 (cffi:pointer-address (libusb:iso-packet-buffer tr i))))
          (is (= (+ base (* i 192))
                 (cffi:pointer-address (libusb:iso-packet-buffer tr i :simple t)))))
        ;; Now make the packets unequal: the accumulating form follows, the shortcut
        ;; does not. That difference is the whole reason both exist.
        (setf (cffi:foreign-slot-value
               (libusb:transfer-iso-packet-descriptor (libusb::transfer-pointer tr) 0)
               '(:struct libusb::libusb-iso-packet-descriptor) 'libusb::length)
              64)
        (is (= (+ base 64) (cffi:pointer-address (libusb:iso-packet-buffer tr 1))))
        (is (= (+ base 64) (cffi:pointer-address
                            (libusb:iso-packet-buffer tr 1 :simple t)))
            "the simple form uses packet 0's length for every packet"))
      (is (null (libusb:iso-packet-buffer tr 8))
          "out of range must be NIL, not a pointer past the buffer")
      (signals libusb:libusb-usage-error (libusb:iso-packet-descriptor tr 8)))))

(test iso-packet-descriptors-report-what-was-written-into-them
  "The per-packet results an isochronous caller reads: requested length, how much
arrived, and a status of its own. No device here, so what is asserted is that the
three fields are addressed correctly -- which is exactly what the offset-60 trap would
break."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :isochronous :endpoint #x81
                                     :length 512 :num-iso-packets 4)
      (libusb:set-iso-packet-lengths tr 128)
      (dotimes (i 4)
        (multiple-value-bind (length actual status) (libusb:iso-packet-descriptor tr i)
          (is (= 128 length))
          (is (= 0 actual))
          (is (eq :completed status) "libusb_alloc_transfer zeroes these, and 0 is ~
                                      LIBUSB_TRANSFER_COMPLETED")))
      (let ((p (libusb:transfer-iso-packet-descriptor (libusb::transfer-pointer tr) 2)))
        (setf (cffi:foreign-slot-value p '(:struct libusb::libusb-iso-packet-descriptor)
                                       'libusb::actual-length)
              99
              (cffi:foreign-slot-value p '(:struct libusb::libusb-iso-packet-descriptor)
                                       'libusb::status)
              :overflow))
      (multiple-value-bind (length actual status) (libusb:iso-packet-descriptor tr 2)
        (is (= 128 length))
        (is (= 99 actual))
        (is (eq :overflow status)))
      (multiple-value-bind (length actual) (libusb:iso-packet-descriptor tr 3)
        (is (= 128 length))
        (is (= 0 actual) "packet 2's results must not have leaked into packet 3")))))

(test a-stream-id-survives-a-round-trip-on-an-unsubmitted-transfer
  "USB 3 bulk streams, which no hardware here has. The binding and the struct field
can still be checked, and that is most of what could be wrong with them."
  (with-fake-handle (handle)
    (libusb:with-transfer (tr handle :type :bulk-stream :endpoint #x83 :length 64)
      (setf (libusb:transfer-stream-id tr) 3)
      (is (= 3 (libusb:transfer-stream-id tr)))
      (is (= (cffi:foreign-enum-value 'libusb::libusb-transfer-type :bulk-stream)
             (cffi:foreign-slot-value (libusb::transfer-pointer tr)
                                      '(:struct libusb::libusb-transfer)
                                      'libusb::type))
          "fill_bulk_stream_transfer must leave the type as BULK_STREAM, not BULK"))))

;;; --- the minted closures -----------------------------------------------

(test a-minted-log-closure-translates-the-level-and-the-string
  "libusb_set_log_cb takes no user_data, which is why this one callback has to be a
runtime-minted libffi closure rather than a static callback with a registry. Here it is
invoked exactly as libusb would -- through its own function pointer, with an enum and a
C string -- and what the Lisp handler receives is asserted."
  (let ((received '()))
    (let ((pointer (libusb::%mint-log-callback
                    (lambda (ctx level message)
                      (push (list ctx level message) received)))))
      (unwind-protect
           (cffi:with-foreign-string (message "libusb: something happened")
             (cffi:foreign-funcall-pointer
              pointer () :pointer (cffi:null-pointer)
              libusb::libusb-log-level :warning :pointer message :void)
             (is (= 1 (length received)))
             (destructuring-bind (ctx level text) (first received)
               (is (cffi:null-pointer-p ctx))
               (is (eq :warning level) "the enum must arrive as a keyword")
               (is (string= "libusb: something happened" text)
                   "the C string must arrive as a Lisp string")))
        (cffi-callback-closures:free-foreign-callback pointer)))))

(test a-log-handler-that-itself-logs-does-not-recurse-until-the-stack-is-gone
  "The callback runs inside libusb, possibly holding libusb's own locks. A handler that
calls into libusb -- or whose output stream is implemented over a USB device, which this
library makes entirely possible -- re-enters here. The per-thread guard makes the inner
call a no-op instead of a crash."
  (let ((calls 0) (pointer nil))
    (setf pointer (libusb::%mint-log-callback
                   (lambda (ctx level message)
                     (declare (ignore ctx level))
                     (incf calls)
                     ;; Re-enter ten deep. Without the guard this does not return.
                     (when (< calls 20)
                       (cffi:with-foreign-string (again message)
                         (cffi:foreign-funcall-pointer
                          pointer () :pointer (cffi:null-pointer)
                          libusb::libusb-log-level :debug :pointer again :void))))))
    (unwind-protect
         (cffi:with-foreign-string (message "recursive")
           (finishes
             (cffi:foreign-funcall-pointer
              pointer () :pointer (cffi:null-pointer)
              libusb::libusb-log-level :debug :pointer message :void))
           (is (= 1 calls) "the handler ran ~D times; the reentrancy guard did not hold"
               calls))
      (cffi-callback-closures:free-foreign-callback pointer))))

(test an-error-in-a-log-handler-is-contained-like-any-other-callback
  "Same guard, and it matters more here than anywhere: the log callback is the one that
can be invoked from libusb's own internal threads at any moment, including during
libusb_exit."
  (let ((pointer (libusb::%mint-log-callback
                  (lambda (ctx level message)
                    (declare (ignore ctx level message))
                    (error "deliberate")))))
    (unwind-protect
         (silencing-callback-errors
           (cffi:with-foreign-string (message "boom")
             (finishes
               (cffi:foreign-funcall-pointer
                pointer () :pointer (cffi:null-pointer)
                libusb::libusb-log-level :error :pointer message :void))))
      (cffi-callback-closures:free-foreign-callback pointer))))

(test the-default-log-handler-collects-into-a-bounded-ring
  "It does not print, and that is deliberate: libusb logs from inside its own locks and
from its own threads, so a handler that formats to a stream which might block turns a
debugging aid into a deadlock. And the ring is bounded, because a device in a retry
loop can produce a great many messages."
  (let ((libusb::*log-messages* '())
        (libusb::*log-message-limit* 4))
    (dotimes (i 10)
      (libusb::collect-log-message nil :debug (format nil "message ~D~%" i)))
    (let ((messages (libusb:drain-log-messages)))
      (is (= 4 (length messages)) "the ring kept ~D of 10" (length messages))
      (is (string= "message 9" (cdr (first (last messages))))
          "newest must be kept, and the trailing newline stripped"))
    (is (null (libusb:log-messages)) "draining must clear")))

(test a-minted-hotplug-closure-translates-the-event-and-returns-zero
  "The hotplug callback's contract has a sharp edge: returning 1 deregisters it. So a
handler that merely continues must return 0, and -- as the next test shows -- a handler
that fails must also return 0, or a bug in somebody's callback would silently switch
hotplug off."
  (libusb:with-context (context)
    (let ((events '()))
      (let ((pointer (cffi-callback-closures:make-foreign-callback
                      (lambda (ctx device event user-data)
                        (declare (ignore ctx device user-data))
                        (libusb:with-callback-guard ("hotplug test" 0)
                          (push event events)
                          0))
                      :int '(:pointer :pointer libusb::libusb-hotplug-event :pointer))))
        (unwind-protect
             (progn
               (is (= 0 (cffi:foreign-funcall-pointer
                         pointer () :pointer (libusb:context-pointer context)
                         :pointer (cffi:null-pointer)
                         libusb::libusb-hotplug-event :device-left
                         :pointer (cffi:null-pointer) :int)))
               (is (equal '(:device-left) events)))
          (cffi-callback-closures:free-foreign-callback pointer))))))

(test a-failing-hotplug-callback-returns-zero-so-it-is-not-deregistered
  "1 means \"stop calling me\". A handler with a bug in it should be reported and kept,
not silently removed -- otherwise the first transient error in somebody's callback
turns off device detection for the life of the process, with nothing to show why."
  (let ((pointer (cffi-callback-closures:make-foreign-callback
                  (lambda (ctx device event user-data)
                    (declare (ignore ctx device event user-data))
                    (libusb:with-callback-guard ("hotplug test" 0)
                      (error "deliberate")))
                  :int '(:pointer :pointer libusb::libusb-hotplug-event :pointer))))
    (unwind-protect
         (silencing-callback-errors
           (is (= 0 (cffi:foreign-funcall-pointer
                     pointer () :pointer (cffi:null-pointer)
                     :pointer (cffi:null-pointer)
                     libusb::libusb-hotplug-event :device-arrived
                     :pointer (cffi:null-pointer) :int))))
      (cffi-callback-closures:free-foreign-callback pointer))))

(test every-minted-closure-is-freed-when-its-owner-is-retired
  "cffi-callback-closures installs no finalizers, so an unfreed closure leaks an
executable page for the life of the image -- and a closure freed too early is worse: a
C function pointer into an unmapped page. This asserts the count returns to where it
started, which is the same thing the hygiene suite checks for the whole run."
  (libusb:with-context (context)
    (let ((before (libusb:live-closure-count)))
      (libusb:set-log-callback context)
      (is (= (1+ before) (libusb:live-closure-count)))
      (libusb:clear-log-callback context)
      (is (= before (libusb:live-closure-count)))
      (finishes (libusb:clear-log-callback context)))))
