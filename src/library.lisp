;;; Finding and opening libusb-1.0.
;;;
;;; Loaded lazily, at run time, and never at load time. Two reasons, and the
;;; second is the load-bearing one:
;;;
;;;   - A dumped image must not carry a foreign library handle from the machine
;;;     that dumped it. LOAD-LIBRARIES is called by OPEN-CONTEXT (and by every
;;;     entry point that can be the first one called), so a restored image
;;;     opens whatever the new machine has.
;;;   - Nothing in libusb/ffi runs at load time, which means the raw system
;;;     compiles and loads on a machine with no libusb installed at all: CFFI
;;;     resolves a DEFCFUN through the linkage table when it is first called,
;;;     not when it is defined. That is what lets the enum, struct-offset and
;;;     descriptor tests run anywhere, and it is the whole reason libusb/ffi is
;;;     a system of its own.

(in-package #:libusb)

(defvar *library-directories*
  (list #+darwin #p"/opt/homebrew/lib/"
        #+darwin #p"/usr/local/lib/"
        #-darwin #p"/usr/local/lib/"
        #-darwin #p"/usr/lib/")
  "Extra directories searched for the libusb-1.0 shared library.

Pushed onto CFFI:*FOREIGN-LIBRARY-DIRECTORIES* by LOAD-LIBRARIES. Homebrew's
prefix is here because macOS ships no libusb of its own and dlopen does not
search /opt/homebrew; on Linux the loader's own search path normally suffices
and these entries are a fallback, not the mechanism.")

(cffi:define-foreign-library libusb
  ;; Version-suffixed names first. The bare libusb-1.0.so is in the -dev
  ;; package, so a machine with only the runtime installed has the soname and
  ;; nothing else -- asking for the unsuffixed name alone is how a binding
  ;; comes to work on the developer's box and nowhere in production.
  (:darwin (:or "libusb-1.0.0.dylib" "libusb-1.0.dylib" "libusb.dylib"))
  (:unix   (:or "libusb-1.0.so.0" "libusb-1.0.so"))
  (:windows (:or "libusb-1.0.dll"))
  (t (:default "libusb-1.0")))

(defvar *libraries-loaded* nil)

(defun libraries-loaded-p ()
  "True if LOAD-LIBRARIES has successfully opened libusb in this image."
  (and *libraries-loaded* t))

(defun load-libraries ()
  "Ensure libusb-1.0 is loaded. Idempotent, and safe to call from anywhere.

Signals CFFI's LOAD-FOREIGN-LIBRARY-ERROR if the library cannot be found,
which is deliberately not wrapped in a LIBUSB-ERROR: a missing shared library
is not a USB failure, and conflating the two sends the reader looking at their
device instead of at their package manager."
  (unless *libraries-loaded*
    (dolist (dir *library-directories*)
      (when (and dir (probe-file dir))
        (pushnew dir cffi:*foreign-library-directories* :test #'equal)))
    (cffi:use-foreign-library libusb)
    (setf *libraries-loaded* t))
  *libraries-loaded*)

(defvar %function-cache (make-hash-table :test 'equal)
  "C name -> pointer, or :ABSENT. Memoises FOREIGN-FUNCTION-AVAILABLE-P so the
version-guarded entry points cost one hash lookup per call rather than a
symbol-table search.")

(defun foreign-function-available-p (c-name)
  "True if the loaded libusb exports C-NAME.

The five entry points added in libusb 1.0.29 and 1.0.30 are probed with this
rather than gated on a read-time feature, because which libusb we are loaded
against is a run-time fact: this same fasl runs against 1.0.30 on a Mac and
1.0.28 on a Raspberry Pi, and a saved image can be restored on either."
  (load-libraries)
  (let ((cached (gethash c-name %function-cache)))
    (cond ((eq cached :absent) nil)
          (cached t)
          (t (let ((p (cffi:foreign-symbol-pointer c-name)))
               (setf (gethash c-name %function-cache) (or p :absent))
               (and p t))))))
