;;; cider-storm-stepper.el --- Cider front-end for the FlowStorm debugger  -*- lexical-binding: t -*-

;; Copyright (c) 2023 Juan Monetta <jpmonettas@gmail.com>

;; Author: Juan Monetta <jpmonettas@gmail.com>
;; URL: https://github.com/jpmonettas/cider-storm
;; Keywords: convenience, tools, debugger, clojure, cider
;; Version: 0.1
;; Package-Requires: ((emacs "26") (cider "1.6.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Cider Storm is an Emacs Cider front-end for the
;; [FlowStorm debugger](https://github.com/jpmonettas/flow-storm-debugger)
;; with support for Clojure and ClojureScript.

;; It brings the time-travel code stepping capabilities of FlowStorm to Emacs,
;; providing an interface similar to the Cider debugger one.

;; Cider Storm isn't trying to re-implement the entire FlowStorm UI, but the
;; most used functionality.  You can always start the full FlowStorm UI if you
;; need the extra tools.

;;; Code:

;;(add-to-list 'cider-jack-in-nrepl-middlewares "flow-storm.nrepl.middleware/wrap-flow-storm")

;;;;;;;;;;;;;;;;;;;;
;; Debugger state ;;
;;;;;;;;;;;;;;;;;;;;

(require 'subr-x)
(require 'cider)

(defvar cider-storm-debugging-mode) ;; just so flycheck doesn't complain

(defvar cider-storm-current-flow-id nil
  "The current flow id. A positive number or nil
for the funnel flow")

(defvar cider-storm-current-thread-id nil
  "Always a positive number representing the thread the stepper
is currently on")

(defvar cider-storm-current-entry nil
  "A nrepl dict representing the current entry on the timeline
the stepper is currently in.
The stepper will always be on a fn-call, expr or fn-return
Example :

(dict
    \"type\"        \"expr\"
    \"coord\"       (2 2 1)
    \"fn-call-idx\" 117
    \"idx\"         118
    \"result\"      6)
")

(defvar cider-storm-initial-entry nil
  "The entry point to your recordings. This should be a timeline
entry always of type fn-call.
Example :
(dict
    \"type\"       \"fn-call\"
    \"flow-id\"     nil
    \"thread-id\"   18
    \"fn-args\"     1
    \"fn-call-idx\" 116
    \"fn-name\"     \"boo\"
    \"fn-ns\"       \"dev-tester\"
    \"form-id\"     698052411
    \"idx\"         116
    \"parent-indx\" 115
    \"ret-idx\"     874)
")

(defvar cider-storm-current-frame nil
  "The current fn frame the stepper is in.
Example :

(dict
 \"args-vec\"           2
 \"fn-call-idx\"        117
 \"fn-name\"            \"other-function\"
 \"fn-ns\"              \"dev-tester\"
 \"form-id\"            1451539897
 \"parent-fn-call-idx\" 116
 \"ret\"                5)
")

(defvar cider-storm-current-thread-trace-cnt nil
  "Current thread timeline length")

(defvar cider-storm-disabled-evil-mode-p nil
  "Tracks if we disabled evil-mode when entering the debugger minor-mode
so we know if we need to restore it after.")

;;;;;;;;;;;;;;;;;;;;
;; Middleware api ;;
;;;;;;;;;;;;;;;;;;;;

(defun cider-storm--trace-cnt (flow-id thread-id)
  (thread-first (cider-nrepl-send-sync-request `("op"        "flow-storm-trace-count"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id))
                (nrepl-dict-get "trace-cnt")))

(defun cider-storm--find-fn-call (fq-fn-symb from-idx from-back)
  (thread-first (cider-nrepl-send-sync-request `("op"         "flow-storm-find-fn-call"
                                                 "fq-fn-symb" ,fq-fn-symb
                                                 "from-idx"   ,from-idx
                                                 "from-back"  ,(if from-back "true" "false")))
                (nrepl-dict-get "fn-call")))

(defun cider-storm--find-flow-fn-call (flow-id)
  (thread-first (cider-nrepl-send-sync-request `("op"      "flow-storm-find-flow-fn-call"
                                                 "flow-id" ,flow-id))
                (nrepl-dict-get "fn-call")))

(defun cider-storm--get-form (form-id)
  (thread-first (cider-nrepl-send-sync-request `("op"         "flow-storm-get-form"
                                                 "form-id" ,form-id))
                (nrepl-dict-get "form")))

(defun cider-storm--timeline-entry (flow-id thread-id idx drift)
  (thread-first (cider-nrepl-send-sync-request `("op"        "flow-storm-timeline-entry"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id
                                                 "idx"       ,idx
                                                 "drift"     ,drift))
                (nrepl-dict-get "entry")))

(defun cider-storm--frame-data (flow-id thread-id fn-call-idx)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-frame-data"
                                                 "flow-id"     ,flow-id
                                                 "thread-id"   ,thread-id
                                                 "fn-call-idx" ,fn-call-idx))
                (nrepl-dict-get "frame")))

(defun cider-storm--pprint-val-ref (v-ref val-print-length val-print-level print-meta pprint)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-pprint"
                                                 "val-ref"      ,v-ref
                                                 "print-length" ,val-print-length
                                                 "print-level"  ,val-print-level
                                                 "print-meta"   ,(if print-meta "true" "false")
                                                 "pprint"       ,(if pprint     "true" "false")))
                (nrepl-dict-get "pprint")))

(defun cider-storm--bindings (flow-id thread-id idx all-frame)
  (thread-first (cider-nrepl-send-sync-request `("op"          "flow-storm-bindings"
                                                 "flow-id"   ,flow-id
                                                 "thread-id" ,thread-id
                                                 "idx"       ,idx
                                                 "all-frame" ,(if all-frame "true" "false")))
                (nrepl-dict-get "bindings")))

(defun cider-storm--clear-recordings ()
  (cider-nrepl-send-sync-request `("op" "flow-storm-clear-recordings")))

(defun cider-storm--recorded-functions ()
  (thread-first (cider-nrepl-send-sync-request `("op" "flow-storm-recorded-functions"))
                (nrepl-dict-get "functions")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Debugger implementation ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(declare-function evil-local-mode "ext:evil-common")
(defun cider-storm--debug-mode-enter ()
  "Called to setup the debug mode"

  (cider-storm-debugging-mode 1)

  (when (bound-and-true-p evil-local-mode)
    ;; if evil-mode disable evil-mode for the buffer
    (evil-local-mode -1)
    (setq cider-storm-disabled-evil-mode-p t)
    (message "Evil mode disabled for this buffer while the debugger is on")))

(defun cider-storm--debug-mode-quit ()
  "Called to tear down the debug mode"

  (cider--debug-remove-overlays)
  (cider-storm-debugging-mode -1)

  ;; restore evil-mode for the buffer if we disabled it
  (when cider-storm-disabled-evil-mode-p
    (evil-local-mode 1)
    (message "Evil mode restored in this buffer")))

(defun cider-storm--select-form (form-id)
  "Given a FORM-ID retrievs the file/line information for it and
opens a buffer for it. If there is no file info for the form it will popup
a buffer for it.
Returns the line number in the buffer where the form is located."

  (let* ((form (cider-storm--get-form form-id))
         (form-file (nrepl-dict-get form "file"))
         (form-line (nrepl-dict-get form "line")))

    (when (and (not (equal (buffer-file-name (current-buffer))
                           form-file))
               cider-storm-debugging-mode)
      ;; if we are changing files, remove the debugger stuff from this buffer
      ;; since we only want to have the debugger mode enable in one buffer at a time
      (cider-storm--debug-mode-quit))
    

    (if (and form-file form-line)
        (when-let* ((buf (save-excursion (cider--find-buffer-for-file form-file))))          
          (with-current-buffer buf
            (switch-to-buffer buf)
            (cider-storm--debug-mode-enter)
            (forward-line (- form-line (line-number-at-pos)))
            form-line))

      (let* ((pprinted-form (nrepl-dict-get form "pprint"))
             (dbg-buf (cider-popup-buffer "*cider-storm-dbg*" 'select 'clojure-mode)))
                        
        (with-current-buffer dbg-buf
          (let ((inhibit-read-only t))
            (cider-storm--debug-mode-enter)
            (insert "\n")
            (insert pprinted-form)
            (goto-char (point-min))
            (forward-line 1)
            2))))))

(defun cider-storm--entry-type (entry)
  (pcase (nrepl-dict-get entry "type")
    ("fn-call"   'fn-call)
    ("fn-return" 'fn-return)
    ("expr"      'expr)))

(defun cider-storm--show-header-overlay (form-line entry-idx total-entries)
  "Helper to display the overlay at the top of the current debugging form."

  (let* ((form-beg-pos (save-excursion
                         (goto-char (point-min))
                         (forward-line (- form-line 2))
                         (point)))
         (o (make-overlay form-beg-pos form-beg-pos (current-buffer))))
    (overlay-put o 'category 'debug-code)
    (overlay-put o 'cider-temporary t)
    (overlay-put o 'face 'cider-debug-code-overlay-face)
    (overlay-put o 'priority 2000)
    (overlay-put o 'before-string (format "CiderStorm - Debugging (%d/%d), press h for help" entry-idx total-entries))
    (push #'cider--delete-overlay (overlay-get o 'modification-hooks))))

(defun cider-storm--clojure-form-source-hash (s)

  "Hash a clojure form string into a 32 bit num.
  Meant to be called with printed representations of a form,
  or a form source read from a file."

  (let* ((M 4294967291)
         (clean-s (thread-last
                   s
                   (replace-regexp-in-string "#[\/\.a-zA-Z0-9_\-]+" "") ;; remove tage
                   (replace-regexp-in-string "\\^:[a-zA-Z0-9_\-]+" "")  ;; remove meta keys
                   (replace-regexp-in-string "\\^\{.+?\}" "")           ;; remove meta maps
                   (replace-regexp-in-string ";.+\n" "")                ;; remove comments
                   (replace-regexp-in-string "[\s\t\n]+" "")))          ;; remove non visible
         (slen (string-width clean-s))
         (sum 0)
         (mul 1)
         (i 0))
    (while (< i slen)
      (let* ((cval (elt clean-s i)))
        (setq mul (if (= 0 (mod i 4)) 1 (* mul 256)))
        (setq sum (+ sum (* cval mul)))
        (setq i (+ i 1))))
    (mod sum M)))

(defun cider-storm--debug-goto-keyval (str-coord)
  (when-let* ((limit (ignore-errors (save-excursion (up-list) (point)))))
    (let* ((coord-type (elt str-coord 0))
           (coord-hash (string-to-number (substring str-coord 1)))
           (found nil))
      (while (and (< (point) limit)
                  (not found))
        (let* ((curr-sexp-beg (point))
               (curr-sexp-end (save-excursion (clojure-forward-logical-sexp 1) (point)))
               (sexp-str (buffer-substring curr-sexp-beg curr-sexp-end))
               (sexp-hash (cider-storm--clojure-form-source-hash sexp-str)))
          (if (= coord-hash sexp-hash)
              (setq found t)
            (clojure-forward-logical-sexp 1))))
      (if (not found)
          (error (message "Can't find instrumented key sexp"))
        (when (eq coord-type ?V)
          (clojure-forward-logical-sexp 1))))))

;; This was stolen from Cider bacause we do something
;; a little different here on map coordinates
(defun cider-storm--debug-move-point (coordinates)

  "Place point on after the sexp specified by COORDINATES.
COORDINATES is a list of integers that specify how to navigate into the
sexp that is after point when this function is called.

In addition to numbers, a coordinate can be a string.
This string contains directions to find a key or value in a map
or an expression in a set."
  
  (condition-case-unless-debug nil
      ;; Navigate through sexps inside the sexp.
      (let ((in-syntax-quote nil))
        (while coordinates
          (while (clojure--looking-at-non-logical-sexp)
            (forward-sexp))
          ;; An `@x` is read as (deref x), so we pop coordinates once to account
          ;; for the extra depth, and move past the @ char.
          (if (eq ?@ (char-after))
              (progn (forward-char 1)
                     (pop coordinates))
            (down-list)
            ;; Are we entering a syntax-quote?
            (when (looking-back "`\\(#{\\|[{[(]\\)" (line-beginning-position))
              ;; If we are, this affects all nested structures until the next `~',
              ;; so we set this variable for all following steps in the loop.
              (setq in-syntax-quote t))
            (when in-syntax-quote
              ;; A `(. .) is read as (seq (concat (list .) (list .))). This pops
              ;; the `seq', since the real coordinates are inside the `concat'.
              (pop coordinates)
              ;; Non-list seqs like `[] and `{} are read with
              ;; an extra (apply vector ...), so pop it too.
              (unless (eq ?\( (char-before))
                (pop coordinates)))
            ;; #(...) is read as (fn* ([] ...)), so we patch that here.
            (when (looking-back "#(" (line-beginning-position))
              (pop coordinates))
            (if coordinates
                (let ((next (pop coordinates)))
                  (when in-syntax-quote
                    ;; We're inside the `concat' form, but we need to discard the
                    ;; actual `concat' symbol from the coordinate.
                    (setq next (1- next)))
                  ;; String coordinates are map keys.
                  (if (stringp next)
                      (cider-storm--debug-goto-keyval next)
                    (clojure-forward-logical-sexp next)
                    (when in-syntax-quote
                      (clojure-forward-logical-sexp 1)
                      (forward-sexp -1)
                      ;; Here a syntax-quote is ending.
                      (let ((match (when (looking-at "~@?")
                                     (match-string 0))))
                        (when match
                          (setq in-syntax-quote nil))
                        ;; A `~@' is read as the object itself, so we don't pop
                        ;; anything.
                        (unless (equal "~@" match)
                          ;; Anything else (including a `~') is read as a `list'
                          ;; form inside the `concat', so we need to pop the list
                          ;; from the coordinates.
                          (pop coordinates))))))
              ;; If that extra pop was the last coordinate, this represents the
              ;; entire #(...), so we should move back out.
              (backward-up-list)))
          ;; Finally skip past all #_ forms
          (cider--debug-skip-ignored-forms))
        ;; Place point at the end of instrumented sexp.
        (clojure-forward-logical-sexp 1))
    ;; Avoid throwing actual errors, since this happens on every breakpoint.
    (error (message "Can't find instrumented sexp, did you edit the source?"))))

(defun cider-storm--display-step (form-id entry trace-cnt)
  "Given a FORM-ID, the current timeline ENTRY and a TRACE-CNT
does everything necessary to display the entry on the form."

  (let* ((form-line (cider-storm--select-form form-id))
         (entry-type (cider-storm--entry-type entry))
         (entry-idx (nrepl-dict-get entry "idx")))
    
    (if-let* ((coord (nrepl-dict-get entry "coord")))
        (cider-storm--debug-move-point coord)

      ;; if it has a nil coord and is a fn-return go to the end to display the result
      (when (eq entry-type 'fn-return)
        (clojure-forward-logical-sexp 1)))

    (cider--debug-remove-overlays)

    (when form-line
      (cider-storm--show-header-overlay form-line entry-idx trace-cnt))

    (when (or (eq entry-type 'fn-return)
              (eq entry-type 'expr))
      (let* ((val-ref (nrepl-dict-get entry "result"))
             (val-pprint (cider-storm--pprint-val-ref val-ref
                                                      50
                                                      3
                                                      nil
                                                      nil))
             (val-str (nrepl-dict-get val-pprint "val-str")))

        (cider--debug-display-result-overlay val-str)))))

(defun cider-storm--show-help ()
  (let* ((help-text "Keybidings

P - Step prev over. Go to the previous recorded step on the same frame.
p - Step prev. Go to the previous recorded step.
n - Step next. Go to the next recorded step.
N - Step next over. Go to the next recorded step on the same frame.
^ - Step out. Go to the next recorded step after this frame.
< - Step first. Go to the first recorded step for the function you called cider-storm-debug-current-fn on.
> - Step last. Go to the last recorded step for the function you called cider-storm-debug-current-fn on.
. - Pprint current value.
i - Inspect current value using the Cider inspector.
t - Tap the current value.
l - Show current locals.
D - Define all recorded bindings for this frame (scope capture like).
h - Prints this help.
q - Quit the debugger mode.")

         (help-buf (cider-popup-buffer "*cider-storm-help*" 'select)))
    (with-current-buffer help-buf
      (let ((inhibit-read-only t))
        (insert help-text)))))

(defun cider-storm--pprint-current-entry ()
  "Popups a buffer and pretty prints the current entry result."

  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (when (or (eq entry-type 'fn-return)
              (eq entry-type 'expr))
      (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result"))
             (val-pprint (cider-storm--pprint-val-ref val-ref
                                                      50
                                                      3
                                                      nil
                                                      't))
             (val-str (nrepl-dict-get val-pprint "val-str"))
             (val-buffer (cider-popup-buffer "*cider-storm-pprint*" 'select 'clojure-mode)))

        (with-current-buffer val-buffer
          (let ((inhibit-read-only t))
            (insert val-str)))))))

(defun cider-storm--jump-to-code (flow-id thread-id next-entry)
  "Given a FLOW-ID, THREAD-ID and a timeline NEXT-ENTRY object moves the debugger
state and display the next entry."

  (let* ((curr-fn-call-idx (nrepl-dict-get cider-storm-current-frame "fn-call-idx"))
         (next-fn-call-idx (nrepl-dict-get next-entry "fn-call-idx"))
         (changing-frame? (not (eq curr-fn-call-idx next-fn-call-idx)))
         (curr-frame (if changing-frame?
                         (let* ((first-frame (cider-storm--frame-data flow-id thread-id 0))
                                (first-entry (cider-storm--timeline-entry flow-id thread-id 0 "at"))
                                (trace-cnt (cider-storm--trace-cnt flow-id thread-id)))
                           (setq cider-storm-current-thread-trace-cnt trace-cnt)
                           (setq cider-storm-current-frame first-frame)
                           (setq cider-storm-current-entry first-entry)
                           first-frame)
                       cider-storm-current-frame))

         (next-frame (if changing-frame?
                         (cider-storm--frame-data flow-id thread-id next-fn-call-idx)
                       curr-frame))
         (next-form-id (nrepl-dict-get next-frame "form-id")))

    (when changing-frame?
      (setq cider-storm-current-frame next-frame))

    (cider-storm--display-step next-form-id next-entry cider-storm-current-thread-trace-cnt)

    (setq cider-storm-current-entry next-entry)))

(defun cider-storm--jump-to (n)
  "Jump into the N possition in the timeline for the current threa and flow."

  (let* ((entry (cider-storm--timeline-entry cider-storm-current-flow-id
                                             cider-storm-current-thread-id
                                             n
                                             "at")))
    (cider-storm--jump-to-code cider-storm-current-flow-id
                               cider-storm-current-thread-id
                               entry)))

(defun cider-storm--step (drift)
  "Step the debugger. DRIFT should be a string with any of:
 next-out, next, next-over, prev, prev-over. "

  (let* ((curr-idx (nrepl-dict-get cider-storm-current-entry "idx")))
    (if curr-idx
        (let* ((next-entry (cider-storm--timeline-entry cider-storm-current-flow-id
                                                        cider-storm-current-thread-id
                                                        curr-idx
                                                        drift)))
          (cider-storm--jump-to-code cider-storm-current-flow-id
                                     cider-storm-current-thread-id
                                     next-entry))

      (message "Not pointing at any recording entry."))))


(defun cider-storm--define-all-bindings-for-frame ()
  "Retrieves all bindings for the current debugger position and
defines them on the current namespace."

  (let* ((bindings (cider-storm--bindings cider-storm-current-flow-id
                                          cider-storm-current-thread-id
                                          (nrepl-dict-get cider-storm-current-entry "idx")
                                          't)))
    (nrepl-dict-map
     (lambda (bind-name bind-val-id)
       (cider-interactive-eval (format "(def %s (flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d)))"
                                       bind-name
                                       bind-val-id)))
     bindings)))

(defun cider-storm--inspect-current-entry ()
  "Opens the cider inspector for the current entry result."

  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (if (or (eq entry-type 'fn-return)
            (eq entry-type 'expr))

        (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result")))
          (cider-inspect-expr (format "(flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d))" val-ref)
                              (cider-current-ns)))

      (message "You are currently positioned in a FnCall which is not inspectable."))))

(defun cider-storm--tap-current-entry ()
  "Taps the current entry result."

  (let* ((entry-type (cider-storm--entry-type cider-storm-current-entry)))
    (if (or (eq entry-type 'fn-return)
            (eq entry-type 'expr))

        (let* ((val-ref (nrepl-dict-get cider-storm-current-entry "result")))
          (cider-interactive-eval (format "(tap> (flow-storm.runtime.values/deref-value (flow-storm.types/make-value-ref %d)))" val-ref)))

      (message "You are currently positioned in a FnCall which is not inspectable."))))

(defun cider-storm--debug-fn (fn-call)
  "Given FN-CALL which should be a string with a fully qualified function name,
finds the first recording entry for it and starts the debugger there."

  (let* ((form-id (nrepl-dict-get fn-call "form-id"))
         (flow-id (nrepl-dict-get fn-call "flow-id"))
         (thread-id (nrepl-dict-get fn-call "thread-id"))
         (trace-cnt (cider-storm--trace-cnt flow-id thread-id)))
    (setq cider-storm-current-entry fn-call)
    (setq cider-storm-current-flow-id flow-id)
    (setq cider-storm-current-thread-id thread-id)
    (setq cider-storm-initial-entry fn-call)
    (setq cider-storm-current-thread-trace-cnt trace-cnt)
    (setq cider-storm-current-frame nil)
    (cider-storm--display-step form-id fn-call cider-storm-current-thread-trace-cnt)))

(defun cider-storm--debug-flow (flow-id)

  "Given a FLOW-ID finds the first recording entry for it and
 starts the debugger there."

  (let* ((fn-call (cider-storm--find-flow-fn-call flow-id)))
    (if fn-call
        (cider-storm--debug-fn fn-call)
      (message "No recordings found for flow %s" flow-id))))

(defun cider-storm--show-current-locals ()
  "Retrieves bindings for the current index and opens a buffer displaying them"

  (let* ((bindings (cider-storm--bindings cider-storm-current-flow-id
                                          cider-storm-current-thread-id
                                          (nrepl-dict-get cider-storm-current-entry "idx")
                                          nil))
         (locals (nrepl-dict-map
                  (lambda (bind-name bind-val-id)
                    (let* ((val-pprint (cider-storm--pprint-val-ref bind-val-id
                                                                    5
                                                                    1
                                                                    nil
                                                                    nil))
                           (val-str (nrepl-dict-get val-pprint "val-str")))
                      (list bind-name val-str)))
                  bindings))
         (locals-text (cider--debug-format-locals-list locals)))

    (let* ((locals-buf (cider-popup-buffer "*cider-storm-locals*" 'select)))
      (with-current-buffer locals-buf
        (let ((inhibit-read-only t))
          (insert locals-text))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Debugger interactive API ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun cider-storm-clear-recordings ()

  "Clear all FlowStorm recordings, for every flow and every thread.

Useful for running it before executing the code you are interested in debugging,
to ensure all the recordings have to do with the code you just run."

  (interactive)

  (cider-storm--clear-recordings))

(defun cider-storm-debug-current-fn ()

  "When the cursor is over a fn name, it will start the debugger
on the first recording found for that fn name. Will search every flow and
every thread."

  (interactive)

  (cider-try-symbol-at-point
   "Debug fn"
   (lambda (var-name)
     (let* ((info (cider-var-info var-name))
            (fn-ns (nrepl-dict-get info "ns"))
            (fn-name (nrepl-dict-get info "name"))
            (fq-fn-name (format "%s/%s" fn-ns fn-name))
            (fn-call (when (and fn-ns fn-name)
                       (cider-storm--find-fn-call fq-fn-name 0 nil))))
       (if fn-call
           (cider-storm--debug-fn fn-call)
         (message "No recordings found for %s/%s" fn-ns fn-name))))))

(defun cider-storm-debug-fn ()

  "Lets you select a function from a list of all the functions currently recorded.
Will search every flow and every thread.

After selecting one, will start the debugger on that function."

  (interactive)

  (let* ((fns (cider-storm--recorded-functions))
         (fq-fn-name (completing-read "Recorded function :"
                                      (mapcar (lambda (fn-dict)
                                                (nrepl-dict-get fn-dict "fq-fn-name"))
                                              fns)))
         (fn-call (cider-storm--find-fn-call fq-fn-name 0 nil)))
    (if fn-call
        (cider-storm--debug-fn fn-call)
      (message "No recordings found for %s" fq-fn-name))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; cider-storm minor mode ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-minor-mode cider-storm-debugging-mode
  "Toggle cider-storm-debugging-mode."
  ;; The initial value.
  :init-value nil
  ;; The indicator for the mode line.
  :lighter " STORM-DBG"
  ;; The minor mode bindings.
  :keymap
  '(("q" . (lambda () (interactive) (cider-storm--debug-mode-quit)))
    ("^" . (lambda () (interactive) (cider-storm--step "next-out")))
    ("n" . (lambda () (interactive) (cider-storm--step "next")))
    ("N" . (lambda () (interactive) (cider-storm--step "next-over")))
    ("p" . (lambda () (interactive) (cider-storm--step "prev")))
    ("P" . (lambda () (interactive) (cider-storm--step "prev-over")))
    ("<" . (lambda () (interactive) (cider-storm--jump-to (nrepl-dict-get cider-storm-initial-entry "idx"))))
    (">" . (lambda () (interactive) (cider-storm--jump-to (nrepl-dict-get cider-storm-initial-entry "ret-idx"))))
    ("h" . (lambda () (interactive) (cider-storm--show-help)))
    ("." . (lambda () (interactive) (cider-storm--pprint-current-entry)))
    ("i" . (lambda () (interactive) (cider-storm--inspect-current-entry)))
    ("t" . (lambda () (interactive) (cider-storm--tap-current-entry)))
    ("l" . (lambda () (interactive) (cider-storm--show-current-locals)))    
    ("D" . (lambda () (interactive) (cider-storm--define-all-bindings-for-frame)))))

(provide 'cider-storm-stepper)
;;; cider-storm-stepper.el ends here
