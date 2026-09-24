# Generates the libusb architecture diagram. Written as a generator rather than by hand
# so the layout arithmetic is checked by a machine instead of by eye.
from xml.sax.saxutils import escape

W, H = 1240, 1500
INK, MUTED, FAINT = "#1f2328", "#5b6472", "#8b93a1"
BG = "#fcfcfb"
PALETTE = {                     # fill, stroke
    "ffi":      ("#eef2ff", "#6366f1"),
    "core":     ("#ecfdf5", "#0d9488"),
    "closures": ("#fff7ed", "#ea580c"),
    "foreign":  ("#f4f4f5", "#a1a1aa"),
    "hot":      ("#fef9c3", "#ca8a04"),
    "plain":    ("#ffffff", "#d4d4d8"),
}
SANS = "Helvetica Neue, Helvetica, Arial, sans-serif"
MONO = "Menlo, DejaVu Sans Mono, monospace"
out = []


def esc(s):
    return escape(str(s))


def text(x, y, s, size=13, fill=INK, family=SANS, anchor="start", weight="normal",
         style="normal", opacity=1.0):
    out.append(f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" '
               f'fill="{fill}" text-anchor="{anchor}" font-weight="{weight}" '
               f'font-style="{style}" opacity="{opacity}">{esc(s)}</text>')


def box(x, y, w, h, kind="plain", r=7, dash=None, width=1.4):
    fill, stroke = PALETTE[kind]
    d = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" '
               f'stroke="{stroke}" stroke-width="{width}"{d}/>')


def labelled_box(x, y, w, h, kind, title, lines=(), mono_title=True, title_size=15):
    box(x, y, w, h, kind)
    text(x + 14, y + 25, title, size=title_size, weight="600",
         family=MONO if mono_title else SANS)
    for i, line in enumerate(lines):
        text(x + 14, y + 47 + i * 17, line, size=12, fill=MUTED)


def arrow(x1, y1, x2, y2, label=None, dash=None, label_side="right", colour=FAINT):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    out.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{colour}" '
               f'stroke-width="1.6" marker-end="url(#arrow)"{d}/>')
    if label:
        if x1 == x2:                                  # vertical
            text(x1 + (10 if label_side == "right" else -10), (y1 + y2) / 2 + 4, label,
                 size=11.5, fill=FAINT, family=MONO,
                 anchor="start" if label_side == "right" else "end")
        else:                                         # horizontal
            text((x1 + x2) / 2, y1 - 8, label, size=11.5, fill=FAINT, family=MONO,
                 anchor="middle")


def note(x, y, lines, width=330, title=None):
    if title:
        text(x, y, title, size=12, weight="600", fill=MUTED)
        y += 18
    for line in lines:
        text(x, y, line, size=11.5, fill=FAINT)
        y += 16
    return y


out.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">')
out.append(f'<rect width="{W}" height="{H}" fill="{BG}"/>')
out.append('<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" '
           f'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
           f'<path d="M0,0 L10,5 L0,10 z" fill="{FAINT}"/></marker></defs>')

text(44, 46, "libusb for Common Lisp", size=26, weight="600")
text(44, 70, "SBCL · CFFI · verified on macOS arm64 / libusb 1.0.30 and Raspberry Pi 4 "
             "aarch64 / libusb 1.0.28", size=13, fill=MUTED)

# ---------------------------------------------------------------- section 1
SX, SW = 44, 700                     # stack column
NX = 790                             # notes column
text(SX, 118, "1 — Five systems, split by build-time dependency weight",
     size=16, weight="600")
text(SX, 138, "Not by platform: every file needs CFFI. The seam that matters is libffi.",
     size=12, fill=MUTED)

labelled_box(SX, 158, SW, 40, "plain", "consumer code", mono_title=False, title_size=13)

labelled_box(SX, 228, 420, 150, "core", "libusb",
             ["contexts · devices · descriptors", "string descriptors · sync transfers",
              "async transfers · event pump", "", "+ bordeaux-threads"])
labelled_box(SX + 470, 228, 230, 150, "closures", "libusb/closures",
             ["hotplug.lisp", "logging.lisp", "shutdown.lisp"])
arrow(SX + 468, 300, 422, 300)

labelled_box(SX, 408, SW, 126, "ffi", "libusb/ffi",
             ["every exported libusb entry point · 22 structs · ~30 enums",
              "the header's 15 static inlines, reimplemented in Lisp",
              "the 1.0.29/1.0.30-only ones behind a runtime symbol probe",
              "", "+ cffi only"])

labelled_box(SX, 566, SW, 46, "foreign", "libusb-1.0.so.0   /   libusb-1.0.0.dylib",
             title_size=13)
labelled_box(SX, 642, SW, 46, "foreign",
             "Linux usbfs /dev/bus/usb   ·   macOS IOKit", title_size=13)
labelled_box(SX, 718, SW, 40, "plain", "USB devices", mono_title=False, title_size=13)

for y1, y2 in ((198, 226), (378, 406), (534, 564), (612, 640), (688, 716)):
    arrow(SX + 120, y1, SX + 120, y2)
text(SX + 136, 552, "CFFI, resolved lazily at first call", size=11.5, fill=FAINT,
     family=MONO)

y = note(NX, 248, [
    "cffi-callback-closures, and through it",
    "cffi-libffi and cffi-grovel: libffi",
    "headers and a C compiler at build",
    "time, and a system in no ocicl",
    "registry, so it resolves as a path",
    "or not at all.",
    "",
    "Keeping it out of libusb is what",
    "keeps `ocicl install libusb' possible.",
], title="why libusb/closures is separate")
y = note(NX, y + 18, [
    "defcfun resolves lazily and",
    "load-libraries is lazy, so this",
    "system compiles and loads on a",
    "machine with no libusb at all —",
    "which is what lets the enum,",
    "struct-offset and descriptor tests",
    "run anywhere, CI included.",
], title="libusb/ffi loads without libusb")
note(NX, y + 18, [
    "root:root 0664 on the Pi, so as an",
    "ordinary user enumeration and",
    "descriptors work and libusb_open",
    "returns LIBUSB_ERROR_ACCESS.",
], title="the device nodes")

out.append(f'<line x1="44" y1="800" x2="{W-44}" y2="800" stroke="#e4e4e7" '
           f'stroke-width="1"/>')

# ---------------------------------------------------------------- section 2
text(SX, 840, "2 — How C reaches Lisp: two mechanisms, on purpose",
     size=16, weight="600")
text(SX, 860, "libusb has four callback types. They are not the same problem, so they "
              "are not solved the same way.", size=12, fill=MUTED)

labelled_box(SX, 880, W - 88, 52, "foreign",
             "libusb_handle_events_timeout_completed(ctx, tv, completed)",
             ["dispatched on a Lisp event-pump thread (:thread) or on the thread that is "
              "waiting for a transfer (:manual)"])

LX, LW = SX, 560
RX, RW = SX + 608, W - 88 - 608
arrow(LX + 180, 932, LX + 180, 966)
arrow(RX + 180, 932, RX + 180, 966)
text(LX + 190, 954, "a transfer completed", size=11.5, fill=FAINT, family=MONO)
text(RX + 190, 954, "a device arrived / libusb logged", size=11.5, fill=FAINT,
     family=MONO)

labelled_box(LX, 966, LW, 62, "hot", "ONE cffi:defcallback  %transfer-complete",
             ["the only native callback in the image"])
labelled_box(RX, 966, RW, 62, "closures", "a libffi closure per Lisp closure",
             ["ffi_closure_alloc: one executable page each"])

labelled_box(LX, 1058, LW, 46, "plain", "transfer->user_data  →  integer index",
             title_size=13)
labelled_box(RX, 1058, RW, 46, "plain", "the closure carries its own Lisp state",
             mono_title=False, title_size=13)
arrow(LX + 180, 1028, LX + 180, 1056)
arrow(RX + 180, 1028, RX + 180, 1056)

labelled_box(LX, 1134, LW, 46, "plain",
             "*transfers*  →  transfer record   (locked)", title_size=13)
arrow(LX + 180, 1104, LX + 180, 1132)
arrow(RX + 180, 1104, RX + 180, 1210)

labelled_box(LX, 1210, LW, 46, "hot", "with-callback-guard", title_size=13)
labelled_box(RX, 1210, RW, 46, "hot", "with-callback-guard   (returns 0, never 1)",
             title_size=13)
arrow(LX + 180, 1180, LX + 180, 1208)

labelled_box(LX, 1286, LW, 84, "core", "the completion, in order",
             ["mirror status and actual_length into Lisp",
              "run the user function — which may resubmit",
              "set the completion flag, then signal the semaphore"],
             mono_title=False, title_size=13)
labelled_box(RX, 1286, RW, 84, "closures", "the handler",
             ["hotplug: (device event registration)",
              "log: (ctx level message), with a reentrancy guard",
              "returning :deregister ends the registration"],
             mono_title=False, title_size=13)
arrow(LX + 180, 1256, LX + 180, 1284)
arrow(RX + 180, 1256, RX + 180, 1284)

# the resubmit loop
out.append(f'<path d="M {LX+LW-40} 1328 L {LX+LW+22} 1328 L {LX+LW+22} 997 '
           f'L {LX+LW+4} 997" fill="none" stroke="{FAINT}" stroke-width="1.6" '
           f'stroke-dasharray="4 3" marker-end="url(#arrow)"/>')
text(LX + LW + 28, 1170, "libusb_submit_transfer", size=11, fill=FAINT, family=MONO)
text(LX + LW + 28, 1186, "from inside the callback:", size=11, fill=FAINT)
text(LX + LW + 28, 1200, "the streaming idiom", size=11, fill=FAINT)

box(SX, 1400, W - 88, 64, "plain", dash="5 4")
text(SX + 16, 1422, "Why not one mechanism for both:", size=12.5, weight="600")
text(SX + 16, 1442, "a libffi closure costs an mmap'd executable page, and transfers are "
                    "many and short-lived — struct libusb_transfer hands us a void* that is "
                    "exactly the demultiplexer a closure", size=11.5, fill=MUTED)
text(SX + 16, 1457, "would pay for. Meanwhile libusb_set_log_cb takes no user_data at all, "
                    "so a per-context Lisp handler has nowhere to put an index and must BE "
                    "its own C function pointer.", size=11.5, fill=MUTED)

out.append("</svg>")
open("architecture.svg", "w").write("\n".join(out))
print("wrote architecture.svg")
