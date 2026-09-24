;;; A working IEEE 802.15.4 / Zigbee sniffer on a TI CC2531 USB dongle.
;;;
;;;   CC2531_CHANNEL=25 CC2531_SECONDS=15 CC2531_OUTPUT=/tmp/zigbee.pcap \
;;;   sbcl --noinform --non-interactive --no-userinit --no-sysinit \
;;;     --eval '(require :asdf)' \
;;;     --eval '(asdf:initialize-source-registry `(:source-registry (:also-exclude "vendor") (:tree ,(truename "./")) :ignore-inherited-configuration))' \
;;;     --eval '(asdf:load-system :libusb)' --load examples/cc2531-sniffer.lisp
;;;
;;; Needs write access to the device node: root, or a udev rule. Channels are 11-26.
;;; The output is a pcap file in the IEEE 802.15.4 TAP encapsulation, so Wireshark shows
;;; the per-frame RSSI, channel and link quality alongside the decode.
;;;
;;; This is also the example that exercises the parts of the library nothing else does:
;;; several transfers in flight at once, each resubmitted from its own completion
;;; callback, which is the streaming idiom the transfer registry exists for.
;;;
;;; ---------------------------------------------------------------------------
;;; The firmware, and how to tell
;;;
;;; A CC2531 is useless as a sniffer unless it carries TI's packet-sniffer firmware.
;;; Flashed with the zigbee2mqtt coordinator firmware instead it presents two CDC
;;; interfaces and a serial port, and none of what follows applies. The two are
;;; distinguishable before sending anything: the sniffer firmware has exactly one
;;; vendor-specific interface with one bulk IN endpoint at 0x83, and answers a vendor IN
;;; request 0xC0 with an 8-byte identity. On the dongle this was written against:
;;;
;;;   interface 0 alt 0 class :VENDOR-SPEC: 83/in/bulk/64
;;;   vendor IN 0xC0 GET_IDENT -> 31 25 31 05 02 00 01 00
;;;
;;; ---------------------------------------------------------------------------
;;; The stream format, read off the wire rather than out of a datasheet
;;;
;;; Every bulk read yields one message: a 3-byte header of a type byte and a
;;; little-endian length, then the body. Type 0x01 is a 1-byte timer heartbeat. Type 0x00
;;; is a captured frame: a 32-bit little-endian timestamp in units of 1/32 us, a length
;;; byte, and that many bytes of 802.15.4 -- except that the radio has overwritten the
;;; frame's two-byte FCS with a signed RSSI and a status byte whose top bit is CRC-OK.
;;;
;;; A real 72-byte message, split up:
;;;
;;;   00        type: a captured frame
;;;   45 00     69 bytes follow
;;;   9A 56 09 00   timestamp 612506, so 19140.8 us
;;;   40        64 bytes of MAC frame and trailing status
;;;   80 C0 ... 10  62 bytes of 802.15.4
;;;   F2        RSSI -14 dBm
;;;   D4        top bit set: the CRC checked out
;;;
;;; That parse is not a guess. In a twelve-message capture one frame arrived with a
;;; single flipped byte and its status byte was 0x54 rather than 0xD4 -- CRC-OK clear,
;;; exactly where this layout says it should be.

(in-package #:libusb)

(defconstant +cc2531-vendor-id+ #x0451)
(defconstant +cc2531-product-id+ #x16ae)

;;; Vendor requests. Direction, type and recipient are assembled by REQUEST-TYPE.
(defconstant +get-ident+ #xc0)
(defconstant +set-power+ #xc5)
(defconstant +get-power+ #xc6)
(defconstant +set-start+ #xd0)
(defconstant +set-end+   #xd1)
(defconstant +set-chan+  #xd2)

(defconstant +power-on+ #x04)

;;; LINKTYPE_IEEE802_15_4_TAP. The plain 802.15.4 link types (195 with FCS, 230 without)
;;; carry the frame and nothing else, which would throw away the two things the radio
;;; tells us about every frame: how strong it was and how well it correlated. TAP prefixes
;;; each frame with a small TLV header that Wireshark reads into named fields.
;;;
;;; The FCS type is declared as None rather than 16-bit CRC, because there is no FCS left
;;; to declare -- the radio overwrote it with RSSI and status. Recomputing a CRC over the
;;; bytes we received and presenting it as the frame's own would be inventing data, and
;;; would be a lie precisely for the frames where it matters, the corrupt ones.
;;;
;;; The TLV numbers and layout here were not taken on trust: a candidate file was fed to
;;; tshark until it named every field, which is how the LQI type below is 10 and not the
;;; 9 or 11 that were tried alongside it.
(defconstant +dlt-ieee802-15-4-tap+ 283)
(defconstant +tap-tlv-fcs-type+ 0)
(defconstant +tap-tlv-rss+ 1)
(defconstant +tap-tlv-channel+ 3)
(defconstant +tap-tlv-lqi+ 10)
(defconstant +tap-fcs-none+ 0)

(defun getenv-integer (name default)
  (let ((value (uiop:getenv name)))
    (or (and value (ignore-errors (parse-integer value :junk-allowed t))) default)))

(defparameter *channel* (getenv-integer "CC2531_CHANNEL" 25))
(defparameter *seconds* (getenv-integer "CC2531_SECONDS" 15))
(defparameter *output* (or (uiop:getenv "CC2531_OUTPUT") "/tmp/zigbee.pcap"))
(defparameter *include-bad-crc*
  (let ((value (uiop:getenv "CC2531_INCLUDE_BAD_CRC")))
    (and value (string/= value "") (string/= value "0")))
  "Whether frames the radio says failed CRC go into the capture file.

Off by default, and the reason is worth stating because a sniffer hiding interference is
usually the wrong trade. A frame that failed CRC contains bytes that are known to differ
from what was transmitted, and a dissector has no way to know that -- during the run this
example was written against, one corrupt beacon decoded as a *different* device, its
extended address off by a single byte from the real one. Handing that to Wireshark
manufactures a device that does not exist.

The count is always reported, so the interference is never hidden, only kept out of the
decode. Set CC2531_INCLUDE_BAD_CRC=1 when the corrupt frames are the thing being
investigated -- but note that TAP has no CRC-validity TLV, so once they are in the file
nothing distinguishes them.")

(defparameter *in-flight* 8
  "Transfers queued on the endpoint at once.

More than one matters for a sniffer: with a single transfer there is a window between a
completion and its resubmission during which the dongle has nowhere to put a frame, and
what it does then is drop it silently. Eight 256-byte transfers is far more slack than
802.15.4's 250 kbit/s can consume.")

;;; --- the dongle --------------------------------------------------------

(defun vendor-out (handle request &key (value 0) (index 0) data)
  (control-transfer handle :request-type (request-type :direction :out :type :vendor
                                                      :recipient :device)
                           :request request :value value :index index
                           :data (or data #()) :timeout 1000))

(defun vendor-in (handle request length &key (value 0) (index 0))
  (control-transfer handle :type :vendor :recipient :device :request request
                           :value value :index index :length length :timeout 1000))

(defun radio-on (handle)
  "Power the radio and wait for the dongle to confirm. Returns the power register.

The wait is not optional: SET_POWER returns as soon as the request is accepted, and a
channel set before the radio has come up is silently ignored."
  (vendor-out handle +set-power+ :index +power-on+)
  (loop repeat 50
        for power = (aref (vendor-in handle +get-power+ 1) 0)
        when (= power +power-on+) return power
        do (sleep 0.05)
        finally (error "the CC2531 radio did not power up (register ~D)" power)))

(defun set-channel (handle channel)
  "Tune to CHANNEL. Low byte at wIndex 0, high byte at wIndex 1 -- two requests, not one."
  (assert (<= 11 channel 26) (channel) "802.15.4 channels are 11 to 26, not ~D." channel)
  (vendor-out handle +set-chan+ :index 0 :data (vector (logand channel #xff)))
  (vendor-out handle +set-chan+ :index 1 :data (vector (ash channel -8))))

;;; --- pcap --------------------------------------------------------------

(defun write-u16 (stream value)
  (write-byte (logand value #xff) stream)
  (write-byte (logand (ash value -8) #xff) stream))

(defun write-u32 (stream value)
  (write-u16 stream (logand value #xffff))
  (write-u16 stream (logand (ash value -16) #xffff)))

(defun write-pcap-header (stream &key (snaplen 256))
  (write-u32 stream #xa1b2c3d4)         ; magic, little-endian, microsecond timestamps
  (write-u16 stream 2)                  ; version major
  (write-u16 stream 4)                  ; version minor
  (write-u32 stream 0)                  ; thiszone
  (write-u32 stream 0)                  ; sigfigs
  (write-u32 stream snaplen)
  (write-u32 stream +dlt-ieee802-15-4-tap+))

(defun float32-octets (value)
  "VALUE as four little-endian IEEE 754 single-precision bytes.

Through CFFI rather than an implementation's float-bits accessor, since CFFI is already
a dependency and this way the host does the encoding."
  (cffi:with-foreign-object (pointer :float)
    (setf (cffi:mem-ref pointer :float) (float value 1.0))
    (let ((octets (make-array 4 :element-type '(unsigned-byte 8))))
      (dotimes (i 4 octets)
        (setf (aref octets i) (cffi:mem-aref pointer :uint8 i))))))

(defun tap-tlv (type value)
  "One TAP TLV: type and length as little-endian 16-bit, then VALUE padded to 4 bytes."
  (let* ((padding (mod (- (length value)) 4))
         (octets (make-array (+ 4 (length value) padding)
                             :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref octets 0) (logand type #xff)
          (aref octets 1) (ash type -8)
          (aref octets 2) (logand (length value) #xff)
          (aref octets 3) (ash (length value) -8))
    (replace octets value :start1 4)
    octets))

(defun tap-header (&key channel rssi lqi)
  "The TAP metadata that precedes a frame."
  (let ((tlvs (concatenate '(vector (unsigned-byte 8))
                           (tap-tlv +tap-tlv-fcs-type+ (vector +tap-fcs-none+))
                           (tap-tlv +tap-tlv-rss+ (float32-octets rssi))
                           (tap-tlv +tap-tlv-channel+
                                    (vector (logand channel #xff) (ash channel -8) 0))
                           (tap-tlv +tap-tlv-lqi+ (vector lqi)))))
    (concatenate '(vector (unsigned-byte 8))
                 ;; version 0, reserved 0, then the total header length including TLVs.
                 (vector 0 0 (logand (+ 4 (length tlvs)) #xff)
                         (ash (+ 4 (length tlvs)) -8))
                 tlvs)))

(defun write-pcap-record (stream seconds microseconds octets)
  (write-u32 stream seconds)
  (write-u32 stream microseconds)
  (write-u32 stream (length octets))
  (write-u32 stream (length octets))
  (write-sequence octets stream))

;;; --- the capture -------------------------------------------------------

(defstruct capture
  stream
  (base-seconds 0) (base-microseconds 0)
  (first-tick nil)                      ; dongle counter at the first frame
  (previous-tick 0) (wraps 0)
  (frames 0) (bad-crc 0) (written 0) (ticks 0) (bytes 0)
  (rssi-sum 0)
  (channel 0))

(defun capture-timestamp (capture counter)
  "Wall-clock (VALUES SECONDS MICROSECONDS) for a dongle COUNTER reading.

The dongle counts 1/32 us ticks in 32 bits, so it wraps every 134 seconds; a reading
lower than the last one means it has. Anchoring to the host clock only at the first frame
keeps the intervals between frames exactly as the radio measured them rather than as a
Lisp process happened to notice them."
  (when (null (capture-first-tick capture))
    (setf (capture-first-tick capture) counter
          (capture-previous-tick capture) counter))
  (when (< counter (capture-previous-tick capture))
    (incf (capture-wraps capture)))
  (setf (capture-previous-tick capture) counter)
  (let* ((elapsed-ticks (- (+ counter (* (capture-wraps capture) (expt 2 32)))
                           (capture-first-tick capture)))
         (elapsed-us (floor elapsed-ticks 32))
         (total-us (+ (capture-base-microseconds capture) elapsed-us)))
    (multiple-value-bind (extra-seconds microseconds) (floor total-us 1000000)
      (values (+ (capture-base-seconds capture) extra-seconds) microseconds))))

(defun little-endian (octets start count)
  (loop for i below count
        sum (ash (aref octets (+ start i)) (* 8 i))))

(defun handle-message (capture octets)
  "Parse one USB message and, if it is a frame, write it to the capture."
  (when (< (length octets) 3) (return-from handle-message))
  (let ((type (aref octets 0))
        (body-length (little-endian octets 1 2)))
    (case type
      (1 (incf (capture-ticks capture)))
      (0
       ;; 4-byte counter, 1-byte length, then the frame. Refuse anything that does not
       ;; add up rather than reading past the end of a short read.
       (when (< body-length 5) (return-from handle-message))
       (when (< (length octets) (+ 3 body-length)) (return-from handle-message))
       (let* ((counter (little-endian octets 3 4))
              (frame-length (aref octets 7)))
         ;; Two of those bytes are RSSI and status, so a frame shorter than three is not
         ;; a frame at all.
         (when (< frame-length 3) (return-from handle-message))
         (when (< (length octets) (+ 8 frame-length)) (return-from handle-message))
         (let* ((mac (subseq octets 8 (+ 8 (- frame-length 2))))
                (rssi-byte (aref octets (+ 8 frame-length -2)))
                (status (aref octets (+ 8 frame-length -1)))
                (rssi (if (> rssi-byte 127) (- rssi-byte 256) rssi-byte))
                (crc-ok (logbitp 7 status)))
           (incf (capture-frames capture))
           (incf (capture-bytes capture) (length mac))
           (incf (capture-rssi-sum capture) rssi)
           (unless crc-ok (incf (capture-bad-crc capture)))
           ;; The timestamp is advanced for every frame, corrupt or not, so that excluding
           ;; one does not shift the clock for those that follow.
           (multiple-value-bind (seconds microseconds)
               (capture-timestamp capture counter)
             (when (or crc-ok *include-bad-crc*)
               (incf (capture-written capture))
               (write-pcap-record
                (capture-stream capture) seconds microseconds
                (concatenate '(vector (unsigned-byte 8))
                             ;; The low seven bits of the status byte are the radio's
                             ;; correlation value, which is what LQI means here.
                             (tap-header :channel (capture-channel capture)
                                         :rssi rssi
                                         :lqi (logand status #x7f))
                             mac))))))))))

(defun sniff (&key (channel *channel*) (seconds *seconds*) (output *output*))
  (with-open-file (stream output :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
    (write-pcap-header stream)
    (let ((capture (make-capture :stream stream
                                 :channel channel
                                 :base-seconds (- (get-universal-time)
                                                  (encode-universal-time 0 0 0 1 1 1970 0))
                                 :base-microseconds 0)))
      (with-open-device (handle :vendor-id +cc2531-vendor-id+
                                :product-id +cc2531-product-id+)
        (with-claimed-interface (handle 0)
          (let ((ident (vendor-in handle +get-ident+ 8)))
            (format t "~&CC2531 ident ~{~2,'0X~^ ~}, radio ~D, channel ~D~%"
                    (coerce ident 'list) (radio-on handle) channel))
          (set-channel handle channel)
          (let ((transfers '()))
            (unwind-protect
                 (with-event-pump ((handle-context handle) :tick 0.1)
                   (vendor-out handle +set-start+)
                   (dotimes (i *in-flight*)
                     (push (make-usb-transfer
                            handle :type :bulk :endpoint #x83 :length 256 :timeout 0
                            :function
                            (lambda (transfer)
                              ;; Runs on the pump thread. Parse, then hand the transfer
                              ;; straight back to libusb -- the endpoint should never be
                              ;; without one queued.
                              (when (eq :completed (transfer-status transfer))
                                (handle-message capture (transfer-data transfer)))
                              (when (member (transfer-status transfer)
                                            '(:completed :timed-out))
                                (submit-transfer transfer))))
                           transfers))
                   (mapc #'submit-transfer transfers)
                   (let ((deadline (+ (get-internal-real-time)
                                      (* seconds internal-time-units-per-second))))
                     (loop while (< (get-internal-real-time) deadline)
                           do (sleep 0.25)
                              (format t "~&~4D frame~:P, ~3D bad CRC, ~5D byte~:P~%"
                                      (capture-frames capture) (capture-bad-crc capture)
                                      (capture-bytes capture))))
                   ;; Stop the radio before the transfers, so nothing new arrives while
                   ;; they are being cancelled.
                   (vendor-out handle +set-end+)
                   ;; The callbacks resubmit, so they have to be told to stop first.
                   (dolist (transfer transfers)
                     (setf (transfer-function transfer) nil))
                   (dolist (transfer transfers)
                     (ignore-errors (cancel-transfer transfer :drain t :timeout 2))))
              (ignore-errors (vendor-out handle +set-end+))
              (ignore-errors (vendor-out handle +set-power+ :index 0))
              (mapc (lambda (transfer) (ignore-errors (free-usb-transfer transfer)))
                    transfers)))))
      (format t "~&~%wrote ~A~%  ~D frame~:P seen, ~D written, ~D failed CRC~:[ (excluded; set CC2531_INCLUDE_BAD_CRC=1 to keep them)~; (included)~]~%  ~D timer heartbeat~:P, mean RSSI ~:[n/a~;~:*~,1F~] dBm~%"
              output (capture-frames capture) (capture-written capture)
              (capture-bad-crc capture) *include-bad-crc*
              (capture-ticks capture)
              (and (plusp (capture-frames capture))
                   (/ (capture-rssi-sum capture) (float (capture-frames capture)))))
      (capture-frames capture))))

(sniff)
