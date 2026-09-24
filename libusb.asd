;;; CFFI bindings to libusb-1.0: a complete raw layer plus a selective
;;; ergonomic one.
;;;
;;; Split by build-time dependency weight, not by platform. The ble/core split
;;; does not transfer here -- every file needs cffi -- but a heavier seam
;;; exists in its place:
;;;
;;;   libusb/ffi       the raw layer: every exported libusb-1.0 entry point,
;;;                    22 structs, ~30 enums, and the header's static-inline
;;;                    functions reimplemented in Lisp. cffi only. It compiles
;;;                    and loads on a machine with no libusb installed at all,
;;;                    because defcfun resolves lazily and LOAD-LIBRARIES is
;;;                    lazy; that is what lets the enum, struct-layout and
;;;                    descriptor tests run where no USB stack exists. It is
;;;                    also a deliverable in its own right: bulk streams,
;;;                    dev_mem and the BOS/SuperSpeed descriptor family are
;;;                    deliberately raw-only, so a consumer of those must be
;;;                    able to ask for the bindings without the opinions.
;;;   libusb           the ergonomic layer: contexts, enumeration, descriptors
;;;                    deep-copied out of C, string descriptors, synchronous
;;;                    transfers, asynchronous transfers and the event loop.
;;;                    Async lives here rather than behind the closures system
;;;                    because it needs no libffi: there is exactly one
;;;                    cffi:defcallback in this library, and libusb_transfer's
;;;                    own user_data field is the demultiplexer.
;;;   libusb/closures  hotplug and log callbacks, the two places where a C
;;;                    callback must carry Lisp state that user_data cannot.
;;;                    libusb_set_log_cb takes no user_data at all, so a
;;;                    per-context Lisp handler needs its own C function
;;;                    pointer, which is what cffi-callback-closures mints.
;;;                    Through that dependency come cffi-libffi and
;;;                    cffi-grovel, i.e. libffi headers and a C compiler at
;;;                    build time, and a system that is in no ocicl registry
;;;                    and so resolves as a path or not at all. Keeping it out
;;;                    of #:libusb is what keeps `ocicl install libusb'
;;;                    possible.
;;;
;;; The entry points that exist only in libusb 1.0.29/1.0.30 are bound behind a
;;; runtime cffi:foreign-symbol-pointer probe rather than a read-time feature:
;;; which binary we load against is a run-time fact, and a dumped image can be
;;; restored on a machine with a different one.

(asdf:defsystem #:libusb/ffi
  :description "Complete raw CFFI bindings to libusb-1.0: functions, structs, enums."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:cffi)
  :components ((:module "src"
                :components ((:file "package")
                             (:file "library"      :depends-on ("package"))
                             ;; The condition hierarchy lives in the raw system
                             ;; so that both layers hang off one root, and
                             ;; deliberately does not depend on "ffi": its
                             ;; messages come from a static table rather than
                             ;; libusb_strerror, so a failure is reportable
                             ;; before the library has even been loaded.
                             (:file "conditions"   :depends-on ("package"))
                             (:file "enums"        :depends-on ("package"))
                             ;; enums, because libusb_transfer.status,
                             ;; libusb_iso_packet_descriptor.status and
                             ;; libusb_init_option.option are enum-typed slots.
                             (:file "structs"      :depends-on ("enums"))
                             ;; library, because every defcfun names it as
                             ;; :library libusb.
                             (:file "ffi"          :depends-on ("structs" "library"))
                             ;; After "ffi" for the shared types, and after
                             ;; "conditions" for LIBUSB-UNSUPPORTED-FUNCTION.
                             (:file "ffi-optional" :depends-on ("ffi" "conditions"))
                             ;; The header's static inlines, in Lisp.
                             ;; libusb_get_descriptor and friends are calls to
                             ;; libusb_control_transfer, hence "ffi".
                             (:file "inline"       :depends-on ("ffi"))))))

(asdf:defsystem #:libusb
  :description "Common Lisp interface to libusb-1.0: devices, descriptors, synchronous and asynchronous transfers."
  :license     "MIT"
  :version     "0.1.0"
  ;; bordeaux-threads is for the transfer registry and the event pump. libusb
  ;; is itself thread-safe; the bookkeeping that lets a completion callback on
  ;; libusb's thread find the Lisp transfer it belongs to is ours, and that is
  ;; what needs the lock.
  :depends-on  (#:libusb/ffi #:bordeaux-threads)
  :components ((:module "src"
                :components ((:file "api-package")
                             (:file "core"        :depends-on ("api-package"))
                             ;; Pure data: a C descriptor tree in, Lisp structs
                             ;; out. No context and no handle, which is what
                             ;; makes the parser testable with no hardware.
                             (:file "descriptors" :depends-on ("api-package"))
                             (:file "device"      :depends-on ("core" "descriptors"))
                             (:file "handle"      :depends-on ("device"))
                             ;; Its own file because its failure policy is the
                             ;; opposite of its neighbours': a device refusing
                             ;; to describe itself is routine, not an error.
                             (:file "strings"     :depends-on ("handle"))
                             (:file "transfers-sync" :depends-on ("handle"))
                             ;; Before "transfer": every callback body in this
                             ;; library goes through its guard.
                             (:file "guard"       :depends-on ("api-package"))
                             (:file "transfer"    :depends-on ("handle" "guard"))
                             (:file "events"      :depends-on ("transfer"))
                             ;; Last: wraps acquire/release pairs from all of
                             ;; the above.
                             (:file "with"        :depends-on ("transfers-sync" "events")))))
  :in-order-to ((asdf:test-op (asdf:test-op #:libusb/tests))))

(asdf:defsystem #:libusb/closures
  :description "libusb hotplug and log callbacks, as runtime-minted Lisp closures."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:libusb #:cffi-callback-closures)
  :components ((:module "src"
                :components ((:file "closures-package")
                             (:file "hotplug"  :depends-on ("closures-package"))
                             (:file "logging"  :depends-on ("closures-package"))
                             ;; Last: teardown order has to know about every
                             ;; callback subsystem there is.
                             (:file "shutdown" :depends-on ("hotplug" "logging"))))))

(asdf:defsystem #:libusb/tests
  :description "Test suite for everything that needs no USB device."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:libusb/closures #:fiveam)
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "helpers")
                             (:file "symbol-tests")
                             (:file "enum-tests")
                             (:file "struct-tests")
                             (:file "descriptor-tests")
                             (:file "condition-tests")
                             (:file "callback-tests")
                             (:file "event-tests")
                             (:file "enumeration-tests")
                             ;; Last in the file order as well as the suite
                             ;; order: it asserts on what the tests above left
                             ;; behind.
                             (:file "hygiene-tests"))))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             ;; ASDF ignores what a perform method returns, so reporting
             ;; failure by returning NIL would leave `asdf:test-system' -- and
             ;; therefore CI -- green on a suite that failed. Signal.
             (unless (uiop:symbol-call :libusb/tests '#:run-tests)
               (error "The libusb test suite failed."))))

(asdf:defsystem #:libusb/hw-tests
  :description "Tests that need a real USB device and permission to open it."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:libusb/tests)
  :components ((:module "tests"
                :components ((:file "hw-tests"))))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             (unless (uiop:symbol-call :libusb/tests '#:run-hw-tests)
               (error "The libusb hardware test suite failed."))))
