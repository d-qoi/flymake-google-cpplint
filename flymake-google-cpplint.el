;;; flymake-google-cpplint.el --- Help to comply with the Google C++ Style Guide -*- lexical-binding: t -*-

;; Copyright 2014 Akiha Senda
;; Copyright 2023 Alex Hirschfeld

;; Author: Akiha Senda <senda.akiha@gmail.com>
;; URL: https://github.com/senda-akiha/flymake-google-cpplint/
;; Created: 02 February 2014

;; Updated by: Alex Hirschfeld <alex@d-qoi.com>
;; URL: https://github.com/d-qoi/flymake-google-cpplint/
;; Updated: 20 July 2023
;; Version: 2.0.0
;; Keywords: flymake, C, C++

;; This file is not part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; If you're want to write code according to the [Google C++ Style Guide](http://google-styleguide.googlecode.com/svn/trunk/cppguide.xml), this will help a great deal.

;; I recommend that the package [google-c-style](http://melpa.milkbox.net/#/google-c-style) also installed with.

;; For more infomations, please check the GitHub
;; https://github.com/flymake/flymake-google-cpplint/

;; Updater commentary:
;; I basically just completely rewrote this so that it would use the new flymake diagnostic functions
;; The code uses very little of the original, none of it actually. But, the original was used for inspiration.
;; This was written for my needs, so not all of the cpplint args have been added in, just the ones I use personally.
;; Eglot overloading the flymake-diagnostic-function variable is annoying.

;;; Code:

(defgroup flymake-google-cpplint nil
  "Customize group for cpplint"
  :prefix "cpplint-"
  :group 'c)

(defcustom cpplint-active-modes '(c-mode c++-mode c-ts-mode c++-ts-mode)
  "List of modes this flymake backend will be active in."
  :group 'flymake-google-cpplint
  :type '(repeat symbol))

(defcustom cpplint-executable
  (executable-find "cpplint")
  "Do we have cpplint?"
  :group 'flymake-google-cpplint)

(defcustom cpplint-verbosity 3
  "Specify a number 0-5 to restrict errors to certain verbosity levels.
Errors with lower verbosity levels have lower confidence and are more
likely to be false positives. 0 is least confident, 5 is most confident."
  :group 'flymake-google-cpplint
  :type '(number :tag "0-5"))

(defcustom cpplint-filter nil
  "Specify a comma-separated list of category-filters to apply: only
error messages whose category names pass the filters will be printed.
(Category names are printed with the message and look like
\"[whitespace/indent]\".)  Filters are evaluated left to right.
\"-FOO\" means \"do not print categories that start with FOO\".
\"+FOO\" means \"do print categories that start with FOO\".

Examples: --filter=-whitespace,+whitespace/braces
          --filter=-whitespace,-runtime/printf,+runtime/printf_format
          --filter=-,+build/include_what_you_use

To see a list of all the categories used in cpplint, pass no arg:
   --filter="
  :group 'flymake-google-cpplint)

(defcustom cpplint-linelength 120
  "This is the allowed line length for the project. The default value is
80 characters.

Examples:
  --linelength=120"
  :type '(number :tag "80 or higher")
  :group 'flymake-google-cpplint)

(defcustom cpplint-counting 'total
  "The total number of errors found is always printed. If
'toplevel' is provided, then the count of errors in each of
the top-level categories like 'build' and 'whitespace' will
also be printed. If 'detailed' is provided, then a count
is provided for each category like 'build/class'."
  :type '(choice
          (const :tag "Total" "total")
          (const :tag "Top Level" "toplevel")
          (const :tag "Detailed" "detailed"))
  :group 'flymake-google-cpplint)

(defvar-local cpplint--flymake-proc nil)

(defun cpplint-create-command (filename)
  "Construct a command that flymake can use to check C/C++ source."
  (remove nil
          (list
           cpplint-executable
           "--output=emacs"
           (if cpplint-verbosity (format "--verbose=%d" cpplint-verbosity))
           (if cpplint-filter (format "--filter=%s" cpplint-filter))
           (if cpplint-filter (format "--counting=%s" cpplint-counting))
           (if cpplint-linelength (format "--linelength=%d" cpplint-linelength))
           filename)))

;;;###autoload
(defun cpplint-flymake (report-fn &rest _args)
  "Flymake CPPLine backend.
Copied mostly from https://www.gnu.org/software/emacs/manual/html_node/flymake/An-annotated-example-backend.html"
  (unless cpplint-executable
    (error "cpplint not found, define cpplint-executable"))

  (when (process-live-p cpplint--flymake-proc)
    (kill-process cpplint--flymake-proc))

  (let* ((source (current-buffer))
         (filename (buffer-file-name))
         (command (cpplint-create-command filename)))
    (save-restriction
      ;; Use whole buffer, save restrictions will revert this when done.
      (widen)
      (setq
       cpplint--flymake-proc
       (make-process
        :name "cpplint-flymake"
        :noquery t
        :connection-type 'pipe
        ;; Collect output in new temp buffer.
        :buffer (generate-new-buffer "*cpplint-flymake*")
        :command command
        :sentinel (lambda (proc _event)
                    ;; Check that the process has indeed exited, as it might
                    ;; be simply suspended.
                    ;;
                    (when (memq (process-status proc) '(exit signal))
                      (unwind-protect
                          ;; Only proceed if `proc' is the same as
                          ;; `cpplint--flymake-proc', which indicates that
                          ;; `proc' is not an obsolete process.
                          ;;
                          (if (with-current-buffer source (eq proc cpplint--flymake-proc))
                              (with-current-buffer (process-buffer proc)
                                (goto-char (point-min))
                                ;; Parse the output buffer for diagnostic's
                                ;; messages and locations, collect them in a list
                                ;; of objects, and call `report-fn'.
                                ;;
                                (cl-loop
                                 ;; while doesn't return nil
                                 while (search-forward-regexp "^\\(.*\\):\\([0-9]+\\): \\(.*\\)$" nil t)
                                 ;; for is basically let* vars being set per iteration
                                 for file = (match-string 1)
                                 for linum = (string-to-number (match-string 2))
                                 for msg = (concat "cpplint:" (match-string 3))
                                 for (beg . end) = (flymake-diag-region source linum)
                                 ;; can use all for (let variables) for this final thing.
                                 collect (flymake-make-diagnostic source beg end :warning msg)
                                 ;; cons output of collect into diags for later use.
                                 into diags
                                 ;; Call with diags before it gets deallocated.
                                 finally (funcall report-fn diags)))
                            (flymake-log :warning "Canceling obsolete check %s" proc))
                        ;; Cleanup the temporary buffer used to hold the
                        ;; check's output.
                        ;;
                        (kill-buffer (process-buffer proc))
                        )))) ;; end of make-process
       ) ;; end of setq
      ) ;; end of save-restrction
    ) ;; end of let*
  ) ;; end of defun.

;;;###autoload
(defun cpplint-hook-flymake-backend ()
  "Adds cpplint diagnostic function to flymake-diagnostic-functions list.
Add this hook to eglot-managed-mode-hook if eglot is enabled for c/c++ buffers.
Add this to prog-mode-hook or any of the c-common-mode derivitive hooks otherwise."
  (interactive)
  (when (memq major-mode cpplint-active-modes)
    (add-hook 'flymake-diagnostic-functions 'cpplint-flymake)))

(provide 'flymake-google-cpplint)
