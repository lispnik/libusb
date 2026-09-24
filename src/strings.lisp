;;; String descriptors.
;;;
;;; Its own file because the failure policy here is the opposite of its
;;; neighbours'. Everywhere else in this layer a libusb error signals; here a
;;; device refusing to describe itself is routine. Plenty of devices advertise a
;;; manufacturer string index whose descriptor they will not produce, some stall
;;; the request outright, and a great many report index 0 -- which in a USB
;;; descriptor means "no string", not "string number zero". Signalling on any of
;;; that would make PRODUCT unusable in the one place it is most wanted, which is
;;; a listing loop over every device on the bus.
;;;
;;; Note for later: libusb 1.0.30 added libusb_get_device_string, which answers
;;; manufacturer, product and serial from a libusb_device with no handle at all --
;;; on Linux, the difference between needing write access to /dev/bus/usb and not.
;;; It is bound, version-guarded, as %LIBUSB-GET-DEVICE-STRING, and is not used
;;; here because the Raspberry Pi this library is verified against runs 1.0.28.

(in-package #:libusb)

(defun device-string (handle index &key langid errorp)
  "The string descriptor at INDEX, as (VALUES STRING NIL) or (VALUES NIL REASON).

Returns NIL at once for INDEX 0, which means \"no string\" wherever a descriptor
carries an index. REASON is an error keyword from ERROR-CODE-KEYWORD, or :EMPTY
for a descriptor that contains no characters. Pass :ERRORP T to signal instead.

Without LANGID this uses libusb_get_string_descriptor_ascii, which asks the
device for its first language and flattens the reply -- adequate for almost every
device, and wrong for any whose strings are not Latin-1. With LANGID it reads the
raw descriptor and decodes UTF-16LE properly, which is the only way to get a
non-ASCII product name out of a device; STRING-DESCRIPTOR-LANGUAGES lists the
LANGIDs on offer."
  (check-handle handle 'device-string)
  (if (zerop index)
      (values nil nil)
      ;; 255 bytes is the most a one-byte bLength can describe, so no string
      ;; descriptor can be longer and no larger buffer is ever useful.
      (cffi:with-foreign-pointer (buffer 256)
        (let ((rc (if langid
                      (%libusb-get-string-descriptor (handle-pointer handle)
                                                     index langid buffer 255)
                      (%libusb-get-string-descriptor-ascii (handle-pointer handle)
                                                           index buffer 255))))
          (cond ((minusp rc)
                 (if errorp
                     (check-result rc (if langid
                                          '%libusb-get-string-descriptor
                                          '%libusb-get-string-descriptor-ascii)
                                   (format nil "string descriptor ~D" index))
                     (values nil (error-code-keyword rc))))
                (langid
                 ;; The raw descriptor: bLength, bDescriptorType (3), then
                 ;; UTF-16LE. Trust the smaller of bLength and what actually
                 ;; arrived -- devices overstate both.
                 (let* ((declared (if (>= rc 1) (cffi:mem-aref buffer :uint8 0) 0))
                        (octets (- (min declared rc) 2)))
                   (if (plusp octets)
                       (values (cffi:foreign-string-to-lisp
                                (cffi:inc-pointer buffer 2)
                                :count octets :encoding :utf-16le)
                               nil)
                       (values nil :empty))))
                ((zerop rc) (values nil :empty))
                (t (values (cffi:foreign-string-to-lisp buffer :count rc
                                                               :encoding :latin-1)
                           nil)))))))

(defun string-descriptor-languages (handle)
  "The LANGIDs HANDLE's device offers, as a list of integers, or NIL.

String descriptor 0 is the language table. A device with no strings at all has no
descriptor 0 either, so NIL here is a normal answer and not a failure. 0x0409 is
US English and is what nearly everything reports."
  (check-handle handle 'string-descriptor-languages)
  (cffi:with-foreign-pointer (buffer 256)
    (let ((rc (%libusb-get-string-descriptor (handle-pointer handle) 0 0 buffer 255)))
      (when (plusp rc)
        (let* ((declared (cffi:mem-aref buffer :uint8 0))
               (octets (- (min declared rc) 2)))
          (loop for i from 0 below (floor octets 2)
                collect (logior (cffi:mem-aref buffer :uint8 (+ 2 (* 2 i)))
                                (ash (cffi:mem-aref buffer :uint8 (+ 3 (* 2 i))) 8))))))))

(macrolet ((define-string-reader (name index-reader what)
             `(defun ,name (handle &key langid errorp)
                ,(format nil "HANDLE's ~A string, or NIL if the device has none~@
                              or will not produce it. See DEVICE-STRING." what)
                (check-handle handle ',name)
                (let ((device (handle-device handle)))
                  (unless device
                    ;; A handle from WRAP-SYS-DEVICE has no libusb_device, so
                    ;; there is no descriptor to read the index out of.
                    (usage-error "~S has no device descriptor to take a string ~
                                  index from; use DEVICE-STRING with an explicit ~
                                  index." handle))
                  (device-string handle
                                 (,index-reader (device-descriptor device))
                                 :langid langid :errorp errorp)))))
  (define-string-reader manufacturer device-descriptor-manufacturer-index
    "iManufacturer")
  (define-string-reader product device-descriptor-product-index "iProduct")
  (define-string-reader serial-number device-descriptor-serial-number-index
    "iSerialNumber"))
