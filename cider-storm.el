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

(require 'cider)
(require 'cider-storm-stepper)

(defgroup cider-storm nil
  "Emacs Cider front-end for the FlowStorm debugger"
  :prefix "cider-storm"
  :group 'applications
  :link '(url-link :tag "GitHub" "https://github.com/jpmonettas/cider-storm"))

(defcustom cider-storm-flow-storm-theme "dark"

  "The theme to use when starting the debugger via flow-storm-start"

  :type 'string
  :options '("dark" "light")
  :group 'cider-storm)

(defmacro cider-storm--ensure-connected (&rest forms)
  `(if (cider-connected-p)
       (progn ,@forms)
     (message "Cider should be connected first")))

(defun cider-storm--clojure-storm-env-p ()
  "Check if the repl connected process is running Clojure Storm"

  (thread-first (cider-nrepl-send-sync-request `("op"   "eval"
                                                 "code" "((requiring-resolve 'flow-storm.utils/storm-env?))"))
                (nrepl-dict-get "value")
                (equal "true")))

(defun cider-storm-storm-start-gui ()

  "Set up the flow-storm debugger and show the GUI."

  (interactive)
  (cider-storm--ensure-connected
   (cider-interactive-eval
    (format "((requiring-resolve 'flow-storm.api/local-connect) {:theme :%s})"
            cider-storm-flow-storm-theme))))

(defun cider-storm-storm-stop-gui ()

  "Close the flow-storm debugger window and clears the debugger state"

  (interactive)
  (cider-storm--ensure-connected
   (if (cider-storm--clojure-storm-env-p)
       (message "Since you are running ClojureStorm is better to just close the window so you keep the debugger running")
       (cider-interactive-eval "((requiring-resolve 'flow-storm.api/stop))"))))

(defun cider-storm-instrument-current-ns (arg)

  "Instrument the namespace you are currently on."

  (interactive "P")
  (if (cider-storm--clojure-storm-env-p)
      
      (message "No need to instrument namespaces since you are running with Clojure Storm")
    
    (let* ((prefix (eq (car arg) 4))
           (current-ns (cider-current-ns))
           (inst-fn-name (if prefix
                             "uninstrument-namespaces-clj"
                           "instrument-namespaces-clj"))
           (clj-cmd (format "(let [inst-ns (requiring-resolve 'flow-storm.api/%s)]
                              (inst-ns #{\"%s\"} {:prefixes? false}))"
                            inst-fn-name
                            current-ns)))

      (cider-interactive-eval clj-cmd))))

(defun cider-storm-instrument-last-form ()

  "Instrument the form you are currently on."

  (interactive)

  (cider-storm--ensure-connected
   (if (cider-storm--clojure-storm-env-p)
       
       (message "No need to instrument the form since you are running with Clojure Storm")
     
     (let* ((current-ns (cider-current-ns))
            (form (cider-last-sexp))
            (clj-cmd (format "(flow-storm.api/instrument* {} %s)" form)))
       (cider-interactive-eval clj-cmd nil nil `(("ns" ,current-ns)))))))

(defun cider-storm-instrument-current-defn ()

  "Instrument the form you are currently on."

  (interactive)

  (cider-storm--ensure-connected
   (if (cider-storm--clojure-storm-env-p)
       
       (message "No need to instrument the form since you are running with Clojure Storm")
     
     (let* ((current-ns (cider-current-ns))
            (form (cider-defun-at-point))
            (clj-cmd (format "(flow-storm.api/instrument* {} %s)" form)))
       (cider-interactive-eval clj-cmd nil nil `(("ns" ,current-ns)))))))

(defun cider-storm-tap-last-result ()

  "Tap *1 (last evaluation result)."

  (interactive)
  (cider-storm--ensure-connected
   (cider-interactive-eval "(tap> *1)")))

(defun cider-storm-show-current-var-doc ()

  "Show doc for var under point."

  (interactive)

  (cider-try-symbol-at-point
   "Flow doc for"
   (lambda (var-name)
     (let* ((info (cider-var-info var-name))
            (fn-ns (nrepl-dict-get info "ns"))
            (fn-name (nrepl-dict-get info "name"))
            (clj-cmd (format "(flow-storm.api/show-doc '%s/%s)" fn-ns fn-name)))
       (when (and fn-ns fn-name)
         (cider-interactive-eval clj-cmd))))))

(defun cider-storm-rtrace-last-sexp ()

  "#rtrace current form."

  (interactive)

  (cider-storm--ensure-connected
   (if (cider-storm--clojure-storm-env-p)
       
       (message "No need to instrument the form since you are running with Clojure Storm")
     
     (let* ((current-ns (cider-current-ns))
            (form (cider-last-sexp))
            (clj-cmd (format "(flow-storm.api/runi {} %s)" form)))
       (cider-interactive-eval clj-cmd nil nil `(("ns" ,current-ns)))))))

(defun cider-storm-eval-and-debug-last-form ()

  "Convenience function to eval a form and immediately put the emacs stepper
on the first recording."
  
  (interactive)

  (cider-storm--ensure-connected
   (let* ((current-ns (cider-current-ns))
          (form (cider-last-sexp)))

     (if (cider-storm--clojure-storm-env-p)
         
         (let* ((clj-cmd (format "%s" form)))
           (cider-storm-clear-recordings)
           (cider-nrepl-send-sync-request `("op"   "eval"
                                            "code" ,clj-cmd
                                            "ns"   ,current-ns))           
           (cider-storm--debug-flow nil))
       
       (let* ((clj-cmd (format "#rtrace %s" form)))
         (cider-interactive-eval clj-cmd nil nil `(("ns" ,current-ns)))
         (cider-storm--debug-flow 0))))))

(defvar cider-storm-map
  (let (cider-storm-map)
    (define-prefix-command 'cider-storm-map)

    (define-key cider-storm-map (kbd "s") #'cider-storm-storm-start-gui)

    (define-key cider-storm-map (kbd "x") #'cider-storm-storm-stop-gui)

    (define-key cider-storm-map (kbd "n") #'cider-storm-instrument-current-ns)

    (define-key cider-storm-map (kbd "f") #'cider-storm-instrument-last-form)
    
    (define-key cider-storm-map (kbd "c") #'cider-storm-instrument-current-defn)
    
    (define-key cider-storm-map (kbd "e") #'cider-storm-eval-and-debug-last-form)
    
    (define-key cider-storm-map (kbd "t") #'cider-storm-tap-last-result)

    (define-key cider-storm-map (kbd "D") #'cider-storm-show-current-var-doc)

    (define-key cider-storm-map (kbd "r") #'cider-storm-rtrace-last-sexp)

    (define-key cider-storm-map (kbd "d") #'cider-storm-debug-current-fn)    
    (define-key cider-storm-map (kbd "j") #'cider-storm-debug-fn)    
    (define-key cider-storm-map (kbd "l") #'cider-storm-clear-recordings)

    cider-storm-map)
  "CIDER Storm keymap.")

;; (define-key cider-mode-map (kbd "C-c C-f") 'cider-storm-map)

(provide 'cider-storm)
;;; cider-storm.el ends here
