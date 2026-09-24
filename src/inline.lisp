;;; The header's static-inline functions, reimplemented in Lisp.
;;;
;;; Fifteen of libusb.h's entry points are `static inline' (and
;;; libusb_le16_to_cpu is a #define alias for libusb_cpu_to_le16), so there is no
;;; symbol in the shared library to bind -- they exist only in the compiled
;;; output of whoever included the header. A binding that left them out would
;;; leave a caller to reinvent the SETUP-packet layout and the iso packet
;;; arithmetic, which is exactly the sort of thing that is wrong once and then
;;; wrong forever, so they are rewritten here against the same struct
;;; definitions.
;;;
;;; They keep the %LIBUSB- prefix even though they are our code wearing C's
;;; name, because that is what a reader coming from libusb's documentation will
;;; look for.

(in-package #:libusb)

;;; --- byte order --------------------------------------------------------

(declaim (inline %libusb-cpu-to-le16 %libusb-le16-to-cpu))

(defun %libusb-cpu-to-le16 (x)
  "X with the byte order of a little-endian wire value.

Identity on every machine this library has run on; kept as a function rather
than elided because a USB descriptor field is little-endian by specification,
not by luck, and the day this is read on a big-endian host the conversion
should already be written."
  (declare (type (unsigned-byte 16) x))
  #+big-endian (logior (ash (ldb (byte 8 0) x) 8) (ldb (byte 8 8) x))
  #-big-endian x)

(defun %libusb-le16-to-cpu (x)
  "The inverse of %LIBUSB-CPU-TO-LE16, which is the same operation.
(libusb.h defines libusb_le16_to_cpu as an alias, for the same reason.)"
  (%libusb-cpu-to-le16 x))

;;; --- control transfer buffers ------------------------------------------

(defun %libusb-fill-control-setup (buffer bm-request-type b-request w-value
                                   w-index w-length)
  "Write a SETUP packet into the first 8 bytes of BUFFER.

A control transfer's buffer is the 8-byte SETUP packet followed by the data
stage, so BUFFER must be at least (+ 8 w-length) bytes long. Getting that wrong
is not a Lisp error -- it is libusb reading past the end of the allocation."
  (setf (cffi:foreign-slot-value buffer '(:struct libusb-control-setup) 'bm-request-type)
        bm-request-type
        (cffi:foreign-slot-value buffer '(:struct libusb-control-setup) 'b-request)
        b-request
        (cffi:foreign-slot-value buffer '(:struct libusb-control-setup) 'w-value)
        (%libusb-cpu-to-le16 w-value)
        (cffi:foreign-slot-value buffer '(:struct libusb-control-setup) 'w-index)
        (%libusb-cpu-to-le16 w-index)
        (cffi:foreign-slot-value buffer '(:struct libusb-control-setup) 'w-length)
        (%libusb-cpu-to-le16 w-length))
  buffer)

(defun %libusb-control-transfer-get-data (transfer)
  "A pointer to the data stage of a control TRANSFER's buffer: buffer + 8."
  (cffi:inc-pointer
   (cffi:foreign-slot-value transfer '(:struct libusb-transfer) 'buffer)
   +control-setup-size+))

(defun %libusb-control-transfer-get-setup (transfer)
  "A pointer to the SETUP packet at the head of a control TRANSFER's buffer."
  (cffi:foreign-slot-value transfer '(:struct libusb-transfer) 'buffer))

;;; --- filling a transfer ------------------------------------------------

(macrolet ((set-slots (transfer &body pairs)
             `(setf ,@(loop for (slot value) on pairs by #'cddr
                            append `((cffi:foreign-slot-value
                                      ,transfer '(:struct libusb-transfer) ',slot)
                                     ,value)))))

  (defun %libusb-fill-control-transfer (transfer dev-handle buffer callback
                                        user-data timeout)
    "Fill TRANSFER as a control transfer over BUFFER, which must already hold a
SETUP packet -- the length is taken from its wLength, exactly as libusb.h does."
    (set-slots transfer
               dev-handle dev-handle
               endpoint 0
               type (cffi:foreign-enum-value 'libusb-transfer-type :control)
               timeout timeout
               buffer buffer
               user-data user-data
               callback callback)
    (unless (cffi:null-pointer-p buffer)
      (set-slots transfer
                 length (+ +control-setup-size+
                           (%libusb-le16-to-cpu
                            (cffi:foreign-slot-value
                             buffer '(:struct libusb-control-setup) 'w-length)))))
    transfer)

  (defun %libusb-fill-bulk-transfer (transfer dev-handle endpoint buffer length
                                     callback user-data timeout)
    "Fill TRANSFER as a bulk transfer."
    (set-slots transfer
               dev-handle dev-handle
               endpoint endpoint
               type (cffi:foreign-enum-value 'libusb-transfer-type :bulk)
               timeout timeout
               buffer buffer
               length length
               user-data user-data
               callback callback)
    transfer)

  (defun %libusb-fill-bulk-stream-transfer (transfer dev-handle endpoint stream-id
                                            buffer length callback user-data timeout)
    "Fill TRANSFER as a bulk transfer on a stream, and set its stream id."
    (%libusb-fill-bulk-transfer transfer dev-handle endpoint buffer length
                                callback user-data timeout)
    (set-slots transfer
               type (cffi:foreign-enum-value 'libusb-transfer-type :bulk-stream))
    (%libusb-transfer-set-stream-id transfer stream-id)
    transfer)

  (defun %libusb-fill-interrupt-transfer (transfer dev-handle endpoint buffer length
                                          callback user-data timeout)
    "Fill TRANSFER as an interrupt transfer."
    (set-slots transfer
               dev-handle dev-handle
               endpoint endpoint
               type (cffi:foreign-enum-value 'libusb-transfer-type :interrupt)
               timeout timeout
               buffer buffer
               length length
               user-data user-data
               callback callback)
    transfer)

  (defun %libusb-fill-iso-transfer (transfer dev-handle endpoint buffer length
                                    num-iso-packets callback user-data timeout)
    "Fill TRANSFER as an isochronous transfer of NUM-ISO-PACKETS packets.

TRANSFER must have been allocated by libusb_alloc_transfer with at least
NUM-ISO-PACKETS, because the packet descriptors live in the same allocation."
    (set-slots transfer
               dev-handle dev-handle
               endpoint endpoint
               type (cffi:foreign-enum-value 'libusb-transfer-type :isochronous)
               timeout timeout
               buffer buffer
               length length
               num-iso-packets num-iso-packets
               user-data user-data
               callback callback)
    transfer))

;;; --- isochronous packet descriptors ------------------------------------

(defun %libusb-set-iso-packet-lengths (transfer length)
  "Set every iso packet descriptor of TRANSFER to LENGTH."
  (dotimes (i (cffi:foreign-slot-value transfer '(:struct libusb-transfer)
                                       'num-iso-packets))
    (setf (cffi:foreign-slot-value (transfer-iso-packet-descriptor transfer i)
                                   '(:struct libusb-iso-packet-descriptor) 'length)
          length))
  transfer)

(defun %libusb-get-iso-packet-buffer (transfer packet)
  "A pointer to iso PACKET's data within TRANSFER's buffer, or NIL.

Accumulates the lengths of the preceding packets, as libusb.h does, so it is
correct for packets of differing sizes and O(packet). Returns NIL rather than a
null pointer when PACKET is out of range, because a Lisp caller who forgets to
check gets a type error here instead of a segmentation fault later."
  (let ((n (cffi:foreign-slot-value transfer '(:struct libusb-transfer)
                                    'num-iso-packets)))
    (when (< packet n)
      (let ((offset 0))
        (dotimes (i packet)
          (incf offset (cffi:foreign-slot-value
                        (transfer-iso-packet-descriptor transfer i)
                        '(:struct libusb-iso-packet-descriptor) 'length)))
        (cffi:inc-pointer
         (cffi:foreign-slot-value transfer '(:struct libusb-transfer) 'buffer)
         offset)))))

(defun %libusb-get-iso-packet-buffer-simple (transfer packet)
  "A pointer to iso PACKET's data, assuming every packet is the size of the
first. O(1), and wrong if the packet lengths differ -- which is precisely the
trade libusb.h offers under this name."
  (let ((n (cffi:foreign-slot-value transfer '(:struct libusb-transfer)
                                    'num-iso-packets)))
    (when (< packet n)
      (cffi:inc-pointer
       (cffi:foreign-slot-value transfer '(:struct libusb-transfer) 'buffer)
       (* packet (cffi:foreign-slot-value
                  (transfer-iso-packet-descriptor transfer 0)
                  '(:struct libusb-iso-packet-descriptor) 'length))))))

;;; --- descriptor reads built on a control transfer ----------------------

(defun %libusb-get-descriptor (dev-handle desc-type desc-index data length)
  "GET_DESCRIPTOR as a synchronous control transfer, with libusb.h's 1000 ms
timeout."
  (%libusb-control-transfer dev-handle
                            (cffi:foreign-enum-value 'libusb-endpoint-direction :in)
                            (cffi:foreign-enum-value 'libusb-standard-request
                                                     :get-descriptor)
                            (logior (ash desc-type 8) desc-index)
                            0 data length 1000))

(defun %libusb-get-string-descriptor (dev-handle desc-index langid data length)
  "GET_DESCRIPTOR for a string, in a particular language.

The raw form: the reply is a length byte, a type byte, and UTF-16LE. Use
DEVICE-STRING in the ergonomic layer unless you want the bytes."
  (%libusb-control-transfer dev-handle
                            (cffi:foreign-enum-value 'libusb-endpoint-direction :in)
                            (cffi:foreign-enum-value 'libusb-standard-request
                                                     :get-descriptor)
                            (logior (ash (cffi:foreign-enum-value
                                          'libusb-descriptor-type :string) 8)
                                    desc-index)
                            langid data length 1000))
