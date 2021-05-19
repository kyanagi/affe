;;; affe.el --- Asynchronous Fuzzy Finder for Emacs -*- lexical-binding: t -*-

;; Author: Daniel Mendler
;; Maintainer: Daniel Mendler
;; Created: 2021
;; License: GPL-3.0-or-later
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (consult "0.7"))
;; Homepage: https://github.com/minad/affe

;;; Commentary:

;; Asynchronous Fuzzy Finder for Emacs

;;; Code:

(require 'consult)
(require 'server)
(eval-when-compile (require 'subr-x))

(defvar affe-find-command "find -not ( -wholename */.* -prune ) -type f")
(defvar affe-grep-command "rg --null --line-buffered --color=never --max-columns=1000 --no-heading --line-number -v \"^$\" .")
(defvar affe-regexp-function #'affe-default-regexp)
(defvar affe-highlight-function #'affe-default-highlight)
(defvar affe--grep-history nil)
(defvar affe--find-history nil)

(defun affe-default-regexp (pattern)
  "Default PATTERN regexp transformation function."
  (mapcan (lambda (word)
            (condition-case nil
                (progn (string-match-p word "") (list word))
              (invalid-regexp nil)))
          (split-string pattern nil t)))

(defun affe-default-highlight (_ cands)
  "Default highlighting function for CANDS."
  cands)

(defconst affe--backend-file
  (expand-file-name
   (concat
    (or (and load-file-name
             (file-name-directory load-file-name))
        default-directory)
    "affe-backend.el")))

(defun affe--send (name expr callback)
  "Send EXPR to server NAME and call CALLBACK with result."
  (let* ((result)
         (proc (make-network-process
                :name name
                :noquery t
                :sentinel
                (lambda (_proc _event)
                  (funcall callback (and result (read result))))
                :filter
                (lambda (_proc out)
                  (dolist (line (split-string out "\n"))
                    (cond
                     ((string-prefix-p "-print " line)
                      (setq result (server-unquote-arg
                                    (string-remove-prefix "-print " line))))
                     ((string-prefix-p "-print-nonl " line)
                      (setq result
                            (concat
                             result
                             (server-unquote-arg
                              (string-remove-prefix "-printnonl " line))))))))
                :coding 'raw-text-unix
                :family 'local
                :service (expand-file-name name server-socket-dir))))
    (process-send-string
     proc
     (format "-eval %s \n" (server-quote-arg (prin1-to-string expr))))
    proc))

(defun affe--async (async cmd)
  "Create asynchrous completion function from ASYNC with backend CMD."
  (let ((proc)
        (last-input)
        (name (make-temp-name "affe-")))
    (lambda (action)
      (pcase action
        ((pred stringp)
         (unless (or (equal "" action) (equal action last-input))
           (ignore-errors (delete-process proc))
           (setq proc (affe--send name
                                  `(affe-backend-filter ,@(funcall affe-regexp-function action))
                                  (lambda (result)
                                    (setq last-input action)
                                    (funcall async 'flush)
                                    (funcall async result)
                                    (funcall async 'refresh))))))
        ('destroy
         (ignore-errors (delete-process proc))
         (affe--send name '(kill-emacs) #'ignore)
         (funcall async 'destroy))
        ('setup
         (funcall async 'setup)
         (call-process
          (file-truename
           (expand-file-name invocation-name
                             invocation-directory))
          nil nil nil "-Q" (concat "--daemon=" name)
          "-l" affe--backend-file)
         (affe--send name `(and (run-at-time 0 nil (lambda () (affe-backend-start ,cmd))) nil) #'ignore))
        (_ (funcall async action))))))

(defun affe--passthrough-all-completions (str table pred _point)
  "Passthrough completion function.
See `completion-all-completions' for the arguments STR, TABLE, PRED and POINT."
  (let ((completion-regexp-list))
    (funcall affe-highlight-function str (all-completions "" table pred))))

(defun affe--passthrough-try-completion (_str table pred _point)
  "Passthrough completion function.
See `completion-try-completion' for the arguments STR, TABLE, PRED and POINT."
  (let ((completion-regexp-list))
    (and (try-completion "" table pred) t)))

(defun affe--read (prompt dir &rest args)
  "Asynchronous selection function with PROMPT in DIR.
ARGS are passed to `consult--read'."
  (let* ((prompt-dir (consult--directory-prompt prompt dir))
         (default-directory (cdr prompt-dir)))
    (consult--minibuffer-with-setup-hook
        (lambda ()
          (setq-local completion-styles-alist
                      (cons
                       (list 'affe--passthrough
                             #'affe--passthrough-try-completion
                             #'affe--passthrough-all-completions
                             "")
                       completion-styles-alist)
                      completion-styles '(affe--passthrough)
                      completion-category-defaults nil
                      completion-category-overrides nil))
      (apply #'consult--read (append args (list :prompt (car prompt-dir)))))))

(defun affe-grep (&optional dir initial)
  "Fuzzy grep in DIR with optional INITIAL input."
  (interactive)
  (affe--read
   "Fuzzy grep" dir
   (thread-first (consult--async-sink)
     (consult--async-transform consult--grep-matches)
     (affe--async affe-grep-command))
   :sort nil
   :initial initial
   :history '(:input affe--grep-history)
   :category 'consult-grep
   :require-match t
   :add-history (thing-at-point 'symbol)
   :lookup #'consult--lookup-cdr
   :state (consult--grep-state)))

(defun affe-find (&optional dir initial)
  "Fuzzy find in DIR with optional INITIAL input."
  (interactive)
  (find-file
   (affe--read
    "Fuzzy find" dir
    (thread-first (consult--async-sink)
      (consult--async-map (lambda (x) (string-remove-prefix "./" x)))
      (affe--async affe-find-command))
    :history '(:input affe--find-history)
    :sort nil
    :initial initial
    :category 'file
    :add-history (thing-at-point 'filename)
    :require-match t)))

(provide 'affe)
;;; affe.el ends here
