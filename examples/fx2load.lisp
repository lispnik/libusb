;;; A firmware loader for the Cypress EZ-USB FX2 and FX2LP, as fxload and cycfx2prog do it.
;;;
;;; Run it with:
;;;
;;;   FX2_HEX=blink.hex sbcl --noinform --non-interactive --no-userinit --no-sysinit \
;;;     --eval '(require :asdf)' \
;;;     --eval '(asdf:initialize-source-registry `(:source-registry (:also-exclude "vendor") (:tree ,(truename "./")) :ignore-inherited-configuration))' \
;;;     --eval '(asdf:load-system :libusb)' --load examples/fx2load.lisp
;;;
;;; Without FX2_HEX it only reads: it finds the chip, reads CPUCS and the first bytes of
;;; program RAM, and changes nothing -- whatever firmware is running keeps running. With
;;; FX2_HEX it holds the 8051 in reset, writes the Intel HEX file into RAM, reads every
;;; byte back to check it, and releases reset so the new firmware starts.
;;;
;;; FX2_DEVICE=VID:PID picks the chip. Without it, the first of these is used:
;;;
;;;   04B4:8613  a bare FX2/FX2LP with no EEPROM: the chip's own default IDs
;;;   0925:3881  the 8-channel "24 MHz" logic analyzer clones
;;;   21A9:1001  the original Saleae Logic
;;;   1D50:608C  any of the above with sigrok's fx2lafw already loaded
;;;
;;; Writing request 0xA0 to a device that is not an FX2 does whatever that device's
;;; firmware does with an unknown vendor request, so FX2_DEVICE is for an ID you know to
;;; be one.
;;;
;;; This is the example for vendor control transfers that carry data in both
;;; directions, against a device with no firmware of its own. The protocol is one
;;; request, which the FX2's USB core decodes in hardware -- no 8051 code is involved,
;;; which is why it works on a chip whose RAM holds nothing yet:
;;;
;;;   0xA0 FIRMWARE LOAD  wValue = address, wIndex = 0
;;;                       OUT writes the data stage to that address, IN reads it back
;;;
;;; Loading is three steps of it. CPUCS is the register at 0xE600; its bit 0 holds the
;;; 8051 in reset, and the core accepts writes to it through 0xA0 so the host can stop
;;; the CPU, rewrite its program, and start it again:
;;;
;;;   1. write 01 to 0xE600         the CPU stops; RAM is now the host's to write
;;;   2. write each HEX record       and read it back, while nothing can change it
;;;   3. write 00 to 0xE600         the CPU starts at 0x0000
;;;
;;; Only the FX2LP's 16 KiB of main RAM (0x0000-0x3FFF) and its 512-byte scratch RAM
;;; (0xE000-0xE1FF) are accepted as targets. A record anywhere else would be a write to
;;; a control register or an endpoint buffer, which is not something a firmware image
;;; should do by accident. The original FX2 (CY7C68013, no A) has only 8 KiB; an image
;;; that does not fit it fails the read-back rather than running half-loaded.
;;;
;;; Each request carries at most 64 bytes, one EP0 packet. Larger data stages are legal
;;; and faster, but 16 KiB at 64 bytes a request is a few hundred control transfers and
;;; well under a second, and a loader that never depends on how much the core will take
;;; in one request has one fewer way to fail on a chip it has not met.
;;;
;;; Nothing here has yet been run against a real FX2. The HEX parser was checked against
;;; images SDCC 4.2 built; the USB half is unverified.

(in-package #:libusb)

(defconstant +fx2-firmware-load+ #xa0)
(defconstant +fx2-cpucs+ #xe600)
(defconstant +fx2-chunk+ 64)

(defparameter *fx2-known-ids*
  '((#x04b4 . #x8613) (#x0925 . #x3881) (#x21a9 . #x1001) (#x1d50 . #x608c)))

(defparameter *fx2-loadable-ranges*
  '((#x0000 . #x4000)                   ; main RAM, code and data
    (#xe000 . #xe200))                  ; scratch RAM, data only
  "Half-open address ranges a firmware image may write.")

;;; --- Intel HEX ----------------------------------------------------------------

(defun hex-octets (line start end path line-number)
  (handler-case
      (let ((octets (make-array (floor (- end start) 2) :element-type '(unsigned-byte 8))))
        (loop for i from start below end by 2
              for j from 0
              do (setf (aref octets j) (parse-integer line :start i :end (+ i 2) :radix 16)))
        octets)
    (error ()
      (error "~A:~D: not hexadecimal: ~S" path line-number line))))

(defun read-intel-hex (path)
  "Every data record in the Intel HEX file at PATH, as a list of (ADDRESS . OCTETS) in
file order. Stops at the end-of-file record. Signals on a bad checksum, a length that
disagrees with the record, or a record type a 64 KiB 8051 image has no use for."
  (with-open-file (in path)
    (loop for line = (read-line in nil)
          for line-number from 1
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          unless (zerop (length trimmed))
            do (unless (and (char= (char trimmed 0) #\:) (oddp (length trimmed)))
                 (error "~A:~D: not an Intel HEX record: ~S" path line-number line))
            and append
                (let* ((raw (hex-octets trimmed 1 (length trimmed) path line-number))
                       (count (aref raw 0))
                       (address (logior (ash (aref raw 1) 8) (aref raw 2)))
                       (type (aref raw 3)))
                  (unless (= (length raw) (+ count 5))
                    (error "~A:~D: the record says ~D data bytes but carries ~D"
                           path line-number count (- (length raw) 5)))
                  (unless (zerop (logand #xff (reduce #'+ raw)))
                    (error "~A:~D: bad checksum" path line-number))
                  (case type
                    (#x00 (list (cons address (subseq raw 4 (+ 4 count)))))
                    (#x01 (loop-finish))
                    (t (error "~A:~D: record type ~2,'0X; an FX2 image needs only 00 and 01"
                              path line-number type)))))))

(defun coalesce-records (records)
  "RECORDS with every run of contiguous addresses merged into one, sorted by address."
  (let ((sorted (sort (copy-list records) #'< :key #'car))
        (merged '()))
    (dolist (record sorted (nreverse merged))
      (let ((previous (first merged)))
        (if (and previous (= (car record) (+ (car previous) (length (cdr previous)))))
            (setf (cdr previous) (concatenate '(vector (unsigned-byte 8))
                                              (cdr previous) (cdr record)))
            (push (cons (car record) (cdr record)) merged))))))

(defun check-loadable (records)
  (dolist (record records)
    (let ((start (car record)) (end (+ (car record) (length (cdr record)))))
      (unless (some (lambda (range) (and (<= (car range) start) (<= end (cdr range))))
                    *fx2-loadable-ranges*)
        (error "The image writes ~4,'0X-~4,'0X, outside the FX2LP's RAM (~{~{~4,'0X-~4,'0X~}~^, ~})."
               start (1- end)
               (mapcar (lambda (range) (list (car range) (1- (cdr range))))
                       *fx2-loadable-ranges*))))))

;;; --- request 0xA0 -------------------------------------------------------------

(defun fx2-write (handle address octets)
  (loop for offset from 0 below (length octets) by +fx2-chunk+
        for chunk = (subseq octets offset (min (length octets) (+ offset +fx2-chunk+)))
        do (multiple-value-bind (count status)
               (control-transfer handle :type :vendor :recipient :device
                                        :request +fx2-firmware-load+
                                        :value (+ address offset) :data chunk :timeout 1000)
             (unless (and (eq status :completed) (= count (length chunk)))
               (error "Writing ~D byte~:P at ~4,'0X: ~(~A~), ~D written."
                      (length chunk) (+ address offset) status count)))))

(defun fx2-read (handle address length)
  (let ((octets (make-array length :element-type '(unsigned-byte 8))))
    (loop for offset from 0 below length by +fx2-chunk+
          for size = (min +fx2-chunk+ (- length offset))
          do (multiple-value-bind (chunk status)
                 (control-transfer handle :type :vendor :recipient :device
                                          :request +fx2-firmware-load+
                                          :value (+ address offset) :length size :timeout 1000)
               (unless (and (eq status :completed) (= (length chunk) size))
                 (error "Reading ~D byte~:P at ~4,'0X: ~(~A~), ~D read."
                        size (+ address offset) status (length chunk)))
               (replace octets chunk :start1 offset)))
    octets))

(defun fx2-cpu-reset (handle resetp)
  (fx2-write handle +fx2-cpucs+ (vector (if resetp 1 0))))

;;; --- the two modes ------------------------------------------------------------

(defun fx2-describe (handle)
  (let ((cpucs (aref (fx2-read handle +fx2-cpucs+ 1) 0))
        (ram (fx2-read handle #x0000 16)))
    (format t "~&CPUCS ~2,'0X: CPU ~:[running~;held in reset~], ~D MHz, CLKOUT ~:[off~;on~]~%"
            cpucs (logbitp 0 cpucs) (aref #(12 24 48 "reserved") (ldb (byte 2 3) cpucs))
            (logbitp 1 cpucs))
    (format t "RAM 0000: ~{~2,'0X~^ ~}~%" (coerce ram 'list))))

(defun fx2-load (handle path)
  (let* ((records (coalesce-records (read-intel-hex path)))
         (total (reduce #'+ records :key (lambda (record) (length (cdr record))))))
    (check-loadable records)
    (format t "~&~A: ~D byte~:P in ~D contiguous block~:P: ~{~{~4,'0X-~4,'0X~}~^ ~}~%"
            (file-namestring path) total (length records)
            (mapcar (lambda (r) (list (car r) (+ (car r) (length (cdr r)) -1))) records))
    (fx2-cpu-reset handle t)
    ;; Any failure from here on leaves the CPU in reset, on purpose: a stopped chip is
    ;; revived by a replug, while a half-written image would run from whatever bytes
    ;; happen to be in RAM.
    (dolist (record records)
      (fx2-write handle (car record) (cdr record)))
    (let ((mismatches
            (loop for (address . octets) in records
                  for read = (fx2-read handle address (length octets))
                  append (loop for i below (length octets)
                               unless (= (aref octets i) (aref read i))
                                 collect (list (+ address i) (aref octets i) (aref read i))))))
      (when mismatches
        (error "~D byte~:P did not read back, the CPU is left in reset~
                ~{~%  ~{~4,'0X: wrote ~2,'0X, read ~2,'0X~}~}~@[~%  ...~]"
               (length mismatches) (subseq mismatches 0 (min 8 (length mismatches)))
               (> (length mismatches) 8))))
    (format t "Read back ~D byte~:P: all match~%" total)
    (fx2-cpu-reset handle nil)
    (format t "CPU released from reset: the firmware is running~%")))

;;; --- all of it ----------------------------------------------------------------

(defun parse-vid-pid (string)
  (let ((colon (position #\: string)))
    (unless colon (error "FX2_DEVICE is VID:PID in hexadecimal, not ~S." string))
    (cons (parse-integer string :end colon :radix 16)
          (parse-integer string :start (1+ colon) :radix 16))))

(let* ((wanted (uiop:getenv "FX2_DEVICE"))
       (hex (uiop:getenv "FX2_HEX"))
       (ids (if wanted (list (parse-vid-pid wanted)) *fx2-known-ids*)))
  (when hex
    (unless (probe-file hex) (error "FX2_HEX names ~S, which does not exist." hex))
    ;; Parse and range-check before touching the device, so a bad file costs nothing.
    (check-loadable (coalesce-records (read-intel-hex hex))))
  (with-context (context)
    (let ((device (loop for (vid . pid) in ids
                        thereis (find-device :context context :vendor-id vid :product-id pid))))
      (unless device
        (error "No FX2 is attached (looked for ~{~{~4,'0X:~4,'0X~}~^, ~})."
               (mapcar (lambda (id) (list (car id) (cdr id))) ids)))
      (let ((descriptor (device-descriptor device)))
        (format t "~&FX2 at ~4,'0X:~4,'0X, bus ~D device ~D~%"
                (device-descriptor-vendor-id descriptor) (device-descriptor-product-id descriptor)
                (device-bus-number device) (device-address device)))
      (handler-case
          (with-device-handle (handle device)
            (if hex
                (fx2-load handle hex)
                (progn
                  (fx2-describe handle)
                  (format t "~&~%Read-only. FX2_HEX=file.hex loads that image and starts it, ~
                             replacing whatever the chip is running.~%"))))
        ;; On Linux this is nearly always the /dev/bus/usb node, not the device.
        (libusb-access-error (condition)
          (format t "~&~%Could not open the FX2 (~A). On Linux that is permission on its ~
                     /dev/bus/usb node: run under sudo, or add a udev rule.~%" condition))))))
