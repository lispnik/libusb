;;; An FTDI FT232R USB-serial chip, driven directly: no FTDI driver, no serial port.
;;;
;;; Run it with:
;;;
;;;   sbcl --noinform --non-interactive --no-userinit --no-sysinit \
;;;     --eval '(require :asdf)' \
;;;     --eval '(asdf:initialize-source-registry `(:source-registry (:also-exclude "vendor") (:tree ,(truename "./")) :ignore-inherited-configuration))' \
;;;     --eval '(asdf:load-system :libusb)' --load examples/ft232r.lisp
;;;
;;; By default it only reads: the descriptors, the EEPROM (checksum verified), the modem
;;; lines and the pin states. Nothing it does that way can disturb whatever is attached.
;;;
;;; FT232R_DRIVE=1 adds the two tests that drive the pins -- a bit-bang self-test and a
;;; serial transmit -- and is for a chip with NOTHING wired to it but, optionally, a
;;; TX-RX loopback jumper. Both put signals on the wires: the bit-bang test toggles TX,
;;; RTS# and DTR# (DTR resets many boards), and the serial test sends a line of text.
;;; This example was first run with the demo on by default against an FT232R that was
;;; still wired to a PPP peer, and that peer received both. Unplug first.
;;;
;;; FT232R_SERIAL picks one chip when several are attached; FT232R_BAUD sets the serial
;;; test's rate (default 115200). The bit-bang test checks itself by reading the pins
;;; back; the serial test checks what comes back on RX if TX is jumpered to it.
;;;
;;; This is the example for control transfers in both directions, bulk OUT, and a bulk
;;; IN endpoint whose packets carry a header. FTDI's protocol is vendor requests on
;;; endpoint 0 plus two bulk endpoints, as libftdi and pyftdi document it:
;;;
;;;   0x00 RESET          0 resets the chip, 1 purges RX, 2 purges TX
;;;   0x03 SET_BAUDRATE   an encoded divisor of 3 MHz, split across wValue and wIndex
;;;   0x04 SET_DATA       data bits, parity and stop bits
;;;   0x05 POLL_MODEM     2 bytes: CTS, DSR, RI, DCD, and line status
;;;   0x09/0x0A SET/GET_LATENCY_TIMER  how long a partly-filled IN packet waits
;;;   0x0B SET_BITMODE    wValue = mode << 8 | output mask
;;;   0x0C READ_PINS      1 byte: the instantaneous state of D0-D7
;;;   0x90 READ_EEPROM    one 16-bit word per request, wIndex its address
;;;
;;; Every bulk IN packet begins with the same two modem-status bytes as POLL_MODEM,
;;; data or not -- with nothing to send, the chip still sends a 2-byte packet every
;;; latency period. So a reader strips two bytes from the front of every 64-byte packet,
;;; which is the whole of the FTDI framing.
;;;
;;; On macOS FTDI's DriverKit driver binds the interface but only takes it when
;;; /dev/cu.usbserial-* is opened, so claiming works without root while that port is
;;; closed. On Linux ftdi_sio holds it; this detaches it for the duration and gives it
;;; back afterwards.
;;;
;;; What is written here was checked against a real FT232R (serial AB9H6LMZ) on macOS:
;;; the EEPROM checksum below matched the stored one. The bit-bang test drives only the
;;; pins that read high at idle, never one something else is already holding low -- a
;;; precaution, not a licence: a pin idling high can still be wired to something.

(in-package #:libusb)

(defconstant +ftdi-vendor-id+ #x0403)
(defconstant +ft232r-product-id+ #x6001)
(defconstant +ftdi-in+ #x81)
(defconstant +ftdi-out+ #x02)
;; The chip's one port. Single-port chips accept 0 or 1; libftdi and pyftdi send 1.
(defconstant +ftdi-port+ 1)

(defun ftdi-out (handle request &key (value 0) (index +ftdi-port+))
  (control-transfer handle :direction :out :type :vendor :recipient :device
                           :request request :value value :index index :timeout 1000))

(defun ftdi-in (handle request length &key (value 0) (index +ftdi-port+))
  (control-transfer handle :type :vendor :recipient :device :request request
                           :value value :index index :length length :timeout 1000))

;;; --- identity ----------------------------------------------------------

(defun read-eeprom (handle)
  "The FT232R's internal EEPROM: 64 little-endian 16-bit words."
  (loop for address below 64
        collect (let ((word (ftdi-in handle #x90 2 :index address)))
                  (logior (aref word 0) (ash (aref word 1) 8)))))

(defun eeprom-checksum (words)
  "FTDI's checksum over all but the last word: XOR each in, then rotate left one."
  (let ((checksum #xaaaa))
    (dolist (word (butlast words) checksum)
      (setf checksum (logxor checksum word)
            checksum (logand #xffff (logior (ash checksum 1) (ash checksum -15)))))))

(defun eeprom-string (words descriptor)
  "A string the EEPROM stores as a USB string descriptor. DESCRIPTOR's low byte is its
byte offset (the top bit set, meaning 'in EEPROM'), its high byte the length."
  (let* ((offset (logand descriptor #x7f))
         (length (ash descriptor -8)))
    (coerce (loop for byte from (+ offset 2) below (+ offset length) by 2
                  collect (code-char (nth (floor byte 2) words)))
            'string)))

(defparameter *cbus-functions*
  #("TXDEN" "PWREN#" "RXLED#" "TXLED#" "TX&RXLED#" "SLEEP#" "CLK48" "CLK24" "CLK12"
    "CLK6" "IOMODE" "BITBANG_WR#" "BITBANG_RD#"))

(defun identify (handle)
  (let* ((device (handle-device handle))
         (descriptor (device-descriptor device))
         (words (read-eeprom handle))
         (checksum (eeprom-checksum words)))
    (format t "~&FT232R ~4,'0X:~4,'0X release ~A, ~A / ~A / ~A~%"
            (device-descriptor-vendor-id descriptor) (device-descriptor-product-id descriptor)
            (bcd-version-string (device-descriptor-device-version descriptor))
            (manufacturer handle) (product handle) (serial-number handle))
    (format t "EEPROM checksum ~4,'0X, stored ~4,'0X: ~:[MISMATCH~;ok~]~%"
            checksum (nth 63 words) (= checksum (nth 63 words)))
    (format t "  strings in EEPROM: ~S ~S ~S~%"
            (eeprom-string words (nth 7 words)) (eeprom-string words (nth 8 words))
            (eeprom-string words (nth 9 words)))
    (let ((config (ldb (byte 8 0) (nth 4 words))) (power (ldb (byte 8 8) (nth 4 words))))
      (format t "  ~:[bus~;self~]-powered~:[~;, remote wakeup~], up to ~D mA~%"
              (logbitp 6 config) (logbitp 5 config) (* 2 power)))
    (format t "  CBUS0-4: ~{~A~^ ~}~%"
            (loop for nibble in (list (ldb (byte 4 0) (nth 10 words)) (ldb (byte 4 4) (nth 10 words))
                                      (ldb (byte 4 8) (nth 10 words)) (ldb (byte 4 12) (nth 10 words))
                                      (ldb (byte 4 0) (nth 11 words)))
                  collect (if (< nibble (length *cbus-functions*)) (aref *cbus-functions* nibble) nibble)))))

;;; --- modem lines and pins -------------------------------------------------

(defun describe-modem-status (status)
  (let ((b0 (aref status 0)) (b1 (aref status 1)))
    (format nil "CTS ~:[off~;ON~]  DSR ~:[off~;ON~]  RI ~:[off~;ON~]  DCD ~:[off~;ON~]~@[  line errors ~A~]"
            (logbitp 4 b0) (logbitp 5 b0) (logbitp 6 b0) (logbitp 7 b0)
            (let ((errors (remove nil (list (and (logbitp 1 b1) "overrun") (and (logbitp 2 b1) "parity")
                                            (and (logbitp 3 b1) "framing") (and (logbitp 4 b1) "break")))))
              (and errors (format nil "~{~A~^, ~}" errors))))))

(defun read-pins (handle) (aref (ftdi-in handle #x0c 1) 0))

(defun lines (handle)
  (format t "~&Modem status: ~A~%" (describe-modem-status (ftdi-in handle #x05 2)))
  (format t "Pins D7..D0 ~8,'0B  (RI# DCD# DSR# DTR# CTS# RTS# RXD TXD)~%" (read-pins handle))
  (format t "Latency timer ~D ms~%" (aref (ftdi-in handle #x0a 1) 0)))

;;; --- bit-bang ----------------------------------------------------------

(defun set-bitmode (handle mode mask)
  (ftdi-out handle #x0b :value (logior (ash mode 8) mask)))

(defun bitbang-self-test (handle)
  "Drive each free pin high then low in asynchronous bit-bang mode, reading every
pattern back with READ_PINS. Needs no wiring: a pin driven as an output reads what it
is driving. 'Free' means reading high at idle -- a pin something else holds low is
left an input, never driven against it. (On the FT232R this was written against, CTS#
read low for as long as a PPP peer on the other end of the cable held its RTS up, and
high once the peer was power-cycled: a pin's idle level says what is attached right
now, not whether anything is.)"
  (let* ((idle (read-pins handle))
         (free (loop for bit below 8 when (logbitp bit idle) collect bit))
         (mask (reduce #'logior (mapcar (lambda (bit) (ash 1 bit)) free)))
         (failures 0))
    (format t "~&Bit-bang: driving D~{~D~^,~} (mask ~8,'0B); leaving the rest as inputs~%" free mask)
    (unwind-protect
         (progn
           (set-bitmode handle #x01 mask)      ; asynchronous bit-bang
           (dolist (pattern (append (list 0 mask)
                                    (mapcar (lambda (bit) (ash 1 bit)) free)
                                    (list (logand mask #b01010101) (logand mask #b10101010))))
             (bulk-out handle +ftdi-out+ (vector pattern) :timeout 1000)
             (sleep 0.01)
             (let ((read (logand mask (read-pins handle))))
               (format t "  wrote ~8,'0B read ~8,'0B ~:[FAIL~;ok~]~%" pattern read (= read pattern))
               (unless (= read pattern) (incf failures)))))
      ;; Back to the UART, whatever happened: a chip left in bit-bang mode is not a
      ;; serial port until something resets it. In asynchronous bit-bang the chip
      ;; samples the pins into its receive buffer continuously, and nobody reads them,
      ;; so it overruns; purge it, or the overrun bit stays set in every status byte.
      (set-bitmode handle #x00 0)
      (ftdi-out handle #x00 :value 1))
    (format t "  ~:[all patterns read back correctly~;~:*~D pattern~:P did not read back~]~%"
            (and (plusp failures) failures))
    (zerop failures)))

;;; --- serial ------------------------------------------------------------

(defun baud-divisor (baud)
  "(VALUES WVALUE WINDEX) for SET_BAUDRATE on an FT232R, as libftdi computes it: a
divisor of 3 MHz in eighths, the fraction encoded in bits 14-16 by a table that is
not in order, and 3 and 2 Mbaud as special cases."
  (let* ((divisor (floor (+ 24000000 (floor baud 2)) baud)) ; in eighths
         (encoded (cond ((= divisor 8) 0)                   ; 3 Mbaud
                        ((= divisor 12) 1)                  ; 2 Mbaud
                        (t (logior (ash divisor -3)
                                   (ash (aref #(0 3 2 4 1 5 6 7) (logand divisor 7)) 14))))))
    (values (ldb (byte 16 0) encoded) (ash encoded -16))))

(defun ftdi-read (handle &key (seconds 0.3))
  "Everything the chip sends for SECONDS, with the two modem-status bytes stripped from
the front of every packet. Returns (VALUES DATA PACKETS LAST-STATUS)."
  (let ((data (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (packets 0) (status nil)
        (deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) deadline)
          do (multiple-value-bind (octets result) (bulk-in handle +ftdi-in+ 64 :timeout 100)
               (when (and (eq result :completed) (>= (length octets) 2))
                 (incf packets)
                 (setf status (subseq octets 0 2))
                 (loop for i from 2 below (length octets) do (vector-push-extend (aref octets i) data)))))
    (values data packets status)))

(defun serial-test (handle &key (baud 115200))
  (multiple-value-bind (value index) (baud-divisor baud)
    (ftdi-out handle #x00 :value 0)                  ; reset
    ;; On a single-port chip wIndex is the divisor's 17th bit and nothing else; only
    ;; the multi-port chips put a port number in it too.
    (ftdi-out handle #x03 :value value :index index)
    (ftdi-out handle #x04 :value #x0008)             ; 8 data bits, no parity, 1 stop
    (ftdi-out handle #x09 :value 2)                  ; 2 ms latency, for a prompt read
    (ftdi-out handle #x00 :value 1)                  ; purge RX
    (format t "~&Serial: ~D 8N1 (divisor wValue ~4,'0X wIndex ~D)~%" baud value index))
  (let* ((message (format nil "hello from Lisp over libusb, ~D~%" (get-universal-time)))
         (octets (map '(vector (unsigned-byte 8)) #'char-code message)))
    (multiple-value-bind (count result) (bulk-out handle +ftdi-out+ octets :timeout 1000)
      (format t "  sent ~D of ~D bytes on TX: ~(~A~) -- the TX LED should have blinked~%"
              count (length octets) result))
    (multiple-value-bind (data packets status) (ftdi-read handle)
      (format t "  read ~D bulk IN packet~:P in 0.3 s, each led by 2 status bytes: ~A~%"
              packets (if status (describe-modem-status status) "none"))
      (cond ((equalp data octets)
             (format t "  loopback: every byte came back on RX -- TX is jumpered to RX~%"))
            ((zerop (length data))
             (format t "  nothing came back on RX (no TX-RX jumper: expected)~%"))
            (t (format t "  RX received ~D byte~:P that do not match what was sent: ~S~%"
                       (length data) (map 'string #'code-char data))))))
  (ftdi-out handle #x09 :value 16))                  ; the latency timer back to its default

;;; --- all of it ---------------------------------------------------------

(let* ((serial (uiop:getenv "FT232R_SERIAL"))
       (drive (equal "1" (uiop:getenv "FT232R_DRIVE")))
       (baud (or (ignore-errors (parse-integer (uiop:getenv "FT232R_BAUD"))) 115200)))
  (with-context (context)
    (let ((device (find-if (lambda (device)
                             (or (null serial)
                                 (with-device-handle (handle device)
                                   (equal serial (serial-number handle)))))
                           (find-devices :context context :vendor-id +ftdi-vendor-id+
                                         :product-id +ft232r-product-id+))))
      (unless device
        (error "No FT232R (~4,'0X:~4,'0X)~@[ with serial ~A~] is attached."
               +ftdi-vendor-id+ +ft232r-product-id+ serial))
      (with-device-handle (handle device)
        (identify handle)
        (lines handle)
        (if (not drive)
            (format t "~&~%Read-only. FT232R_DRIVE=1 adds the bit-bang and serial tests, which put ~
                       signals on TX, RTS# and DTR# --~%set it only with nothing wired to the chip.~%")
            ;; Detaching is Linux's ftdi_sio; on macOS the driver lets go by itself
            ;; while its serial port is closed, and detaching is not needed.
            (let ((detached (and (kernel-driver-active-p handle 0)
                                 (ignore-errors (detach-kernel-driver handle 0)))))
              (unwind-protect
                   (handler-case
                       (with-claimed-interface (handle 0)
                         (bitbang-self-test handle)
                         (serial-test handle :baud baud))
                     ;; The usual cause is the chip's serial port being open -- on macOS
                     ;; FTDI's driver takes the interface only then -- so say so rather
                     ;; than print a bare LIBUSB_ERROR_ACCESS.
                     ((or libusb-access-error libusb-busy) (condition)
                       (format t "~&~%Could not claim the FT232R's interface (~A). Is its serial ~
                                  port open -- a terminal, or pppd on /dev/cu.usbserial-~A?~%"
                               condition (serial-number handle))))
                (when detached (ignore-errors (attach-kernel-driver handle 0))))))))))
