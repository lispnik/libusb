;;; Asynchronous transfers: the registry, the one native callback, and the
;;; submit / complete / cancel / free state machine.
;;;
;;; There is exactly ONE cffi:defcallback in this library, %TRANSFER-COMPLETE, and
;;; the transfer's own user_data field carries an integer index into a registry
;;; that finds the Lisp record. The alternative -- minting a libffi closure per
;;; transfer with cffi-callback-closures -- would cost an ffi_closure_alloc, which
;;; is an mmap of an executable page plus a foreign cif, for an object that lives
;;; for one 300 ms bulk read; a streaming application churns thousands of them.
;;; struct libusb_transfer hands us a void * of our own, which is precisely the
;;; demultiplexer a closure would otherwise be paying for. (Hotplug and log
;;; callbacks are a different case, and do use closures: see libusb/closures.)
;;;
;;; Buffers are foreign-allocated rather than pinned Lisp vectors, and that is
;;; forced rather than chosen. SBCL's pinning is dynamic-extent, but an async
;;; buffer must stay put from libusb_submit_transfer until a completion callback
;;; on another thread at an unknown later time -- which cannot be nested inside
;;; the submitting form. Unpinned, a GC in any thread can move an octet vector
;;; while the kernel is writing into its old address, and that surfaces as
;;; occasional wrong bytes: no crash, nothing to bisect. One memcpy per transfer
;;; against a USB transaction costing tens of microseconds is not a trade worth
;;; thinking about twice.

(in-package #:libusb)

(define-condition libusb-transfer-state-error (libusb-error)
  ((transfer  :initarg :transfer  :reader libusb-transfer-state-error-transfer)
   (state     :initarg :state     :reader libusb-transfer-state-error-state)
   (operation :initarg :operation :reader libusb-transfer-state-error-operation))
  (:report (lambda (c stream)
             (format stream "libusb: ~S is not valid on a ~(~A~) transfer"
                     (libusb-transfer-state-error-operation c)
                     (libusb-transfer-state-error-state c))))
  (:documentation "A transfer operation was attempted in the wrong state.

Signalled rather than allowed, because the two cases that get here are both
memory corruption if permitted: freeing a transfer libusb still owns, and
submitting one that is already in flight."))

(defstruct (transfer (:constructor %make-transfer)
                     (:predicate transferp)
                     (:copier nil)
                     (:print-object print-transfer))
  (index 0 :type (integer 0))           ; registry key, and the C user_data
  (pointer (cffi:null-pointer))
  context
  handle                                ; kept reachable: libusb holds its pointer
  (type :bulk)
  (endpoint 0)
  (buffer (cffi:null-pointer))
  (size 0)
  (owns-buffer t)
  (dev-mem nil)                         ; came from libusb_dev_mem_alloc
  (num-iso-packets 0)
  (flags '())
  (state :fresh)                        ; :fresh :submitted :done :freed
  ;; STATUS and ACTUAL-LENGTH are mirrored into Lisp by the dispatcher rather
  ;; than read from C on demand, for two reasons: with LIBUSB_TRANSFER_FREE_
  ;; TRANSFER the struct is gone the moment the dispatcher returns, and without
  ;; it the struct's own status is only meaningful until the next submit. A
  ;; caller reading (TRANSFER-STATUS tr) after WAIT-FOR-TRANSFER must get the
  ;; value that belonged to *that* completion.
  (status nil)
  (actual-length 0)
  (function nil)                        ; user completion function of one argument
  (callback-error nil)
  (completed (cffi:null-pointer))       ; foreign int, for handle_events_completed
  (semaphore nil)
  (lock nil)
  (submit-count 0)
  (epoch 0 :type fixnum))

(defun print-transfer (transfer stream)
  (print-unreadable-object (transfer stream :type t)
    (format stream "#~D ~(~A~) #x~2,'0X ~(~A~)~@[ ~(~A~)~]~@[ ~D/~D~]"
            (transfer-index transfer) (transfer-type transfer)
            (transfer-endpoint transfer) (transfer-state transfer)
            (transfer-status transfer)
            (and (plusp (transfer-actual-length transfer))
                 (transfer-actual-length transfer))
            (transfer-size transfer))))

;;; --- the registry ------------------------------------------------------

(defvar *transfers* (make-hash-table)
  "INDEX -> TRANSFER, for every transfer libusb currently owns.

The index is what lives in the C struct's user_data field, so this table is also
what keeps the Lisp record -- and through it the buffer, the completion function
and the device handle -- reachable while the transfer is in flight.")

(defvar *transfers-lock* (bt:make-lock "libusb transfer registry"))
(defvar *next-transfer-index* 0)

(defun live-transfer-count ()
  "How many transfers this image currently has registered."
  (bt:with-lock-held (*transfers-lock*) (hash-table-count *transfers*)))

(defun %intern-transfer (transfer)
  "Give TRANSFER an index and register it. Returns the index.

Indices are never reused. A recycled index would let a completion that arrives
late for a freed transfer resolve to a live one and corrupt it -- which is the
entire class of bug this registry exists to prevent. A fixnum counter at one
transfer per microsecond lasts longer than the hardware."
  (bt:with-lock-held (*transfers-lock*)
    (let ((index (incf *next-transfer-index*)))
      (setf (transfer-index transfer) index
            (gethash index *transfers*) transfer)
      index)))

(defun %find-transfer (index)
  "The TRANSFER with INDEX, or NIL.

The lock scopes the GETHASH and nothing else: it is released before any user code
runs, so a completion function that submits another transfer -- the streaming
idiom -- cannot deadlock against the registry."
  (bt:with-lock-held (*transfers-lock*) (gethash index *transfers*)))

(defun %forget-transfer (index)
  (bt:with-lock-held (*transfers-lock*) (remhash index *transfers*)))

;;; --- the single native callback ----------------------------------------

(cffi:defcallback %transfer-complete :void ((tr :pointer))
  (with-callback-guard ("transfer completion")
    (let* ((index (cffi:pointer-address
                   (cffi:foreign-slot-value tr '(:struct libusb-transfer) 'user-data)))
           (transfer (and (plusp index) (%find-transfer index))))
      (if transfer
          (%finish-transfer transfer tr)
          ;; Either not ours -- another library sharing this context, or a struct
          ;; somebody else filled -- or ours and already forgotten. Index 0 is
          ;; reserved for exactly this: we do not know who owns TR, so nothing
          ;; further is read from it.
          (report-callback-error
           "transfer completion"
           (format nil "completion for unknown transfer index ~D" index))))))

(defun %finish-transfer (transfer tr)
  "Record a completion, run the user function, and release any waiter."
  (let* ((flags (cffi:foreign-slot-value tr '(:struct libusb-transfer) 'flags))
         (status (cffi:foreign-slot-value tr '(:struct libusb-transfer) 'status))
         (actual (cffi:foreign-slot-value tr '(:struct libusb-transfer) 'actual-length))
         (self-freeing (member :free-transfer flags)))
    (bt:with-lock-held ((transfer-lock transfer))
      (setf (transfer-status transfer) status
            (transfer-actual-length transfer) actual
            (transfer-state transfer) (if self-freeing :freed :done)))
    (when self-freeing
      ;; libusb frees the struct as soon as we return, so the index must stop
      ;; resolving to this record now and TR must not be touched again.
      (%forget-transfer (transfer-index transfer))
      (%release-transfer-resources transfer :struct-gone t))
    ;; The user function gets its own guard so that an error in it cannot skip the
    ;; wake-up below. A thread blocked forever is a worse outcome than a reported
    ;; backtrace.
    (let ((function (transfer-function transfer)))
      (when function
        (handler-case (without-float-traps (funcall function transfer))
          (serious-condition (e)
            (setf (transfer-callback-error transfer) e)
            (report-callback-error "transfer completion (user function)" e)))))
    ;; A completion function is allowed to resubmit -- that is how a stream is
    ;; kept running -- and if it did, this completion is not a waiter's business.
    (when (eq :done (bt:with-lock-held ((transfer-lock transfer))
                      (transfer-state transfer)))
      ;; Flag before semaphore, deliberately: a :MANUAL-mode waiter watches only
      ;; the flag, and libusb's own sync.c sets its completion int from the
      ;; callback in exactly this order.
      (unless (cffi:null-pointer-p (transfer-completed transfer))
        (setf (cffi:mem-ref (transfer-completed transfer) :int) 1))
      (bt:signal-semaphore (transfer-semaphore transfer))))
  nil)

;;; --- allocation and filling --------------------------------------------

(defun transfer-live-p (transfer)
  "True if TRANSFER still owns a libusb_transfer from this image."
  (and (transferp transfer)
       (not (eq :freed (transfer-state transfer)))
       (= (transfer-epoch transfer) *image-epoch*)))

(defun check-transfer (transfer &optional operation)
  (unless (transferp transfer)
    (usage-error "~S is not a libusb transfer." transfer))
  (unless (= (transfer-epoch transfer) *image-epoch*)
    (error 'libusb-stale-object :object transfer :operation operation))
  (when (eq :freed (transfer-state transfer))
    (error 'libusb-invalid-object :object transfer :operation operation))
  transfer)

(defun %allocate-buffer (handle size dev-mem)
  "Allocate SIZE bytes for a transfer. Returns (VALUES POINTER DEV-MEM-P).

DEV-MEM asks for libusb_dev_mem_alloc, the Linux usbfs zero-copy path, and falls
back to malloc when it is unavailable -- which is every non-Linux backend and any
kernel without the support. The fallback is silent but observable: DEV-MEM-P comes
back NIL, so a caller who needs to know can assert on it."
  (cond ((zerop size) (values (cffi:null-pointer) nil))
        (dev-mem
         (let ((p (%libusb-dev-mem-alloc (handle-pointer handle) size)))
           (if (cffi:null-pointer-p p)
               (values (cffi:foreign-alloc :uint8 :count size) nil)
               (values p t))))
        (t (values (cffi:foreign-alloc :uint8 :count size) nil))))

(defun make-usb-transfer (handle &key (type :bulk) (endpoint 0)
                                      (timeout *default-timeout*)
                                      length data buffer-pointer
                                      (num-iso-packets 0) (flags '())
                                      dev-mem function)
  "Allocate an asynchronous transfer on HANDLE. Nothing is submitted.

TYPE is :CONTROL :BULK :INTERRUPT :ISOCHRONOUS or :BULK-STREAM. Give :LENGTH for a
read or :DATA for a write; BUFFER-POINTER hands the transfer foreign memory the
caller owns, which is how a static-vectors or mmap-backed user opts out of the copy
without this library taking a dependency. FUNCTION, if given, is called with the
transfer when it completes -- on the event-handling thread, so keep it short.

FLAGS is a list of LIBUSB-TRANSFER-FLAGS keywords. The default -- none of them --
leaves this library owning the struct and the buffer, with FREE-USB-TRANSFER as
the single point of reclamation. :FREE-TRANSFER is genuine fire-and-forget: it
makes libusb destroy the struct when the callback returns, which forbids both
inspecting the result afterwards and resubmitting, so it allocates no completion
cell and WAIT-FOR-TRANSFER cannot be used. :FREE-BUFFER is refused on a dev-mem
buffer, because libusb would call free() on an mmap."
  (check-handle handle 'make-usb-transfer)
  (when (and dev-mem (member :free-buffer flags))
    (usage-error "LIBUSB_TRANSFER_FREE_BUFFER on a dev-mem buffer would free() ~
                  an mmap; ask for one or the other."))
  (when (and data length)
    (usage-error "MAKE-USB-TRANSFER takes :DATA or :LENGTH, not both."))
  (when (and buffer-pointer (or data dev-mem))
    (usage-error "MAKE-USB-TRANSFER was given :BUFFER-POINTER as well as ~
                  ~:[:DEV-MEM~;:DATA~]; the buffer can only come from one place."
                 (and data t)))
  (let* ((size (or length (and data (length data)) 0))
         (pointer (%libusb-alloc-transfer num-iso-packets)))
    (when (cffi:null-pointer-p pointer)
      (error 'libusb-no-memory :code -11 :function '%libusb-alloc-transfer))
    (let ((transfer (%make-transfer :pointer pointer
                                   :context (handle-context handle)
                                   :handle handle
                                   :type type
                                   :endpoint endpoint
                                   :size size
                                   :num-iso-packets num-iso-packets
                                   :flags flags
                                   :function function
                                   :epoch *image-epoch*
                                   :lock (bt:make-lock "libusb transfer")
                                   :semaphore (bt:make-semaphore :count 0))))
      (handler-case
          (progn
            (if buffer-pointer
                (setf (transfer-buffer transfer) buffer-pointer
                      (transfer-owns-buffer transfer) nil)
                (multiple-value-bind (p dev-mem-p) (%allocate-buffer handle size dev-mem)
                  (setf (transfer-buffer transfer) p
                        (transfer-dev-mem transfer) dev-mem-p)))
            ;; No completion cell for a self-freeing transfer: there will be
            ;; nothing left to report to and nobody may wait on it.
            (unless (member :free-transfer flags)
              (setf (transfer-completed transfer)
                    (cffi:foreign-alloc :int :initial-element 0)))
            (when data (transfer-write-data transfer data))
            ;; Interned before the struct is filled, because the index has to
            ;; exist before it is written into user_data.
            (%intern-transfer transfer)
            (%fill-transfer transfer timeout)
            (let ((context (handle-context handle)))
              (bt:with-lock-held ((context-lock context))
                (push transfer (context-transfers context))))
            transfer)
        (serious-condition (e)
          (ignore-errors (free-usb-transfer transfer))
          (error e))))))

(defun %fill-transfer (transfer timeout)
  (let ((pointer (transfer-pointer transfer))
        (handle (handle-pointer (transfer-handle transfer)))
        (callback (cffi:callback %transfer-complete))
        (user-data (cffi:make-pointer (transfer-index transfer)))
        (buffer (transfer-buffer transfer))
        (size (transfer-size transfer)))
    (ecase (transfer-type transfer)
      (:control
       ;; The caller was expected to write a SETUP packet into the buffer with
       ;; %LIBUSB-FILL-CONTROL-SETUP; the length comes from its wLength, exactly
       ;; as libusb.h's inline does.
       (%libusb-fill-control-transfer pointer handle buffer callback user-data timeout))
      (:bulk
       (%libusb-fill-bulk-transfer pointer handle (transfer-endpoint transfer)
                                   buffer size callback user-data timeout))
      (:bulk-stream
       (%libusb-fill-bulk-stream-transfer pointer handle (transfer-endpoint transfer)
                                          0 buffer size callback user-data timeout))
      (:interrupt
       (%libusb-fill-interrupt-transfer pointer handle (transfer-endpoint transfer)
                                        buffer size callback user-data timeout))
      (:isochronous
       (%libusb-fill-iso-transfer pointer handle (transfer-endpoint transfer)
                                  buffer size (transfer-num-iso-packets transfer)
                                  callback user-data timeout)))
    ;; The fill helpers do not touch flags, and libusb_alloc_transfer zeroes the
    ;; struct, so this is the only place flags are written.
    (setf (cffi:foreign-slot-value pointer '(:struct libusb-transfer) 'flags)
          (transfer-flags transfer))
    transfer))

;;; --- data in and out ---------------------------------------------------

(defun transfer-write-data (transfer data &key (start 0) end)
  "Copy DATA into TRANSFER's buffer and set its length. Returns the length."
  (check-transfer transfer 'transfer-write-data)
  (let* ((end (or end (length data)))
         (count (- end start)))
    (when (> count (transfer-size transfer))
      (usage-error "~D bytes will not fit in a transfer buffer of ~D."
                   count (transfer-size transfer)))
    (dotimes (i count)
      (setf (cffi:mem-aref (transfer-buffer transfer) :uint8 i)
            (aref data (+ start i))))
    (unless (cffi:null-pointer-p (transfer-pointer transfer))
      (setf (cffi:foreign-slot-value (transfer-pointer transfer)
                                     '(:struct libusb-transfer) 'length)
            count))
    count))

(defun transfer-data (transfer &key into all)
  "The bytes TRANSFER received, as a fresh octet vector.

Only the ACTUAL-LENGTH bytes that arrived, unless ALL is true, in which case the
whole buffer comes back -- which is what a caller inspecting an isochronous
transfer's individual packets wants, since their lengths live in the packet
descriptors rather than in actual_length."
  (check-transfer transfer 'transfer-data)
  (octets-from-pointer (transfer-buffer transfer)
                       (if all (transfer-size transfer) (transfer-actual-length transfer))
                       :into into))

(defun transfer-buffer-pointer (transfer)
  "TRANSFER's foreign buffer, for a caller who would rather not copy."
  (check-transfer transfer 'transfer-buffer-pointer)
  (transfer-buffer transfer))

;;; --- submit, wait, cancel, free ----------------------------------------

(defun submit-transfer (transfer)
  "Hand TRANSFER to libusb. Returns TRANSFER.

Valid on a :FRESH transfer and on a :DONE one -- resubmitting the same transfer is
the normal way to keep a stream running, and it reuses the struct, the buffer and
the registry entry."
  (check-transfer transfer 'submit-transfer)
  (bt:with-lock-held ((transfer-lock transfer))
    (unless (member (transfer-state transfer) '(:fresh :done))
      (error 'libusb-transfer-state-error :transfer transfer
                                          :state (transfer-state transfer)
                                          :operation 'submit-transfer))
    (setf (transfer-status transfer) nil
          (transfer-actual-length transfer) 0
          (transfer-callback-error transfer) nil
          ;; Set BEFORE the C call, not after: the callback can fire on the pump
          ;; thread before libusb_submit_transfer has returned to us, and a
          ;; post-hoc SETF would clobber :DONE back to :SUBMITTED.
          (transfer-state transfer) :submitted)
    (incf (transfer-submit-count transfer)))
  (unless (cffi:null-pointer-p (transfer-completed transfer))
    (setf (cffi:mem-ref (transfer-completed transfer) :int) 0))
  ;; A fresh semaphore, rather than draining the old one. A resubmitted transfer whose
  ;; semaphore still carries last round's count would make the next WAIT-FOR-TRANSFER
  ;; return instantly with a stale status -- and bordeaux-threads has no portable
  ;; non-blocking way to drain one (WAIT-ON-SEMAPHORE rejects a zero timeout). The
  ;; dispatcher reads this slot when it completes, and submit writes it before the C
  ;; call, so the callback always signals the semaphore a waiter is about to wait on.
  (setf (transfer-semaphore transfer) (bt:make-semaphore :count 0))
  (let ((rc (%libusb-submit-transfer (transfer-pointer transfer))))
    (unless (zerop rc)
      ;; No callback will come, so the state has to be rolled back here or the
      ;; transfer can never be freed.
      (bt:with-lock-held ((transfer-lock transfer))
        (setf (transfer-state transfer) :fresh))
      (check-result rc '%libusb-submit-transfer
                    (format nil "endpoint #x~2,'0X" (transfer-endpoint transfer)))))
  transfer)

(defun wait-for-transfer (transfer &key timeout)
  "Block until TRANSFER completes. Returns its status keyword, or NIL on TIMEOUT.

NIL means this call gave up, not that the transfer did: it is still in flight and
its callback has not run. TIMEOUT is in seconds and is a Lisp-side deadline,
entirely separate from the transfer's own millisecond timeout, which libusb
enforces.

How the waiting is done depends on the context's event mode, because there is no
single answer that is correct in both. With a pump thread running we simply block
on a semaphore. Without one, nobody is calling libusb_handle_events, so the waiter
has to be the pump -- via libusb_handle_events_timeout_completed, which takes the
event lock properly on our behalf and returns as soon as the completion flag is
set."
  (check-transfer transfer 'wait-for-transfer)
  (when (cffi:null-pointer-p (transfer-completed transfer))
    (usage-error "This transfer was created with :FREE-TRANSFER, so libusb ~
                  destroys it inside the callback and there is nothing left to ~
                  wait for. Use a completion FUNCTION instead."))
  (ecase (context-event-mode (transfer-context transfer))
    (:thread (%wait-on-semaphore transfer timeout))
    (:manual (%pump-until-complete transfer timeout))))

(defun %deadline (seconds)
  (and seconds (+ (get-internal-real-time)
                  (round (* seconds internal-time-units-per-second)))))

(defun %seconds-remaining (deadline)
  (and deadline
       (/ (- deadline (get-internal-real-time))
          (float internal-time-units-per-second))))

(defun %wait-on-semaphore (transfer timeout)
  ;; The state is the authority and the semaphore is only a wake-up: bordeaux-
  ;; threads' WAIT-ON-SEMAPHORE has returned different things in different
  ;; versions, and a deadline loop absorbs a spurious wake-up without a special
  ;; case for it.
  (let ((deadline (%deadline timeout)))
    (loop
      (when (member (transfer-state transfer) '(:done :freed))
        (return (transfer-status transfer)))
      (let ((remaining (%seconds-remaining deadline)))
        (when (and remaining (<= remaining 0)) (return nil))
        ;; Re-read the slot each time round: a resubmit installs a new semaphore, and
        ;; the deadline loop is what makes waiting on the previous one harmless.
        (bt:wait-on-semaphore (transfer-semaphore transfer)
                              :timeout (max (min (or remaining 0.25) 0.25) 0.001))))))

(defun %pump-until-complete (transfer timeout)
  (let ((ctx (context-pointer (transfer-context transfer)))
        (cell (transfer-completed transfer))
        (deadline (%deadline timeout)))
    (cffi:with-foreign-object (tv '(:struct timeval))
      (loop
        (when (plusp (cffi:mem-ref cell :int))
          (return (transfer-status transfer)))
        (let ((remaining (%seconds-remaining deadline)))
          (when (and remaining (<= remaining 0)) (return nil))
          (%set-timeval tv (min 0.1 (or remaining 0.1)))
          (let ((rc (%libusb-handle-events-timeout-completed ctx tv cell)))
            (unless (or (zerop rc)
                        ;; A signal arrived. Not a failure -- go round again.
                        (= rc -10))     ; LIBUSB_ERROR_INTERRUPTED
              (check-result rc '%libusb-handle-events-timeout-completed))))))))

(defun %set-timeval (tv seconds)
  (multiple-value-bind (whole fraction) (floor (max seconds 0))
    (setf (cffi:foreign-slot-value tv '(:struct timeval) 'tv-sec) whole
          (cffi:foreign-slot-value tv '(:struct timeval) 'tv-usec)
          (round (* fraction 1000000))))
  tv)

(defun cancel-transfer (transfer &key (drain t) (timeout 2))
  "Ask libusb to cancel TRANSFER, and by default wait for the callback.

Cancellation is asynchronous: libusb_cancel_transfer only requests it, and the
completion callback still runs, with status :CANCELLED. Nothing may be reclaimed
until it has, which is why DRAIN defaults to true -- freeing a transfer whose
callback is still pending is a use-after-free of the buffer.

LIBUSB_ERROR_NOT_FOUND from libusb is not an error here: it means the transfer had
already completed or is completing, so the callback is on its way regardless."
  (check-transfer transfer 'cancel-transfer)
  (when (eq :submitted (transfer-state transfer))
    (let ((rc (%libusb-cancel-transfer (transfer-pointer transfer))))
      (unless (or (zerop rc) (= rc -5)) ; LIBUSB_ERROR_NOT_FOUND
        (check-result rc '%libusb-cancel-transfer))))
  (when (and drain (not (cffi:null-pointer-p (transfer-completed transfer))))
    (wait-for-transfer transfer :timeout timeout))
  transfer)

(defun %release-transfer-resources (transfer &key struct-gone)
  "Free TRANSFER's buffer and completion cell. STRUCT-GONE if libusb freed the
libusb_transfer itself, as it does for :FREE-TRANSFER."
  (let ((buffer (transfer-buffer transfer)))
    (when (and (transfer-owns-buffer transfer)
               (not (cffi:null-pointer-p buffer))
               ;; With FREE_BUFFER set, libusb_free_transfer already did it.
               (not (member :free-buffer (transfer-flags transfer))))
      (if (transfer-dev-mem transfer)
          (ignore-errors (%libusb-dev-mem-free (handle-pointer (transfer-handle transfer))
                                               buffer (transfer-size transfer)))
          (cffi:foreign-free buffer))))
  (setf (transfer-buffer transfer) (cffi:null-pointer))
  (let ((cell (transfer-completed transfer)))
    (unless (cffi:null-pointer-p cell)
      (cffi:foreign-free cell)
      (setf (transfer-completed transfer) (cffi:null-pointer))))
  (when struct-gone
    (setf (transfer-pointer transfer) (cffi:null-pointer)))
  (let ((context (transfer-context transfer)))
    (when (and context (context-live context))
      (bt:with-lock-held ((context-lock context))
        (setf (context-transfers context)
              (remove transfer (context-transfers context))))))
  (values))

(defun free-usb-transfer (transfer)
  "Release TRANSFER. Idempotent.

Signals LIBUSB-TRANSFER-STATE-ERROR if the transfer is still in flight, because
freeing one libusb still owns frees the buffer it is writing into. Cancel and
drain it first -- or use WITH-TRANSFER, which does."
  (unless (transferp transfer) (return-from free-usb-transfer (values)))
  (bt:with-lock-held ((transfer-lock transfer))
    (when (eq :submitted (transfer-state transfer))
      (error 'libusb-transfer-state-error :transfer transfer :state :submitted
                                         :operation 'free-usb-transfer)))
  (unless (eq :freed (transfer-state transfer))
    ;; The registry entry goes first: after this, a completion that somehow
    ;; arrives finds nothing and does nothing, rather than finding a half-freed
    ;; record.
    (%forget-transfer (transfer-index transfer))
    (let ((pointer (transfer-pointer transfer)))
      (unless (cffi:null-pointer-p pointer)
        (%libusb-free-transfer pointer)))
    (setf (transfer-pointer transfer) (cffi:null-pointer))
    (%release-transfer-resources transfer)
    (setf (transfer-state transfer) :freed))
  (values))

;;; Steps 20 and 30: cancel and drain everything in flight, then free it. Both
;;; before the event pump stops, because the drain needs the pump to deliver the
;;; cancellations.
(register-context-teardown
 20 (lambda (context)
      (dolist (transfer (copy-list (context-transfers context)))
        (when (eq :submitted (transfer-state transfer))
          (ignore-errors (cancel-transfer transfer :drain t :timeout 2))))))

(register-context-teardown
 30 (lambda (context)
      (dolist (transfer (copy-list (context-transfers context)))
        (ignore-errors (free-usb-transfer transfer)))
      (setf (context-transfers context) '())))

;;; --- isochronous packets and streams -----------------------------------

(defun set-iso-packet-lengths (transfer length)
  "Set every isochronous packet descriptor of TRANSFER to LENGTH."
  (check-transfer transfer 'set-iso-packet-lengths)
  (%libusb-set-iso-packet-lengths (transfer-pointer transfer) length)
  transfer)

(defun iso-packet-descriptor (transfer index)
  "Isochronous packet INDEX of TRANSFER, as (VALUES LENGTH ACTUAL-LENGTH STATUS)."
  (check-transfer transfer 'iso-packet-descriptor)
  (unless (< index (transfer-num-iso-packets transfer))
    (usage-error "Packet ~D of a transfer with ~D packet~:P."
                 index (transfer-num-iso-packets transfer)))
  (let ((p (transfer-iso-packet-descriptor (transfer-pointer transfer) index)))
    (values (cffi:foreign-slot-value p '(:struct libusb-iso-packet-descriptor) 'length)
            (cffi:foreign-slot-value p '(:struct libusb-iso-packet-descriptor)
                                     'actual-length)
            (cffi:foreign-slot-value p '(:struct libusb-iso-packet-descriptor) 'status))))

(defun iso-packet-buffer (transfer index &key simple)
  "A pointer to isochronous packet INDEX's data within TRANSFER's buffer.

Accumulates the preceding packets' lengths, which is correct for packets of
differing sizes. SIMPLE takes libusb's O(1) shortcut of assuming every packet is
the size of the first -- faster, and wrong the moment they differ."
  (check-transfer transfer 'iso-packet-buffer)
  (if simple
      (%libusb-get-iso-packet-buffer-simple (transfer-pointer transfer) index)
      (%libusb-get-iso-packet-buffer (transfer-pointer transfer) index)))

(defun transfer-stream-id (transfer)
  "TRANSFER's bulk stream id."
  (check-transfer transfer 'transfer-stream-id)
  (%libusb-transfer-get-stream-id (transfer-pointer transfer)))

(defun (setf transfer-stream-id) (stream-id transfer)
  (check-transfer transfer '(setf transfer-stream-id))
  (%libusb-transfer-set-stream-id (transfer-pointer transfer) stream-id)
  stream-id)

(defun alloc-streams (handle endpoints num-streams)
  "Allocate NUM-STREAMS bulk streams on ENDPOINTS, a list of addresses.

USB 3 only, and Linux only in practice. Returns the number of streams actually
allocated, which can be fewer than asked for."
  (check-handle handle 'alloc-streams)
  (let ((n (length endpoints)))
    (cffi:with-foreign-object (array :uint8 (max n 1))
      (loop for e in endpoints for i from 0
            do (setf (cffi:mem-aref array :uint8 i) e))
      (check-result (%libusb-alloc-streams (handle-pointer handle) num-streams array n)
                    '%libusb-alloc-streams))))

(defun free-streams (handle endpoints)
  "Release the bulk streams allocated on ENDPOINTS."
  (check-handle handle 'free-streams)
  (let ((n (length endpoints)))
    (cffi:with-foreign-object (array :uint8 (max n 1))
      (loop for e in endpoints for i from 0
            do (setf (cffi:mem-aref array :uint8 i) e))
      (check-result (%libusb-free-streams (handle-pointer handle) array n)
                    '%libusb-free-streams))))

(defun dev-mem-alloc (handle size)
  "SIZE bytes of DMA-capable, zero-copy memory, or NIL if unavailable.

Linux usbfs only. Must be released with DEV-MEM-FREE and never with
CFFI:FOREIGN-FREE, and never given LIBUSB_TRANSFER_FREE_BUFFER."
  (check-handle handle 'dev-mem-alloc)
  (let ((p (%libusb-dev-mem-alloc (handle-pointer handle) size)))
    (unless (cffi:null-pointer-p p) p)))

(defun dev-mem-free (handle pointer size)
  "Release memory from DEV-MEM-ALLOC."
  (check-handle handle 'dev-mem-free)
  (check-result (%libusb-dev-mem-free (handle-pointer handle) pointer size)
                '%libusb-dev-mem-free))
