;;; Synchronous transfers, and the buffer marshalling both transfer layers use.
;;;
;;; These wrap libusb's own blocking functions, which do their own event handling
;;; internally. That has one consequence worth knowing before reaching for them:
;;; on a context with an event pump running (src/events.lisp) they contend with
;;; the pump for the context's event lock, and a blocking call here cannot be
;;; interrupted once entered -- not by a Lisp deadline, not by anything. The async
;;; versions in src/transfer.lisp are built to be cancellable and are the better
;;; choice in a threaded program; these are the better choice in a script.

(in-package #:libusb)

(defvar *default-timeout* 1000
  "Default transfer timeout in milliseconds.

1000, not 0. libusb reads 0 as \"block forever\", and a library whose default is
an uninterruptible foreign call is a library that hangs the REPL the first time a
device stops answering.")

(deftype octet-vector () '(simple-array (unsigned-byte 8) (*)))

(defmacro with-octets-pointer ((pointer vector &key (start 0) end) &body body)
  "Bind POINTER to VECTOR's bytes for the extent of BODY.

Pins the vector when it is already a SIMPLE-ARRAY (UNSIGNED-BYTE 8), which is
zero-copy on SBCL, and copies into freshly allocated foreign memory otherwise.
Safe here and only here: pinning in SBCL is dynamic-extent, so it covers a
blocking call that returns before this form does. An asynchronous transfer, whose
buffer must survive until a callback on another thread at an unknown later time,
cannot use this -- see the commentary in src/transfer.lisp."
  (let ((v (gensym "VECTOR")) (s (gensym "START")) (e (gensym "END"))
        (raw (gensym "RAW")) (len (gensym "LENGTH")) (i (gensym "I")))
    `(let* ((,v ,vector) (,s ,start) (,e (or ,end (length ,v)))
            (,len (- ,e ,s)))
       (if (typep ,v 'octet-vector)
           (cffi:with-pointer-to-vector-data (,raw ,v)
             (let ((,pointer (cffi:inc-pointer ,raw ,s)))
               ,@body))
           (cffi:with-foreign-object (,pointer :uint8 (max ,len 1))
             (dotimes (,i ,len)
               (setf (cffi:mem-aref ,pointer :uint8 ,i) (aref ,v (+ ,s ,i))))
             ,@body)))))

(defun octets-from-pointer (pointer count &key into)
  "COUNT bytes from POINTER as a fresh octet vector, or copied INTO one."
  (let ((v (or into (make-array count :element-type '(unsigned-byte 8)))))
    (dotimes (i count v)
      (setf (aref v i) (cffi:mem-aref pointer :uint8 i)))))

(defun request-type (&key (direction :out) (type :standard) (recipient :device))
  "Assemble a bmRequestType byte.

Bit 7 is the direction, bits 5:6 the type and bits 0:4 the recipient. Worth a
function so that no caller has to remember which, and so that CONTROL-TRANSFER's
keywords have one place to be turned into a byte."
  (logior (cffi:foreign-enum-value 'libusb-endpoint-direction direction)
          (cffi:foreign-enum-value 'libusb-request-type type)
          (cffi:foreign-enum-value 'libusb-request-recipient recipient)))

;;; --- control ------------------------------------------------------------

(defun control-transfer (handle &key (direction :out) (type :standard)
                                     (recipient :device) request-type
                                     (request 0) (value 0) (index 0)
                                     data length
                                     (timeout *default-timeout*) (errorp t))
  "One synchronous control transfer on endpoint 0.

DIRECTION, TYPE and RECIPIENT are assembled into bmRequestType unless
REQUEST-TYPE is given explicitly, in which case it is used verbatim.

Supply :DATA (an octet vector) for an OUT transfer or :LENGTH for an IN transfer.
Supplying both is an error rather than a guess, because which one was meant
decides the direction bit and guessing wrong sends the device garbage.

Returns (VALUES RESULT STATUS): the transferred count for OUT, a fresh octet
vector of exactly what arrived for IN, and STATUS one of :COMPLETED or :TIMEOUT.
A timeout does not signal even with ERRORP true -- libusb fills in the partial
count on its way out, so a short transfer plus :TIMEOUT is the truth about what
reached the device, and unwinding would discard it. Everything else signals."
  (check-handle handle 'control-transfer)
  (when (and data length)
    (usage-error "CONTROL-TRANSFER takes :DATA or :LENGTH, not both: which one ~
                  decides the direction of the transfer."))
  ;; :DATA means an OUT transfer and :LENGTH an IN one; DIRECTION is only
  ;; consulted when neither was given, which is a zero-length control transfer
  ;; such as SET_CONFIGURATION.
  (let ((bm-request-type (or request-type
                             (request-type :direction (cond (data :out)
                                                            (length :in)
                                                            (t direction))
                                           :type type :recipient recipient)))
        (out-p (and data t)))
    (flet ((run (pointer count)
             (let ((rc (%libusb-control-transfer (handle-pointer handle)
                                                bm-request-type request value index
                                                pointer count timeout)))
               (cond ((= rc -7)          ; LIBUSB_ERROR_TIMEOUT
                      ;; libusb's synchronous control transfer reports no partial
                      ;; count on timeout -- unlike bulk and interrupt, it has
                      ;; nowhere to put one -- so there is nothing to salvage but
                      ;; the fact of the timeout.
                      (values 0 :timeout))
                     ((minusp rc)
                      (if errorp
                          (check-result rc '%libusb-control-transfer)
                          (values nil (error-code-keyword rc))))
                     (t (values rc :completed))))))
      (cond (out-p
             (with-octets-pointer (pointer data)
               (run pointer (length data))))
            (t
             (let ((count (or length 0)))
               (cffi:with-foreign-object (pointer :uint8 (max count 1))
                 (multiple-value-bind (rc status) (run pointer count)
                   (values (and rc (octets-from-pointer pointer rc)) status)))))))))

;;; --- bulk and interrupt -------------------------------------------------

(macrolet
    ((define-transfer-pair (read-name write-name binding kind)
       `(progn
          (defun ,write-name (handle endpoint data
                              &key (start 0) end (timeout *default-timeout*)
                                   (errorp t))
            ,(format nil "Write DATA to ~A ENDPOINT. Returns (VALUES COUNT STATUS).~@
~@
STATUS is :COMPLETED or :TIMEOUT, and a timeout does not signal: libusb reports~@
how much reached the device before giving up, and a short write plus :TIMEOUT is~@
more useful than an unwind. A stall, a vanished device or a refused endpoint all~@
signal." kind)
            (check-handle handle ',write-name)
            (let ((end (or end (length data))))
              (cffi:with-foreign-object (transferred :int)
                (with-octets-pointer (pointer data :start start :end end)
                  (let ((rc (,binding (handle-pointer handle) endpoint pointer
                                      (- end start) transferred timeout)))
                    (let ((count (cffi:mem-ref transferred :int)))
                      (cond ((= rc -7) (values count :timeout))
                            ((minusp rc)
                             (if errorp
                                 (check-result rc ',binding
                                               (format nil "endpoint #x~2,'0X"
                                                       endpoint))
                                 (values count (error-code-keyword rc))))
                            (t (values count :completed)))))))))

          (defun ,read-name (handle endpoint length
                             &key into (timeout *default-timeout*) (errorp t))
            ,(format nil "Read up to LENGTH bytes from ~A ENDPOINT.~@
~@
Returns (VALUES OCTETS STATUS COUNT). OCTETS is a fresh vector of exactly the~@
bytes that arrived, unless INTO is given, in which case it is INTO itself and~@
COUNT says how much of it is valid. STATUS is :COMPLETED or :TIMEOUT, and a~@
timeout is not an error: an interrupt endpoint with nothing to say times out by~@
design, and a bulk read from an idle device does too." kind)
            (check-handle handle ',read-name)
            (cffi:with-foreign-object (transferred :int)
              (cffi:with-foreign-object (pointer :uint8 (max length 1))
                (let* ((rc (,binding (handle-pointer handle) endpoint pointer
                                     length transferred timeout))
                       (count (cffi:mem-ref transferred :int)))
                  (flet ((data () (octets-from-pointer pointer count :into into)))
                    (cond ((= rc -7) (values (data) :timeout count))
                          ((minusp rc)
                           (if errorp
                               (check-result rc ',binding
                                             (format nil "endpoint #x~2,'0X" endpoint))
                               (values (data) (error-code-keyword rc) count)))
                          (t (values (data) :completed count)))))))))))

  (define-transfer-pair bulk-read bulk-write %libusb-bulk-transfer "bulk")
  (define-transfer-pair interrupt-read interrupt-write %libusb-interrupt-transfer
    "interrupt"))
