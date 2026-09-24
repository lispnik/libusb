(in-package #:libusb/tests)
(in-suite libusb-events)

;;; A context is unprivileged and needs no devices, so everything about event
;;; handling -- including the shutdown race that is libusb's classic footgun -- is
;;; testable on a bare machine.

(test handle-events-with-a-short-timeout-returns-promptly-and-succeeds
  "The most basic thing that must work, and a canary for a mis-bound timeval: if
tv_usec were the wrong width the timeout would come out either enormous or zero, and
this test would either hang or still pass -- which is why the elapsed time is checked
as well as the return value."
  (libusb:with-context (context)
    (let ((start (get-internal-real-time)))
      (is (eq :success (libusb:handle-events context :timeout 0.05)))
      (let ((elapsed (/ (- (get-internal-real-time) start)
                        (float internal-time-units-per-second))))
        (is (< elapsed (scaled 2))
            "handle_events with a 50 ms timeout took ~,3F s" elapsed)))))

(test a-fresh-context-is-in-manual-mode-and-has-no-pump
  "The default, and the mode the rest of this suite relies on: with no pump, a waiting
thread does the event handling itself."
  (libusb:with-context (context)
    (is (eq :manual (libusb:context-event-mode context)))
    (is-false (libusb:event-pump-running-p context))))

(test an-event-pump-starts-switches-the-mode-and-stops-without-leaving-a-thread
  "Starting one is the easy half. Stopping it is the half that matters."
  (libusb:with-context (context)
    (let ((pump (libusb:start-event-pump context)))
      (is-true (libusb:event-pump-running-p context))
      (is (eq :thread (libusb:context-event-mode context)))
      (let ((thread (libusb::pump-thread pump)))
        (libusb:stop-event-pump context)
        (is-false (bt:thread-alive-p thread))
        (is-false (libusb:event-pump-running-p context))
        (is (eq :manual (libusb:context-event-mode context))
            "stopping must put the context back in a mode where waiting still works")
        (is (null (libusb::pump-error pump))
            "the pump exited with ~S" (libusb::pump-error pump))))))

(test starting-a-pump-twice-does-not-start-two
  "Because WITH-EVENT-PUMP nests in real code, and two threads calling
libusb_handle_events on one context is legal but pointless -- and makes the join at
teardown twice as likely to go wrong."
  (libusb:with-context (context)
    (libusb:with-event-pump (context)
      (let ((pump (libusb::context-pump context)))
        (is (eq pump (libusb:start-event-pump context)))))))

(test stopping-an-event-pump-is-what-makes-libusb-exit-safe
  "This is the regression test for libusb's sharpest edge. libusb_exit while another
thread sits inside libusb_handle_events tears the context out from under it: a
use-after-free that presents as a crash in poll() with no libusb frames on the stack
and nothing in the backtrace to suggest what happened.

Twenty start/stop/exit cycles. If the join were not mandatory, or the flag-then-
interrupt order were wrong, this is where it would show -- and it would show as a
crash, not a failed assertion, which is exactly why it is worth running twenty times
rather than once."
  (dotimes (i 20)
    (let ((context (libusb:open-context)))
      (libusb:start-event-pump context :tick 0.05)
      (is-true (libusb:event-pump-running-p context))
      (finishes (libusb:stop-event-pump context))
      (finishes (libusb:close-context context)))))

(test closing-a-context-stops-its-pump-without-being-asked
  "The teardown order is registered in one place for exactly this: a caller who used
WITH-EVENT-PUMP and then returned through a non-local exit must not be able to leave
libusb_exit racing a live pump thread."
  (let ((context (libusb:open-context)))
    (libusb:start-event-pump context :tick 0.05)
    (let ((thread (libusb::pump-thread (libusb::context-pump context))))
      (libusb:close-context context)
      (is-false (bt:thread-alive-p thread)))))

(test interrupting-the-event-handler-wakes-a-blocked-pump-promptly
  "A pump with a thirty-second tick is, without libusb_interrupt_event_handler, a
thirty-second wait at teardown. The flag is set before the interrupt so there is no
window in which the pump misses the request and settles in for the full tick."
  (libusb:with-context (context)
    (libusb:start-event-pump context :tick 30.0)
    (sleep 0.1)                         ; let it actually get inside handle_events
    (let ((start (get-internal-real-time)))
      (finishes (libusb:stop-event-pump context))
      (let ((elapsed (/ (- (get-internal-real-time) start)
                        (float internal-time-units-per-second))))
        (is (< elapsed (scaled 3))
            "stopping a pump with a 30 s tick took ~,2F s; the interrupt did not wake it"
            elapsed)))))

(test a-pump-that-cannot-be-joined-refuses-to-let-you-reach-libusb-exit
  "STOP-EVENT-PUMP returning normally is a promise that libusb_exit is now safe. If the
thread cannot be joined the promise has to be refused: signalling and leaving a leaked
context plus a live thread is recoverable, whereas calling libusb_exit with a thread
still inside libusb_handle_events is a use-after-free that surfaces as a crash in poll()
with no libusb frames on the stack.

The unstoppable pump is built rather than raced. A real one is designed to stop within a
millisecond of being asked -- it is told through a flag libusb itself checks, and woken
with libusb_interrupt_event_handler -- so any attempt to catch a real one failing would
pass or fail on timing. Instead a pump record is assembled around a thread that will not
finish until this test lets it, which makes the refusal deterministic."
  (let ((context (libusb:open-context))
        (blocker (bt:make-semaphore :count 0))
        (stop (cffi:foreign-alloc :int :initial-element 0)))
    (unwind-protect
         (let* ((thread (bt:make-thread (lambda () (bt:wait-on-semaphore blocker
                                                                        :timeout 30))
                                        :name "libusb test blocker"))
                (pump (libusb::make-event-pump
                       :context context :stop stop :thread thread
                       :exited (bt:make-semaphore :count 0) :tick 1.0)))
           (setf (libusb::context-pump context) pump
                 (libusb::context-event-mode context) :thread)
           (signals libusb:libusb-event-pump-stuck
             (libusb:stop-event-pump context :timeout 0.05))
           (is-true (libusb::context-pump context)
                    "a refused stop must leave the pump in place rather than half ~
                     dismantled -- the caller may want to try again")
           (is (= 1 (cffi:mem-ref stop :int))
               "the stop flag must have been set even though the join failed")
           (bt:signal-semaphore blocker)
           (bt:join-thread thread)
           ;; Now that the thread really has finished, the ordinary stop must succeed.
           (setf (libusb::pump-exited pump) (bt:make-semaphore :count 1))
           (finishes (libusb:stop-event-pump context))
           (is-false (libusb::context-pump context)))
      ;; STOP-EVENT-PUMP frees the flag only on the path that succeeds, so on any other
      ;; path it is ours.
      (when (and (libusb::context-pump context)
                 (not (cffi:null-pointer-p (libusb::pump-stop
                                            (libusb::context-pump context)))))
        (cffi:foreign-free stop))
      (setf (libusb::context-pump context) nil
            (libusb::context-event-mode context) :manual)
      (libusb:close-context context))))

;;; --- the polling primitives --------------------------------------------

(test every-context-reports-at-least-one-pollfd
  "libusb keeps an internal pipe that libusb_interrupt_event_handler writes to, so
there is always at least one descriptor. An empty list would mean the array walk is
wrong -- it is NULL-terminated, and reading it as a counted array is the obvious way to
get this wrong."
  (libusb:with-context (context)
    (let ((fds (libusb:pollfds context)))
      (is (plusp (length fds)) "no pollfds at all")
      (dolist (entry fds)
        (is (integerp (car entry)))
        (is (>= (car entry) 0) "file descriptor ~S" (car entry))
        (is (or (member :pollin (cdr entry)) (member :pollout (cdr entry)))
            "descriptor ~D is watched for neither reading nor writing" (car entry))))))

(test pollfd-timeout-handling-is-reported-honestly-for-this-platform
  "libusb_pollfds_handle_timeouts is true on Linux, which has timerfd, and FALSE on
macOS. An external event loop built on the descriptors alone will therefore never
enforce a transfer timeout on a Mac -- and everything will work until a device stops
answering. Pinned per platform so the answer cannot quietly change."
  (libusb:with-context (context)
    (let ((handled (libusb:pollfds-handle-timeouts-p context)))
      #+linux (is-true handled "on Linux libusb uses timerfd and should answer true")
      #+darwin (is-false handled
                         "if this ever becomes true on macOS the warning in ~
                          POLLFDS-HANDLE-TIMEOUTS-P should be revisited")
      #-(or linux darwin) (is (typep handled 'boolean)))))

(test the-next-timeout-is-either-absent-or-not-negative
  "NIL means an external loop may block indefinitely; a number means it must wake. A
negative number would mean the timeval decoding is wrong, and would make such a loop
spin."
  (libusb:with-context (context)
    (let ((timeout (libusb:next-timeout context)))
      (is (or (null timeout) (and (realp timeout) (>= timeout 0)))
          "next-timeout returned ~S" timeout))))

(test pollfd-notifiers-can-be-installed-and-cleared-without-leaking-a-closure
  "Two more minted closures, and the same rule as everywhere: detach from libusb first,
free the trampolines second."
  (libusb:with-context (context)
    (let ((before (libusb:live-closure-count)))
      (libusb:set-pollfd-notifiers context
                                   :added (lambda (fd events) (declare (ignore fd events)))
                                   :removed (lambda (fd) (declare (ignore fd))))
      (is (= (+ 2 before) (libusb:live-closure-count)))
      (libusb:set-pollfd-notifiers context)
      (is (= before (libusb:live-closure-count))))))

(test event-handler-active-reports-whether-somebody-is-pumping
  "Useful to a caller deciding whether to pump themselves, and a direct check that the
pump thread really is inside libusb rather than merely alive."
  (libusb:with-context (context)
    (is-false (libusb:event-handler-active-p context))
    (libusb:with-event-pump (context :tick 0.05)
      (sleep 0.2)
      (is-true (libusb:event-handler-active-p context)))))

(test manual-mode-completes-a-transfer-with-no-pump-thread-anywhere
  "The :MANUAL path end to end, without a device: the waiter drives
libusb_handle_events_timeout_completed itself, and the completion flag set by the
dispatcher is what releases it. This is what makes the library usable in a
single-threaded program."
  (with-fake-handle (handle context)
    (is (eq :manual (libusb:context-event-mode context)))
    (libusb:with-transfer (tr handle :type :bulk :endpoint #x83 :length 8)
      (invoke-completion tr :status :completed :actual 8)
      (is (eq :completed (libusb:wait-for-transfer tr :timeout (scaled 2)))))))

(test a-wait-that-times-out-says-so-and-leaves-the-transfer-alone
  "NIL means this call gave up, not that the transfer did. The distinction matters
because the caller's next move is to cancel and drain, and a transfer that had actually
completed must not be cancelled."
  (with-fake-handle (handle)
    (let ((tr (libusb:make-usb-transfer handle :type :bulk :endpoint #x83 :length 8)))
      (unwind-protect
           (progn
             (setf (libusb::transfer-state tr) :submitted)
             (is (null (libusb:wait-for-transfer tr :timeout 0.2))
                 "a transfer nothing will ever complete must time out, not hang")
             (is (eq :submitted (libusb:transfer-state tr))))
        (setf (libusb::transfer-state tr) :done)
        (libusb:free-usb-transfer tr)))))
