;;; ejump.el --- Jump to definition for erl -*- lexical-binding: t; -*-

;; Finding in Erlang code using find instead of tags
;; Based on https://github.com/jacktasia/dumb-jump
;; ...
;; EJump provides a xref-based interface for jumping to Erlang
;; definitions. It is based on tools such as grep, the silver searcher
;; (https://geoff.greer.fm/ag/), ripgrep
;; (https://github.com/BurntSushi/ripgrep) or git-grep
;; (https://git-scm.com/docs/git-grep).
;;
;; To enable EJump, and prefer it over erlang-mode's tags lookup,
;; add the following to your initialisation file:
;;
;;   (add-hook 'erlang-mode-hook 'my-set-xref-backend)
;;   (defun my-set-xref-backend ()
;;     (setq xref-backend-functions '(#'ejump-xref-activate)))
;;
;; Now pressing M-. on an identifier should open a buffer at the place
;; where it is defined, or a list of candidates if uncertain. This
;; list can be navigated using M-g M-n (next-error) and M-g M-p
;; (previous-error).

;; For debugging:
;;
;; (defun show-erl-id-at-pt ()
;;  (interactive)
;;  (erlang-with-id (kind module name arity) (erlang-get-identifier-at-point)
;;    (message "kind=%s module=%s name=%s arity=%s" kind module name arity)))
;;
;; (define-key erlang-mode-map (kbd "C-c i") 'show-erl-id-at-pt)

;;; Code:
(unless (require 'xref nil :noerror)
  (require 'etags))
(require 's)
(require 'dash)
(require 'popup)
(require 'cl-generic nil :noerror)
(require 'cl-lib)
(require 'erlang)

(defgroup ejump nil
  "Easily jump to project function and variable definitions"
  :group 'tools
  :group 'convenience)

;;;###autoload
(defvar ejump-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-g") 'ejump-go)
    (define-key map (kbd "C-M-p") 'ejump-back)
    (define-key map (kbd "C-M-q") 'ejump-quick-look)
    map))

(defcustom ejump-window
  'current
  "Which window to use when jumping.  Valid options are 'current (default) or 'other."
  :group 'ejump
  :type '(choice (const :tag "Current window" current)
                 (const :tag "Other window" other)))

(defcustom ejump-use-visible-window
  t
  "When true will jump in a visible window if that window already has the file open."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-selector
  'popup
  "Which selector to use when there is multiple choices.  `ivy` and `helm' are also supported."
  :group 'ejump
  :type '(choice (const :tag "Popup" popup)
                 (const :tag "Helm" helm)
                 (const :tag "Ivy" ivy)
                 (const :tag "Completing Read" completing-read)))

(defcustom ejump-ivy-jump-to-selected-function
  #'ejump-ivy-jump-to-selected
  "Prompts user for a choice using ivy then ejump to that choice."
  :group 'ejump
  :type 'function)

(defcustom ejump-prefer-searcher
  nil
  "The preferred searcher to use 'ag, 'rg, 'git-grep, 'gnu-grep,or 'grep.
If nil then the most optimal searcher will be chosen at runtime."
  :group 'ejump
  :type '(choice (const :tag "Best Available" nil)
                 (const :tag "ag" ag)
                 (const :tag "rg" rg)
                 (const :tag "grep" gnu-grep)
                 (const :tag "git grep" git-grep)
                 (const :tag "git grep + ag" git-grep-plus-ag)))

(defcustom ejump-force-searcher
  nil
  "Forcibly use searcher: 'ag, 'rg, 'git-grep, 'gnu-grep, or 'grep.
Set to nil to not force anything and use `ejump-prefer-searcher'
or most optimal searcher."
  :group 'ejump
  :type '(choice (const :tag "Best Available" nil)
                 (const :tag "ag" ag)
                 (const :tag "rg" rg)
                 (const :tag "grep" gnu-grep)
                 (const :tag "git grep" git-grep)
                 (const :tag "git grep + ag" git-grep-plus-ag)))

(defcustom ejump-grep-prefix
  "LANG=C"
  "Prefix to grep command.  Seemingly makes it faster for pure text."
  :group 'ejump
  :type 'string)

(defcustom ejump-grep-cmd
  "grep"
  "The path to grep.  By default assumes it is in path."
  :group 'ejump
  :type 'string)

(defcustom ejump-ag-cmd
  "ag"
  "The the path to the silver searcher.  By default assumes it is in path.  If not found fallbacks to grep."
  :group 'ejump
  :type 'string)

(defcustom ejump-rg-cmd
  "rg"
  "The the path to ripgrep.  By default assumes it is in path.  If not found fallbacks to grep."
  :group 'ejump
  :type 'string)

(defcustom ejump-git-grep-cmd
  "git grep"
  "The the path to git grep.  By default assumes it is in path.  If not found fallbacks to grep."
  :group 'ejump
  :type 'string)

(defcustom ejump-ag-word-boundary
  "(?![a-zA-Z0-9\\?\\*-])"
  "`\\b` thinks `-` is a word boundary.  When this matters use `\\j` instead and ag will use this value."
  :group 'ejump
  :type 'string)

(defcustom ejump-rg-word-boundary
  "($|[^a-zA-Z0-9\\?\\*-])"
  "`\\b` thinks `-` is a word boundary.  When this matters use `\\j` instead and rg will use this value."
  :group 'ejump
  :type 'string)

(defcustom ejump-git-grep-word-boundary
  "($|[^a-zA-Z0-9\\?\\*-])"
  "`\\b` thinks `-` is a word boundary.  When this matters use `\\j` instead and git grep will use this value."
  :group 'ejump
  :type 'string)

(defcustom ejump-grep-word-boundary
  "($|[^a-zA-Z0-9\\?\\*-])"
  "`\\b` thinks `-` is a word boundary.  When this matters use `\\j` instead and grep will use this value."
  :group 'ejump
  :type 'string)

(defcustom ejump-fallback-regexp
  "\\bJJJ\\j"
  "When ejump-fallback-search is t use this regexp.  Defaults to boundary search of symbol under point."
  :group 'ejump
  :type 'string)

(defcustom ejump-fallback-search
  t
  "If nothing is found with normal search fallback to searching the fallback regexp."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-force-grep
  nil
  "When t will use grep even if ag is available."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-zgrep-cmd
  "zgrep"
  "The path to grep to use for gzipped files.  By default assumes it is in path."
  :group 'ejump
  :type 'string)

(defcustom ejump-grep-args "-REn"
  "Grep command args [R]ecursive, [E]xtended regexps, and show line [n]umbers."
  :group 'ejump
  :type 'string)

(defcustom ejump-gnu-grep-args "-rEn"
  "Grep command args [r]ecursive and [E]xtended regexps, and show line [n]umbers."
  :group 'ejump
  :type 'string)

(defcustom ejump-max-find-time
  2
  "Number of seconds a grep/find command can take before being warned to use ag and config."
  :group 'ejump
  :type 'integer)

(defcustom ejump-functions-only
  nil
  "Should we only jump to functions?"
  :group 'ejump
  :type 'boolean)

(defcustom ejump-quiet
  nil
  "If non-nil EJump will not log anything to *Messages*."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-ignore-context
  nil
  "If non-nil EJump will ignore the context of point when jumping."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-git-grep-search-untracked
  t
  "If non-nil EJump will also search untracked files when using searcher git-grep."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-git-grep-search-args
  ""
  "Appends the passed arguments to the git-grep search function. Default: \"\""
  :group 'ejump
  :type 'string)

(defcustom ejump-ag-search-args
  ""
  "Appends the passed arguments to the ag search function. Default: \"\""
  :group 'ejump
  :type 'string)

(defcustom ejump-rg-search-args
  "--pcre2"
  "Appends the passed arguments to the rg search function. Default: \"--pcre2\""
  :group 'ejump
  :type 'string)


(defcustom ejump-project-denoters
  '(".ejump" ".projectile" ".git" ".hg" ".fslckout" ".bzr" "_darcs" ".svn" "Makefile" "PkgInfo" "-pkg.el")
  "Files and directories that signify a directory is a project root."
  :group 'ejump
  :type '(repeat (string  :tag "Name")))

(defcustom ejump-default-project "~"
  "The default project to search within if a project root is not found."
  :group 'ejump
  :type 'string)

(defcustom ejump-project nil
  "The project to search within if normal denoters will not work.  This should only be needed in the rarest of cases."
  :group 'ejump
  :type 'string)

(defcustom ejump-before-jump-hook nil
  "Hooks called before jumping."
  :type 'hook
  :group 'ejump
  :type 'hook)

(defcustom ejump-after-jump-hook nil
  "Hooks called after jumping."
  :type 'hook
  :group 'ejump
  :type 'hook)

(defcustom ejump-aggressive
  nil
  "If `t` jump aggressively with the possibility of a false positive.
If `nil` always show list of more than 1 match."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-debug
  nil
  "If `t` will print helpful debug information."
  :group 'ejump
  :type 'boolean)

(defcustom ejump-confirm-jump-to-modified-file
  t
  "If t, confirm before jumping to a modified file (which may lead to an
inaccurate jump).  If nil, jump without confirmation but print a warning."
  :group 'ejump
  :type 'boolean)

(defun ejump-message-prin1 (str &rest args)
  "Helper function when debugging apply STR 'prin1-to-string' to all ARGS."
  (apply 'message str (-map 'prin1-to-string args)))

(defvar ejump--ag-installed? 'unset)
(defun ejump-ag-installed? ()
  "Return t if ag is installed."
  (if (eq ejump--ag-installed? 'unset)
      (setq ejump--ag-installed?
            (s-contains? "ag version" (shell-command-to-string (concat ejump-ag-cmd " --version"))))
    ejump--ag-installed?))

(defvar ejump--git-grep-plus-ag-installed? 'unset)
(defun ejump-git-grep-plus-ag-installed? ()
  "Return t if git grep and ag is installed."
  (if (eq ejump--git-grep-plus-ag-installed? 'unset)
      (setq ejump--git-grep-plus-ag-installed?
            (and (ejump-git-grep-installed?) (ejump-ag-installed?)))
    ejump--git-grep-plus-ag-installed?))

(defvar ejump--rg-installed? 'unset)
(defun ejump-rg-installed? ()
  "Return t if rg is installed."
  (if (eq ejump--rg-installed? 'unset)
      (setq ejump--rg-installed?
            (let ((result (s-match "ripgrep \\([0-9]+\\)\\.\\([0-9]+\\).*"
                                   (shell-command-to-string (concat ejump-rg-cmd " --version")))))
              (when (equal (length result) 3)
                (let ((major (string-to-number (nth 1 result)))
                      (minor (string-to-number (nth 2 result))))
                  (or
                   (and (= major 0) (>= minor 10))
                   (>= major 1))))))
    ejump--rg-installed?))

(defvar ejump--git-grep-installed? 'unset)
(defun ejump-git-grep-installed? ()
  "Return t if git-grep is installed."
  (if (eq ejump--git-grep-installed? 'unset)
      (setq ejump--git-grep-installed?
            (s-contains? "fatal: no pattern given"
                         (shell-command-to-string (concat ejump-git-grep-cmd))))
    ejump--git-grep-installed?))

(defvar ejump--grep-installed? 'unset)
(defun ejump-grep-installed? ()
  "Return 'gnu if GNU grep is installed, 'bsd if BSD grep is installed, and nil otherwise."
  (if (eq ejump--grep-installed? 'unset)
      (let* ((version (shell-command-to-string (concat ejump-grep-cmd " --version")))
             (variant (cond ((s-match "GNU grep" version) 'gnu)
                            ((s-match "[0-9]+\\.[0-9]+" version) 'bsd)
                            (t nil))))
        (setq ejump--grep-installed? variant))
    ejump--grep-installed?))

(defun ejump-run-test (test cmd)
  "Use TEST as the standard input for the CMD."
  (with-temp-buffer
    (insert test)
    (shell-command-on-region (point-min) (point-max) cmd nil t)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ejump-run-test-temp-file (test thefile realcmd)
  "Write content to the temporary file, run cmd on it, return result"
  (with-temp-buffer
    (insert test)
    (write-file thefile nil)
    (delete-region (point-min) (point-max))
    (shell-command realcmd t)
    (delete-file thefile)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun ejump-run-git-grep-test (test cmd)
  "Use string TEST as input through a local, temporary file for CMD.
Because git grep must be given a file as input, not just a string."
  (let ((thefile ".git.grep.test"))
    (ejump-run-test-temp-file test thefile (concat cmd " " thefile))))

(defun ejump-run-ag-test (test cmd)
  "Use TEST as input, but first write it into temporary file
and then run ag on it. The difference is that ag ignores multiline
matches when passed input from stdin, which is a crucial feature."
  (let ((thefile ".ag.test"))
    (ejump-run-test-temp-file test thefile (concat cmd " " thefile))))

(defun ejump-test-grep-rules (&optional run-not-tests)
  "Test all the grep rules and return count of those that fail.
Optionally pass t for RUN-NOT-TESTS to see a list of all failed rules."
  (let ((fail-tmpl "grep FAILURE '%s' %s in response '%s' | CMD: '%s' | rule: '%s'")
        (variant (if (eq (ejump-grep-installed?) 'gnu) 'gnu-grep 'grep)))
    (-mapcat
     (lambda (rule)
       (-mapcat
        (lambda (test)
          (let* ((cmd (concat "grep -En -e "
                              (shell-quote-argument (ejump-populate-regexp (plist-get rule :regexp) "test" variant))))
                 (resp (ejump-run-test test cmd)))
            (when (or
                   (and (not run-not-tests) (not (s-contains? test resp)))
                   (and run-not-tests (> (length resp) 0)))
              (list (format fail-tmpl (if run-not-tests "not" "")
                            test (if run-not-tests "IS unexpectedly" "NOT") resp cmd (plist-get rule :regexp))))))
        (plist-get rule (if run-not-tests :not :tests))))
     (--filter (member "grep" (plist-get it :supports)) ejump-find-rules))))

(defun ejump-test-ag-rules (&optional run-not-tests)
  "Test all the ag rules and return count of those that fail.
Optionally pass t for RUN-NOT-TESTS to see a list of all failed rules"
  (let ((fail-tmpl "ag FAILURE '%s' %s in response '%s' | CMD: '%s' | rule: '%s'"))
    (-mapcat
     (lambda (rule)
       (-mapcat
        (lambda (test)
          (let* ((cmd (concat "ag --nocolor --nogroup --nonumber "
                              (shell-quote-argument (ejump-populate-regexp (plist-get rule :regexp) "test" 'ag))))
                 (resp (ejump-run-ag-test test cmd)))
            (when (or
                   (and (not run-not-tests) (not (s-contains? test resp)))
                   (and run-not-tests (> (length resp) 0)))
              (list (format fail-tmpl test (if run-not-tests "IS unexpectedly" "NOT") resp cmd rule)))))
        (plist-get rule (if run-not-tests :not :tests))))
     (--filter (member "ag" (plist-get it :supports)) ejump-find-rules))))

(defun ejump-test-rg-rules (&optional run-not-tests)
  "Test all the rg rules and return count of those that fail.
Optionally pass t for RUN-NOT-TESTS to see a list of all failed rules"
  (let ((fail-tmpl "rg FAILURE '%s' %s in response '%s' | CMD: '%s' | rule: '%s'"))
    (-mapcat
     (lambda (rule)
       (-mapcat
        (lambda (test)
          (let* ((cmd (concat "rg --color never --no-heading -U --pcre2 "
                              (shell-quote-argument (ejump-populate-regexp (plist-get rule :regexp) "test" 'rg))))
                 (resp (ejump-run-test test cmd)))
            (when (or
                   (and (not run-not-tests) (not (s-contains? test resp)))
                   (and run-not-tests (> (length resp) 0)))
              (list (format fail-tmpl test (if run-not-tests "IS unexpectedly" "NOT") resp cmd rule)))))
        (plist-get rule (if run-not-tests :not :tests))))
     (--filter (member "rg" (plist-get it :supports)) ejump-find-rules))))

(defun ejump-test-git-grep-rules (&optional run-not-tests)
  "Test all the git grep rules and return count of those that fail.
Optionally pass t for RUN-NOT-TESTS to see a list of all failed rules"
  (let ((fail-tmpl "rg FAILURE '%s' %s in response '%s' | CMD: '%s' | rule: '%s'"))
    (-mapcat
     (lambda (rule)
       (-mapcat
        (lambda (test)
          (let* ((cmd (concat "git grep --color=never -h --untracked -E  "
                              (shell-quote-argument (ejump-populate-regexp (plist-get rule :regexp) "test" 'git-grep))))
                 (resp (ejump-run-git-grep-test test cmd)))
            (when (or
                   (and (not run-not-tests) (not (s-contains? test resp)))
                   (and run-not-tests (> (length resp) 0)))
              (list (format fail-tmpl test (if run-not-tests "IS unexpectedly" "NOT") resp cmd rule)))))
        (plist-get rule (if run-not-tests :not :tests))))
     (--filter (member "grep" (plist-get it :supports)) ejump-find-rules))))

(defun ejump-message (str &rest args)
  "Log message STR with ARGS to the *Messages* buffer if not using ejump-quiet."
  (when (not ejump-quiet)
    (apply 'message str args))
  nil)

(defmacro ejump-debug-message (&rest exprs)
  "Generate a debug message to print all expressions EXPRS."
  (declare (indent defun))
  (let ((i 5) frames frame)
    ;; based on https://emacs.stackexchange.com/a/2312
    (while (setq frame (backtrace-frame i))
      (push frame frames)
      (cl-incf i))
    ;; this is a macro-expanded version of the code in the stackexchange
    ;; code from above. This version should work on emacs-24.3, since it
    ;; doesn't depend on thread-last.
    (let* ((frame (cl-find-if
                   (lambda (frame)
                     (ignore-errors
                       (and (car frame)
                            (eq (caaddr frame)
                                'defalias))))
                   (reverse frames)))
           (func (cl-cadadr (cl-caddr frame)))
           (defun-name (symbol-name func)))
      (with-temp-buffer
        (insert "EJUMP DEBUG `")
        (insert defun-name)
        (insert "` START\n----\n\n")
        (dolist (expr exprs)
          (insert (prin1-to-string expr) ":\n\t%s\n\n"))
        (insert "\n-----\nEJUMP DEBUG `")
        (insert defun-name)
        (insert "` END\n-----")
        `(when ejump-debug
           (ejump-message
            ,(buffer-string)
            ,@exprs))))))

(defun ejump-to-selected (results choices selected)
  "With RESULTS use CHOICES to find the SELECTED choice from multiple options."
  (let* ((result-index (--find-index (string= selected it) choices))
         (result (when result-index
                   (nth result-index results))))
    (when result
      (ejump-result-follow result))))

(defun ejump-helm-persist-action (candidate)
  "Previews CANDIDATE in a temporary buffer displaying the file at the matched line.
\\<helm-map>
This is the persistent action (\\[helm-execute-persistent-action]) for helm."
  (let* ((file (plist-get candidate :path))
         (line (plist-get candidate :line))
         (default-directory-old default-directory))
    (switch-to-buffer (get-buffer-create " *helm ejump persistent*"))
    (setq default-directory default-directory-old)
    (fundamental-mode)
    (erase-buffer)
    (insert-file-contents file)
    (let ((buffer-file-name file))
      (set-auto-mode)
      (font-lock-fontify-region (point-min) (point-max))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun ejump--format-result (proj result)
  (format "%s:%s: %s"
          (s-replace proj "" (plist-get result :path))
          (plist-get result :line)
          (s-trim (plist-get result :context))))

(defun ejump-ivy-jump-to-selected (results choices _proj)
  "Offer CHOICES as candidates through `ivy-read', then execute
`ejump-result-follow' on the selected choice.  Ignore _PROJ."
  (ivy-read "Jump to: " (-zip choices results)
            :action (lambda (cand)
                      (ejump-result-follow (cdr cand)))
            :caller 'ejump-ivy-jump-to-selected))

(defun ejump-prompt-user-for-choice (proj results)
  "Put a PROJ's list of RESULTS in a 'popup-menu' (or helm/ivy)
for user to select.  Filters PROJ path from files for display."
  (let ((choices (--map (ejump--format-result proj it) results)))
    (cond
     ((eq ejump-selector 'completing-read)
      (ejump-to-selected results choices (completing-read "Jump to: " choices)))
     ((and (eq ejump-selector 'ivy) (fboundp 'ivy-read))
      (funcall ejump-ivy-jump-to-selected-function results choices proj))
     ((and (eq ejump-selector 'helm) (fboundp 'helm))
      (helm :sources
            (helm-build-sync-source "Jump to: "
                                    :action '(("Jump to match" . ejump-result-follow))
                                    :candidates (-zip choices results)
                                    :persistent-action 'ejump-helm-persist-action)
            :buffer "*helm ejump choices*"))
     (t
      (ejump-to-selected results choices (popup-menu* choices))))))

(defun ejump-get-project-root (filepath)
  "Keep looking at the parent dir of FILEPATH until a denoter file/dir is found."
  (s-chop-suffix
   "/"
   (expand-file-name
    (or
     ejump-project
     (locate-dominating-file filepath #'ejump-get-config)
     ejump-default-project))))

(defun ejump-get-config (dir)
  "If a project denoter is in DIR then return it, otherwise
nil. However, if DIR contains a `.ejumpignore' it returns nil
to keep looking for another root."
  (if (file-exists-p (expand-file-name ".ejumpignore" dir))
      nil
    (car (--filter
          (file-exists-p (expand-file-name it dir))
          ejump-project-denoters))))

(defun ejump-issue-result (issue)
  "Return a result property list with the ISSUE set as :issue property symbol."
  `(:results nil
    :symbol nil
    :ctx-type nil
    :file nil
    :root nil
    :issue ,(intern issue)))

(defun ejump-xref-backend-search-and-get-results (prompt situation)
  "Find definitions, return a list of xref objects."
  (let* ((info (ejump-get-results prompt situation))
           (results (plist-get info :results))
           (look-for (or prompt (plist-get info :symbol)))
           (proj-root (plist-get info :root))
           (issue (plist-get info :issue))
           (processed (ejump-process-results
                       results
                       (plist-get info :file)
                       proj-root
                       (plist-get info :ctx-type)
                       look-for
                       nil
                       nil))
           (results (plist-get processed :results))
           (do-var-jump (plist-get processed :do-var-jump))
           (var-to-jump (plist-get processed :var-to-jump))
           (match-cur-file-front (plist-get processed :match-cur-file-front)))

      (ejump-debug-message
       look-for
       (plist-get info :ctx-type)
       var-to-jump
       (pp-to-string match-cur-file-front)
       (pp-to-string results)
       match-cur-file-front
       proj-root
       (plist-get info :file))
      (cond ((eq issue 'nogrep)
             (ejump-message "Please install ag, rg, git grep or grep!"))
            ((eq issue 'nosymbol)
             (ejump-message "No symbol under point."))
            ((= (length results) 0)
             (ejump-message "'%s' %s declaration not found." look-for
                            (plist-get info :ctx-type)))
            (t (mapcar (lambda (res)
                         (xref-make
                          (plist-get res :context)
                          (xref-make-file-location
                           (expand-file-name (plist-get res :path))
                           (plist-get res :line)
                           0)))
                       (if do-var-jump
                           (list var-to-jump)
                         match-cur-file-front))))))

(defun ejump-get-results (prompt situation)
  "Run ejump-fetch-results if searcher installed, buffer is saved, and there's a symbol under point."
  (cond
   ((not (or (ejump-ag-installed?)
             (ejump-rg-installed?)
             (ejump-git-grep-installed?)
             (ejump-grep-installed?)))
    (ejump-issue-result "nogrep"))
   ;; TODO: jumping from the *erlang* inferior shell?
   ;; Something along this from dumb-jump:
   ;;   ((or (string= (buffer-name) "*shell*")
   ;;        (string= (buffer-name) "*eshell*"))
   ;;    (ejump-fetch-shell-results prompt))
   ((and (not prompt) (not (region-active-p)) (not (thing-at-point 'symbol)))
    (ejump-issue-result "nosymbol"))
   (t
    (ejump-fetch-file-results prompt situation))))

(defun ejump-fetch-file-results (prompt situation)
  (let* ((cur-file (or (buffer-file-name) ""))
         (otp-src-dir (ejump-locate-otp-src-dir-cachingly))
         (proj-root (if (ejump-is-in-otp-src-dir cur-file)
                        otp-src-dir
                      (ejump-get-project-root cur-file)))
         (proj-config (ejump-get-config proj-root))
         (config (when (s-ends-with? ".ejump" proj-config)
                   (ejump-read-config proj-root proj-config))))
    (ejump-fetch-results cur-file proj-root config prompt situation)))

(defun ejump-fetch-results (cur-file proj-root _config prompt situation)
  "Return a list of results based on current file context and calling grep/ag.
CUR-FILE is the path of the current buffer.
PROJ-ROOT is that file's root project directory.
of project configuration."
  (cond ((eq situation 'find-defs)
         (ejump-fetch-defs-results cur-file proj-root prompt))
        ((eq situation 'find-refs)
         (ejump-fetch-refs-results cur-file proj-root prompt))))

(defun ejump-fetch-defs-results (cur-file proj-root prompt)
  "Return a list of results based on current file context and calling grep/ag.
CUR-FILE is the path of the current buffer.
PROJ-ROOT is that file's root project directory.
of project configuration."
  (let* ((identifier (get-text-property 0 :ejump-id-at-point prompt))
         (id-kind    (erlang-id-kind identifier))
         (id-mod     (erlang-id-module identifier))
         (id-name    (erlang-id-name identifier))
         (buf        (get-text-property 0 :ejump-buf prompt))
         (buf-mod    (if (buffer-file-name buf)
                         (erlang-get-module-from-file-name
                          (buffer-file-name buf))))
         (cur-line-num (line-number-at-pos))
         (proj-config (ejump-get-config proj-root))
         (config (when (s-ends-with? ".ejump" proj-config)
                   (ejump-read-config proj-root proj-config)))

         (regexps (ejump-unpopulated-regexps-for-defs-from-id-at-pt prompt))
         (file-patterns (ejump-file-patterns-for-defs-from-id-at-pt prompt))

         (exclude-paths (-distinct
                         (append (when config (plist-get config :exclude))
                                 '("_build" ".rebar"))))
         (include-paths (when config (plist-get config :include)))
                                        ; we will search proj root
                                        ; and all include paths
         (otp-src-dir (ejump-locate-otp-src-dir-cachingly))
         (erl-libs (ejump-erl-libs))
         (search-path-current-buffer (cond ((eq id-kind 'qualified-function)
                                            (if (or (null buf-mod)
                                                    (string= id-mod buf-mod))
                                                '(<current-buffer>)
                                              ;; Call to other module:
                                              nil))
                                           (t
                                            '(<current-buffer>))))
         (search-paths (append search-path-current-buffer
                               (list proj-root)
                               include-paths
                               (if otp-src-dir (list otp-src-dir))
                               erl-libs))
         (raw-results
          (cond
           ((or (eq id-kind 'macro) (eq id-kind 'record))
            (ejump-search-paths id-name search-paths regexps
                                file-patterns exclude-paths
                                cur-file cur-line-num))
           (t
            (ejump-search-paths id-name search-paths regexps
                                file-patterns exclude-paths
                                cur-file cur-line-num))))

         (results (delete-dups (--map (plist-put it :target id-name)
                                      raw-results))))

    `(:results ,results
               :symbol ,id-name
               :ctx-type nil ; FIXME: needed?
               :file ,cur-file
               :root ,proj-root)))

(defun ejump-search-paths (look-for search-paths regexps
                                    file-patterns exclude-paths
                                    cur-file cur-line-num)
  "Search for LOOK-FOR in SEARCH-PATHS-LIST.
Populate REGEXPS with LOOK-FOR.
Look in SEARCH-PATHS which is a list containing element of either of these:
  - '<current-buffer>
  - a plist (:search-path '<current-buffer>
             :regexps OVERRIDING-REGEXPS
             [:do-next 'do-elem | 'stop-if-results (default) | 'stop] (opt)
            )
  - a DIR element (a string).
Consider files matching FILE-PATTERNS, exclude EXCLUDE-PATHS
Do not include matches in CUR-FILE for CUR-LINE-NUM."
  (let ((paths-searched)
        (results)
        (do-elem t)
        (stop nil))
    (mapc
     (lambda (elem)
       (let ((search-path)
             (do-next 'stop-if-results)
             (elem-regexps regexps))
         (cond ((stringp elem)
                (setq search-path elem))
               ((equal elem '<current-buffer>)
                (setq search-path elem))
               ((list elem)
                (setq search-path (plist-get elem :search-path))
                (setq elem-regexps (plist-get elem :regexps))
                (setq do-next (or (plist-get elem :do-next) do-next))))
         (when (and do-elem (not stop))
           (cond
            ((equal search-path '<current-buffer>)
             (setq results (ejump-search-buffer look-for elem-regexps
                                                cur-line-num)))
            ((not (ejump-is-subdir-of-any search-path paths-searched))
             (setq results
                   (ejump-search-file-system look-for search-path elem-regexps
                                             file-patterns exclude-paths
                                             cur-file cur-line-num))
             (setq paths-searched (cons search-path paths-searched)))))
         (cond ((equal do-next 'stop-if-results)
                (setq do-elem (null results)))
               ((equal do-next 'stop)
                (setq stop t))
               ((equal do-next 'do-elem)
                (setq do-elem t)))))
     search-paths)
    results))

(defun ejump-true-is-subdir-of (dir possibly-containing-dir)
  "Test if DIR is in POSSIBLY-CONTAINING-DIR.
Assume both dirs are results from (file-truename X)."
  ;; DIR, "/tmp/a/b/c", is a subdir of POSSIBLY-CONTAINING-DIR, "/tmp",
  ;; if POSSIBLY-CONTAINING-DIR is a prefix of DIR
  (s-prefix? possibly-containing-dir dir))

(defun ejump-is-subdir-of-any (dir dirs)
  (let ((true-dir (file-truename dir)))
    (--any (ejump-true-is-subdir-of true-dir (file-truename it)) dirs)))

(defun ejump-unpopulated-regexps-for-defs-from-id-at-pt (id-at-pt)
  (let* ((identifier  (get-text-property 0 :ejump-id-at-point id-at-pt))
         (buf         (get-text-property 0 :ejump-buf id-at-pt))
         (buf-filename-as-atom (ejump-quote-atom-if-needed
                                (erlang-get-module-from-file-name
                                 (buffer-file-name buf)))))
    ;; JJJ -> look-for
    ;; \s -> space
    ;; \j boundary
    ;; \b boundary too? (in grep and in elisp regexps)
    (erlang-with-id (kind module name arity) (erlang-get-identifier-at-point)
      (cond (; local function or type:
             (or (eq kind 'qualified-function)
                 (and (eq kind nil) arity))
             '("^JJJ\\s*\\\("
               "^-type\\s+JJJ\\s*\\\("))
            (; an atom maybe:
             (and (null kind) (null arity))
             ;; check for '{name' as in gen-server call request terms?
             '("^.+\\bJJJ\\b"))
            ((eq kind 'record)
             '("-record(JJJ"))
            ((eq kind 'macro)
             '("^-define\\s*\\\(JJJ"))
            (t
             '("\\bJJJ\\b"))))))

(defun ejump-file-patterns-for-defs-from-id-at-pt (id-at-pt)
  ;; Return value seems to be a regexp for ag, but a glob for rg or git-grep
  ;; or nil for the grep-tool's notion of erlang files. (Hmm...)
  (let* ((identifier (get-text-property 0 :ejump-id-at-point id-at-pt))
         (_buf       (get-text-property 0 :ejump-buf id-at-pt)))
    (erlang-with-id (kind module name) (erlang-get-identifier-at-point)
      (cond ((or (eq kind 'qualified-function)  ; eg xyz:fn_abc(...)
                 (eq kind 'module))             ; eg just xyz:
             (list (concat module ".erl")
                   (concat module ".yrl")
                   (concat module ".xrl")))
            (t
             nil)))))

(defun ejump-quote-atom-if-needed (s)
  (erlang-add-quotes-if-needed s))

(defun ejump-ensure-uquoted-atom (s)
  (erlang-remove-quotes s))

(defun ejump-git-dir (d)
  (let* ((git-dir-cmd (format "git -C \"%s\" rev-parse --absolute-git-dir" d))
         (output (s-chop-suffix "\n" (shell-command-to-string git-dir-cmd))))
    (if (not (s-contains? "fatal: not a git repository" output))
        output)))

(defun ejump-fetch-refs-results (cur-file proj-root prompt)
  "Return a list of results based on current file context and calling grep/ag.
CUR-FILE is the path of the current buffer.
PROJ-ROOT is that file's root project directory.
of project configuration."
  (let* ((identifier (get-text-property 0 :ejump-id-at-point prompt))
         (buf        (get-text-property 0 :ejump-buf prompt))
         (look-for   (erlang-id-name identifier))
         (cur-line-num (line-number-at-pos))
         (proj-config (ejump-get-config proj-root))
         (config (when (s-ends-with? ".ejump" proj-config)
                   (ejump-read-config proj-root proj-config)))
         (is-exported (ejump-is-identifier-exported-function-p identifier))
         (is-remote (erlang-with-id (kind) identifier
                      (equal kind 'qualified-function)))
         ;; Example:
         ;; * search references for, ie calls to, a()
         ;;   - search for mod:a() in **/*.erl
         ;;     search for a() in mod.erl
         ;;   - but if the function is not exported, search for a() in buf only

         (l-regexps (ejump-unpopulated-local-regexps-for-refs-from-id-at-pt
                     prompt))
         (r-regexps (ejump-unpopulated-remote-regexps-for-refs-from-id-at-pt
                     prompt))
         (file-patterns (ejump-file-patterns-for-refs-from-id-at-pt prompt))

         (exclude-paths (-distinct
                         (append (when config (plist-get config :exclude))
                                 '("_build" ".rebar"))))
         (include-paths (when config (plist-get config :include)))
                                        ; we will search proj root
                                        ; and all include paths
         (otp-src-dir (ejump-locate-otp-src-dir-cachingly))
         (erl-libs (ejump-erl-libs))
         (search-buffer (list :search-path '<current-buffer>
                              :regexps (cond
                                        (is-remote r-regexps)
                                        ((not is-exported) l-regexps)
                                        (t (append l-regexps r-regexps)))
                              :do-next (if (not is-exported) 'stop
                                         'do-elem)))
         (search-paths (append (list search-buffer)
                               (list proj-root) ;; fixme. r-regexps
                               include-paths
                               erl-libs))
         (raw-results
          (erlang-with-id (kind module name) identifier
            (ejump-search-paths name search-paths r-regexps
                                file-patterns exclude-paths
                                cur-file cur-line-num)))

         (results (delete-dups (--map (plist-put it :target look-for)
                                      raw-results))))

    `(:results ,results
               :symbol ,look-for
               :ctx-type nil ; FIXME: needed?
               :file ,cur-file
               :root ,proj-root)))

(defun ejump-is-identifier-exported-function-p (identifier)
  (erlang-with-id (kind module name arity) identifier
    (cond ((and (null kind) arity)
           (erlang-function-exported-p name arity))
          (t
           (equal 'kind 'qualified-function)))))

(defun ejump-unpopulated-remote-regexps-for-refs-from-id-at-pt (id-at-pt)
  (let* ((identifier  (get-text-property 0 :ejump-id-at-point id-at-pt))
         (buf         (get-text-property 0 :ejump-buf id-at-pt))
         (buf-filename-as-atom (ejump-quote-atom-if-needed
                                (erlang-get-module-from-file-name
                                 (buffer-file-name buf)))))
    ;;
    ;; Example of a file x.erl, when point is on the function name:
    ;;
    ;;                                 kind  module     name         arity
    ;; -------------------------------------------------------------------
    ;; -spec some_fn(_, _) -> _.   ;   nil   x          some_fn      2
    ;; some_fn(A, B) ->            ;   nil   x          some_fn      2
    ;;     local_fn(),             ;   nil   x          local_fn     0
    ;;     x:exported_fn()         ;   qf*   x          exported_fn  0
    ;;     other_mod:remote_fn().  ;   qf*   other_mod  remote_fn    0
    ;;
    ;; qf* == 'qualified-function

    ;; JJJ -> look-for
    ;; \s -> space
    ;; \j boundary
    ;; \b boundary too? (in grep and in elisp regexps)
    (erlang-with-id (kind module name arity) identifier
      (cond
       ((and (null kind) arity)
        (--map
         (s-replace "MMM" buf-filename-as-atom it)
         '("\\bMMM\\s*:\\s*JJJ\\s*\\\("
           "fun\\s+MMM\\s*:\\s*JJJ\\s*/")))

       ((eq kind 'qualified-function)
        (--map
         (s-replace "MMM" module it)
         '("\\bMMM\\s*:\\s*JJJ\\s*\\\("
           "fun\\s+MMM\\s*:\\s*JJJ\\s*/")))

       ((eq kind 'macro)
        '("\\\?JJJ\\b"))

       (t
        '("\\bJJJ\\b"))))))

(defun ejump-unpopulated-local-regexps-for-refs-from-id-at-pt (id-at-pt)
  (let* ((identifier  (get-text-property 0 :ejump-id-at-point id-at-pt)))
     (erlang-with-id (kind module name arity) identifier
       (cond (; local function or type:
              (or (eq kind 'qualified-function)
                  (and (eq kind nil) arity))
              '("\\bJJJ\\s*\\\("
                "fun\\s+JJJ\\s*/"))
             ((eq kind 'macro)
              '("\\\?JJJ\\b"))
             (t
              '("\\bJJJ\\b"))))))

(defun ejump-file-patterns-for-refs-from-id-at-pt (_id-at-pt)
  nil)

;;;###autoload
(defun ejump-back ()
  "Jump back to where the last jump was done."
  (interactive)
  (with-demoted-errors "Error running `ejump-before-jump-hook': %S"
    (run-hooks 'ejump-before-jump-hook))
  (pop-tag-mark)
  (with-demoted-errors "Error running `ejump-after-jump-hook': %S"
    (run-hooks 'ejump-after-jump-hook)))

;;;###autoload
(defun ejump-quick-look ()
  "Run ejump-go in quick look mode.
That is, show a tooltip of where it would jump instead."
  (interactive)
  (ejump-go t))

;;;###autoload
(defun ejump-go-other-window ()
  "Like 'ejump-go' but use 'find-file-other-window' instead of 'find-file'."
  (interactive)
  (let ((ejump-window 'other))
    (ejump-go)))

;;;###autoload
(defun ejump-go-current-window ()
  "Like ejump-go but always use 'find-file'."
  (interactive)
  (let ((ejump-window 'current))
    (ejump-go)))

;;;###autoload
(defun ejump-go-prefer-external ()
  "Like ejump-go but prefer external matches from the current file."
  (interactive)
  (ejump-go nil t))

;;;###autoload
(defun ejump-go-prompt ()
  "Like ejump-go but prompts for function instead of using under point"
  (interactive)
  (ejump-go nil nil (read-from-minibuffer "Jump to: ")))

;;;###autoload
(defun ejump-go-prefer-external-other-window ()
  "Like ejump-go-prefer-external but use 'find-file-other-window' instead
of 'find-file'."
  (interactive)
  (let ((ejump-window 'other))
    (ejump-go-prefer-external)))

;;;###autoload
(defun ejump-go (&optional use-tooltip prefer-external prompt)
  "Go to the function/variable declaration for thing at point.
When USE-TOOLTIP is t a tooltip jump preview will show instead.
When PREFER-EXTERNAL is t it will sort external matches before
current file."
  (interactive "P")
  (let* ((start-time (float-time))
         (info (ejump-get-results prompt))
         (end-time (float-time))
         (fetch-time (- end-time start-time))
         (results (plist-get info :results))
         (look-for (or prompt (plist-get info :symbol)))
         (proj-root (plist-get info :root))
         (issue (plist-get info :issue))
         (result-count (length results)))
    (when (> fetch-time ejump-max-find-time)
      (ejump-message
       (concat "Took over %ss to find '%s'. "
               "Please install ag or rg, or add a .ejump file "
               "to '%s' with path exclusions")
       (number-to-string ejump-max-find-time) look-for proj-root))
    (cond
     ((eq issue 'nogrep)
      (ejump-message "Please install ag, rg, git grep or grep!"))
     ((eq issue 'nosymbol)
      (ejump-message "No symbol under point."))
     ((= result-count 1)
      (ejump-result-follow (car results) use-tooltip proj-root))
     ((> result-count 1)
      ;; multiple results so let the user pick from a list
      ;; unless the match is in the current file
      (ejump-handle-results results (plist-get info :file) proj-root
                            (plist-get info :ctx-type)
                            look-for use-tooltip prefer-external))
     ((= result-count 0)
      (ejump-message "'%s' %s declaration not found."
                     look-for
                     (plist-get info :ctx-type))))))

(defcustom ejump-erl-cmd
  "erl"
  "The the path to erl.  By default assumes it is in path."
  :group 'ejump
  :type 'string)

(defcustom ejump-erlang-otp-src-dir
  nil
  "Directory for Erlang source files, or nil to attempt to auto-detect it."
  :group 'ejump
  :type '(choice (const :tag "Attempt to auto-detect" nil)
                 (directory :tag "Directory of Erlang/OTP source files")))

(defun ejump-is-in-otp-src-dir (file)
  (let ((otp-src-dir (ejump-locate-otp-src-dir-cachingly)))
    (when otp-src-dir
      (ejump-true-is-subdir-of (file-truename file)
                               (file-truename otp-src-dir)))))

(defvar ejump--cached-otp-src-dir 'unset)
;(setq ejump--cached-otp-src-dir 'unset)
(defun ejump-locate-otp-src-dir-cachingly ()
  "Return a path to the Erlang/OTP sources, or nil, and cache it."
  (if (eq ejump--cached-otp-src-dir 'unset)
      (if ejump-erlang-otp-src-dir
          (setq ejump--cached-otp-src-dir ejump-erlang-otp-src-dir)
        (setq ejump--cached-otp-src-dir (ejump-locate-otp-src-dir)))
    ejump--cached-otp-src-dir))

(defun ejump-locate-otp-src-dir ()
  "Return a path to the Erlang/OTP sources if Erlang is found, or nil.
The path retuned is for instance `/usr/lib/erlang/' and source files are
commonly found in the lib/app-VSN/src/ subdirectories of this dir."
  (if (ejump-erl-installed?)
      (let* ((erl-expr "io:put_chars(code:root_dir()), halt(0).")
             (cmd (concat ejump-erl-cmd
                          " -noinput +B -boot start_clean"
                          " -eval '" erl-expr "'"))
             (root-dir (ejump-shell-cmd-to-string-exec-path cmd)))
        (if (file-directory-p root-dir)
            ;; Suffix with /lib ??
            root-dir))))

(defvar ejump--erl-installed? 'unset)
;(setq ejump--erl-installed? 'unset)
(defun ejump-erl-installed? ()
  "Return t or nil depending on if the `ejump-erl-cmd' is found.
Use the value of `exec-path' to find erl"
  (if (eq ejump--erl-installed? 'unset)
      (let* ((cmd (format "%s +V" ejump-erl-cmd)))
        (if (s-contains? "Erlang" (ejump-shell-cmd-to-string-exec-path cmd))
            (setq ejump--erl-installed? t)
          (setq ejump--erl-installed? nil)))
    ejump--erl-installed?))

(defun ejump-shell-cmd-to-string-exec-path (cmd)
  (let ((sh-path (s-join ":" (-map (lambda (p)
                                     (shell-quote-argument
                                      (directory-file-name p)))
                                   exec-path))))
    (shell-command-to-string (format "export PATH=\"%s\"; %s" sh-path cmd))))

(defvar ejump--erl-libs 'unset)
(defun ejump-erl-libs ()
  "The ERL_LIBS environment variable as a list of directories, if set."
  (if (eq ejump--erl-libs 'unset)
      (let ((erl-libs (getenv "ERL_LIBS")))
        (setq ejump--erl-libs
              (if erl-libs
                  (-distinct
                   (--filter (file-directory-p it)
                             (s-split ":" erl-libs t)))
                '())))
    ejump--erl-libs))

(defun ejump-filter-no-start-comments (results lang)
  "Filter out RESULTS with a :context that starts with a comment
given the LANG of the current file."
  (let ((comment "%"))
    (-concat
     (--filter (not (s-starts-with? comment (s-trim (plist-get it :context))))
               results))))

(defun ejump-handle-results
    (results cur-file proj-root ctx-type look-for use-tooltip prefer-external)
  "Handle the searchers results.
RESULTS is a list of property lists with the searcher's results.
CUR-FILE is the current file within PROJ-ROOT.
CTX-TYPE is a string of the current context.
LOOK-FOR is the symbol we're jumping for.
USE-TOOLTIP shows a preview instead of jumping.
PREFER-EXTERNAL will sort current file last."
  (let* ((processed (ejump-process-results results cur-file proj-root ctx-type look-for use-tooltip prefer-external))
         (results (plist-get processed :results))
         (do-var-jump (plist-get processed :do-var-jump))
         (var-to-jump (plist-get processed :var-to-jump))
         (match-cur-file-front (plist-get processed :match-cur-file-front)))
    (ejump-debug-message
     look-for
     ctx-type
     var-to-jump
     (pp-to-string match-cur-file-front)
     (pp-to-string results)
     prefer-external
     proj-root
     cur-file)
    (cond
     (use-tooltip ;; quick-look mode
      (popup-menu* (--map (ejump--format-result proj-root it) results)))
     (do-var-jump
      (ejump-result-follow var-to-jump use-tooltip proj-root))
     (t
      (ejump-prompt-user-for-choice proj-root match-cur-file-front)))))

(defun ejump-process-results
    (results cur-file proj-root ctx-type _look-for _use-tooltip prefer-external)
  "Process (filter, sort, ...) the searchers results.
RESULTS is a list of property lists with the searcher's results.
CUR-FILE is the current file within PROJ-ROOT.
CTX-TYPE is a string of the current context.
LOOK-FOR is the symbol we're jumping for.
USE-TOOLTIP shows a preview instead of jumping.
PREFER-EXTERNAL will sort current file last."
  "Figure which of the RESULTS to jump to. Favoring the CUR-FILE"
  (let* ((lang "erlang")
         (match-sorted (-sort (lambda (x y) (< (plist-get x :diff) (plist-get y :diff))) results))
         (match-no-comments (ejump-filter-no-start-comments match-sorted lang))

         ;; Find the relative current file path by the project root. In some cases the results will
         ;; not be absolute but relative and the "current file" filters must match in both
         ;; cases. Also works when current file is in an arbitrary sub folder.
         (rel-cur-file
          (cond ((and (s-starts-with? proj-root cur-file)
                      (s-starts-with? default-directory cur-file))
                 (substring cur-file (length default-directory) (length cur-file)))

                ((and (s-starts-with? proj-root cur-file)
                      (not (s-starts-with? default-directory cur-file)))
                 (substring cur-file (1+ (length proj-root)) (length cur-file)))

                (t
                 cur-file)))

         ;; Moves current file results to the front of the list, unless PREFER-EXTERNAL then put
         ;; them last.
         (match-cur-file-front
          (if (not prefer-external)
              (-concat
               (--filter (and (> (plist-get it :diff) 0)
                              (or (string= (plist-get it :path) cur-file)
                                  (string= (plist-get it :path) rel-cur-file)))
                         match-no-comments)
               (--filter (and (<= (plist-get it :diff) 0)
                              (or (string= (plist-get it :path) cur-file)
                                  (string= (plist-get it :path) rel-cur-file)))
                         match-no-comments)

               ;; Sort non-current files by path length so the nearest file is more likely to be
               ;; sorted higher to the top. Also sorts by line number for sanity.
               (-sort (lambda (x y)
                        (and (< (plist-get x :line) (plist-get y :line))
                             (< (length (plist-get x :path)) (length (plist-get y :path)))))
                      (--filter (not (or (string= (plist-get it :path) cur-file)
                                         (string= (plist-get it :path) rel-cur-file)))
                                match-no-comments)))
            (-concat
             (-sort (lambda (x y)
                      (and (< (plist-get x :line) (plist-get y :line))
                           (< (length (plist-get x :path)) (length (plist-get y :path)))))
                    (--filter (not (or (string= (plist-get it :path) cur-file)
                                       (string= (plist-get it :path) rel-cur-file)))
                              match-no-comments))
             (--filter (or (string= (plist-get it :path) cur-file)
                           (string= (plist-get it :path) rel-cur-file))
                       match-no-comments))))

         (matches
          (if (not prefer-external)
              (-distinct
               (append (ejump-current-file-results cur-file match-cur-file-front)
                       (ejump-current-file-results rel-cur-file match-cur-file-front)))
            match-cur-file-front))

         (var-to-jump (car matches))
         ;; TODO: handle if ctx-type is null but ALL results are variable

         ;; When non-aggressive it should only jump when there is only one match, regardless of
         ;; context.
         (do-var-jump
          (and (or ejump-aggressive
                   (= (length match-cur-file-front) 1))
               (or (= (length matches) 1)
                   (string= ctx-type "variable")
                   (string= ctx-type ""))
               var-to-jump)))

    (list :results results
          :do-var-jump do-var-jump
          :var-to-jump var-to-jump
          :match-cur-file-front match-cur-file-front)))

(defun ejump-read-config (root config-file)
  "Load and return options (exclusions, inclusions, etc).
Ffrom the ROOT project CONFIG-FILE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name config-file root))
    (let ((local-root (if (file-remote-p root)
                          (tramp-file-name-localname
                           (tramp-dissect-file-name root))
                        root))
          include exclude lang)
      (while (not (eobp))
        (cond ((looking-at "^language \\\(.+\\\)")
               (setq lang (match-string 1)))
              ((looking-at "^\\+\\(.+\\)")
               (push (expand-file-name (match-string 1) local-root)
                     include))
              ((looking-at "^-/?\\(.+\\)")
               (push (expand-file-name (match-string 1) local-root)
                     exclude)))
        (forward-line))
      (list :exclude (nreverse exclude)
            :include (nreverse include)
            :language lang))))

(defun ejump-file-modified-p (path)
  "Check if PATH is currently open in Emacs and has a modified buffer."
  (interactive)
  (--any?
   (and (buffer-modified-p it)
        (buffer-file-name it)
        (file-exists-p (buffer-file-name it))
        (file-equal-p (buffer-file-name it) path))
   (buffer-list)))

(defun ejump-result-follow (result &optional use-tooltip proj)
  "Take the RESULT to jump to and record the jump, for jumping back, and then trigger jump.  If ejump-confirm-jump-to-modified-file is t, prompt if we should continue if destination has been modified.  If it is nil, display a warning."
  (if (ejump-file-modified-p (plist-get result :path))
      (let ((target-file (plist-get result :path)))
        (if ejump-confirm-jump-to-modified-file
            (when (y-or-n-p (concat target-file " has been modified so we may have the wrong location. Continue?"))
              (ejump--result-follow result use-tooltip proj))
          (progn (message
                  "Warning: %s has been modified so we may have the wrong location."
                  target-file)
                 (ejump--result-follow result use-tooltip proj))))
    (ejump--result-follow result use-tooltip proj)))

(defun ejump--result-follow (result &optional use-tooltip proj)
  "Take the RESULT to jump to and record the jump, for jumping back, and then trigger jump."
  (let* ((target-boundary (s-matched-positions-all
                           (concat "\\b" (regexp-quote (plist-get result :target)) "\\b")
                           (plist-get result :context)))
         ;; column pos is either via tpos from ag or by using the regexp above or last using old s-index-of
         (pos (if target-boundary
                  (car (car target-boundary))
                (s-index-of (plist-get result :target) (plist-get result :context))))

         (result-path (plist-get result :path))

         ;; Return value is either a string like "/ssh:user@1.2.3.4:" or nil
         (tramp-path-prefix (file-remote-p default-directory))

         ;; If result-path is an absolute path, the prefix is added to the head of it,
         ;; or result-path is added to the end of default-directory
         (path-for-tramp (when (and result-path tramp-path-prefix)
                           (if (file-name-absolute-p result-path)
                               (concat tramp-path-prefix result-path)
                             (concat default-directory result-path))))

         (thef (or path-for-tramp result-path))
         (line (plist-get result :line)))
    (when thef
      (if use-tooltip
          (popup-tip (ejump--format-result proj result))
        (ejump-goto-file-line thef line pos)))
    ;; return the file for test
    thef))


(defun ejump-goto-file-line (thefile theline pos)
  "Open THEFILE and go line THELINE"
  (if (fboundp 'xref-push-marker-stack)
      (xref-push-marker-stack)
    (ring-insert find-tag-marker-ring (point-marker)))

  (with-demoted-errors "Error running `ejump-before-jump-hook': %S"
    (run-hooks 'ejump-before-jump-hook))

  (let* ((visible-buffer (find-buffer-visiting thefile))
         (visible-window (when visible-buffer (get-buffer-window visible-buffer))))
    (cond
     ((and visible-window ejump-use-visible-window)
      (select-window visible-window))
     ((eq ejump-window 'other)
      (find-file-other-window thefile))
     (t (find-file thefile))))

  (goto-char (point-min))
  (forward-line (1- theline))
  (forward-char pos)
  (with-demoted-errors "Error running `ejump-after-jump-hook': %S"
    (run-hooks 'ejump-after-jump-hook)))

(defun ejump-current-file-results (path results)
  "Return the PATH's RESULTS."
  (let ((matched (--filter (string= path (plist-get it :path)) results)))
    matched))

(defun ejump-generators-by-searcher (searcher)
  "For a SEARCHER it yields a response parser, a command
generator function, an installed? function, and the corresponding
searcher symbol."
  (cond ((equal 'git-grep searcher)
         `(:parse ,'ejump-parse-git-grep-response
                  :generate ,'ejump-generate-git-grep-command
                  :installed ,'ejump-git-grep-installed?))
        ((equal 'ag searcher)
         `(:parse ,'ejump-parse-ag-response
                  :generate ,'ejump-generate-ag-command
                  :installed ,'ejump-ag-installed?))
        ((equal 'git-grep-plus-ag searcher)
         `(:parse ,'ejump-parse-ag-response
                  :generate ,'ejump-generate-git-grep-plus-ag-command
                  :installed ,'ejump-git-grep-plus-ag-installed?))
        ((equal 'rg searcher)
         `(:parse ,'ejump-parse-rg-response
                  :generate ,'ejump-generate-rg-command
                  :installed ,'ejump-rg-installed?))
        ((equal 'gnu-grep searcher)
         `(:parse ,'ejump-parse-grep-response
                  :generate ,'ejump-generate-gnu-grep-command
                  :installed ,'ejump-grep-installed?))
        ((equal 'grep searcher)
         `(:parse ,'ejump-parse-grep-response
                  :generate ,'ejump-generate-grep-command
                  :installed ,'ejump-grep-installed?))))

(defun ejump-pick-grep-variant (&optional proj-root)
  (cond
   ;; If `ejump-force-searcher' is not nil then use that searcher.
   (ejump-force-searcher
    (ejump-generators-by-searcher ejump-force-searcher))

   ;; If project root has a .git then use git-grep if installed.
   ((and proj-root
         (ejump-git-grep-installed?)
         (file-exists-p (expand-file-name ".git" proj-root)))
    (ejump-generators-by-searcher 'git-grep))

   ;; If `ejump-prefer-searcher' is not nil then use if installed.
   ((and ejump-prefer-searcher
         (funcall (plist-get (ejump-generators-by-searcher ejump-prefer-searcher)
                             :installed)))
    (ejump-generators-by-searcher ejump-prefer-searcher))

   ;; Fallback searcher order.
   ((ejump-ag-installed?)
    (ejump-generators-by-searcher 'ag))
   ((ejump-rg-installed?)
    (ejump-generators-by-searcher 'rg))
   ((eq (ejump-grep-installed?) 'gnu)
    (ejump-generators-by-searcher 'gnu-grep))
   (t
    (ejump-generators-by-searcher 'grep))))

(defun ejump-shell-command-switch ()
  "Yields the shell command switch to use for the current
  `shell-file-name' in order to not load the shell profile/RC for
  speeding up things."
  (let ((base-name (downcase (file-name-base shell-file-name))))
    (cond
     ((or (string-equal "zsh" base-name)
          (string-equal "csh" base-name)
          (string-equal "tcsh" base-name))
      "-icf")

     ((string-equal "bash" base-name)
      "-c")

     (t
      shell-command-switch))))

(defun ejump-search-buffer-else-file-system (look-for search-paths regexps
                                                      file-patterns exclude-args
                                                      cur-file line-num)
  (let ((res (ejump-search-buffer look-for regexps line-num)))
    (when (not res)
      (setq res
            (--mapcat
             (ejump-search-file-system look-for it regexps
                                       file-patterns exclude-args
                                       cur-file line-num)
             search-paths)))
    res))

(defun ejump-search-buffer  (look-for regexps line-num &optional buf)
  "Populate REGEXPS with LOOK-FOR avoiding hitting LINE-NUM, optionally in BUF.
Called with LINE-NUM in buffer being 1.
Return:
   ((:path \"file.erl\"
     :line 506
     :context \"some_fn(Arg1, ) ->\"
     :diff -52)
    ...)"
  ;; TODO: If looking for a function, somehow also consider arity.
  (let ((re (concat "\\("
                    (s-join
                     "\\|"
                     (--map (ejump-populate-regexp-for-buf look-for it)
                            regexps))
                    "\\)"))
        (res))
    (save-excursion
      (save-match-data
        (when buf (set-buffer buf))
        (goto-char (point-min))
        (while (re-search-forward re (point-max) t)
          (let* ((line-beginning (save-excursion (beginning-of-line)
                                                 (point)))
                 (line-ending  (save-excursion (end-of-line)
                                               (point)))
                 (ctxt (copy-sequence (buffer-substring-no-properties
                                       line-beginning
                                       line-ending)))
                 (line (+ (count-lines 1 (point))
                          (if (= (current-column) 0) 1 0))))
            (if (not (= line line-num))
                (setq res
                      (append res (list (list :path (buffer-file-name)
                                              :line line
                                              :context ctxt
                                              :diff (- line line-num))))))))))
    (ejump-filter-out-subseqent-function-clauses look-for res)))

(defun ejump-populate-regexp-for-buf (look-for re)
  (let ((text re))
    (setq text (s-replace "\\j" "\\b" text))

    (setq text (s-replace "\\s" "[[:space:]]" text))
    (setq text (s-replace "\\(" "(" text))
    (setq text (s-replace "\\)" ")" text))
    (setq text (s-replace "JJJ" (regexp-quote look-for) text))
    text))

(defun ejump-filter-out-subseqent-function-clauses (look-for res)
  "When LOOK-FOR occurs first in :context of RES, include only the first hit
for each file.  The assumption is that function_clauses (only) occur first."
  (let ((curr-file))
    (--filter
     (if (s-starts-with? look-for (plist-get it :context))
         (let ((item-file (plist-get it :path)))
           ;; If new file, remember that and keep this item
           (when (not (string= item-file curr-file))
             (setq curr-file item-file)
             t))
       ;; Not at the beginning => probably not a function clause. Keep it.
       t)
     res)))

(defun ejump-search-file-system (look-for proj regexps
                                          file-patterns exclude-args
                                          cur-file line-num)
  "Populate REGEXPS with LOOK-FOR and search dir PROJ.
Search files matching FILE-PATTERNS excluding EXCLUDE-ARGS.
Use file searching command from GENERATE-FN and parse with PARSE-FN.
Do not report matches in CUR-FILE for LINE-NUM.
Return:
   ((:path \"file.erl\"
     :line 506
     :context \"some_fn(Arg1, ) ->\"
     :diff -52)
    ...)"
  (let* ((gen-funcs (ejump-pick-grep-variant proj))
         (parse-fn (plist-get gen-funcs :parse))
         (generate-fn (plist-get gen-funcs :generate))
         (proj-root (if (file-remote-p proj)
                        (directory-file-name
                         (tramp-file-name-localname
                          (tramp-dissect-file-name proj)))
                      proj))
         (cmd (funcall generate-fn look-for cur-file proj-root
                       regexps file-patterns exclude-args))
         ;; (_debug (message "cmd=\"%s\"" cmd))
         (shell-command-switch (ejump-shell-command-switch))
         (rawresults (shell-command-to-string cmd)))

    (ejump-debug-message cmd rawresults)
    (when (and (s-blank? rawresults) ejump-fallback-search)
      (setq regexps (list ejump-fallback-regexp))
      (setq cmd (funcall generate-fn look-for cur-file proj-root regexps
                         file-patterns exclude-args))
      (setq rawresults (shell-command-to-string cmd))
      (ejump-debug-message cmd rawresults))
    (unless (s-blank? cmd)
      (let ((results (funcall parse-fn rawresults cur-file line-num)))
        (ejump-filter-out-subseqent-function-clauses
         look-for
         (--filter (s-contains? look-for (plist-get it :context)) results))))))

(defun ejump-parse-response-line (resp-line cur-file)
  "Parse a search program's single RESP-LINE for CUR-FILE
into a list of (path line context)."
  (let* ((parts (--remove (string= it "")
                          (s-split "\\(?:^\\|:\\)[0-9]+:"  resp-line)))
         (line-num-raw (s-match "\\(?:^\\|:\\)\\([0-9]+\\):" resp-line)))

    (cond
     ;; From dumb-jump:
     ;; fixes rare bug where context is blank
     ;; but file is defined "/somepath/file.txt:14:"
     ;; OR: (and (= (length parts) 1) (file-name-exists (nth 0 parts)))
     ((s-match ":[0-9]+:$" resp-line)
      nil)
     ((and parts line-num-raw)
      (if (= (length parts) 2)
          (list (let ((path (expand-file-name (nth 0 parts))))
                  (if (file-name-absolute-p (nth 0 parts))
                      path
                    (file-relative-name path)))
                (nth 1 line-num-raw) (nth 1 parts))
        ;; this case is when they are searching a particular file...
        (list (let ((path (expand-file-name cur-file)))
                (if (file-name-absolute-p cur-file)
                    path
                  (file-relative-name path)))
              (nth 1 line-num-raw) (nth 0 parts)))))))

(defun ejump-parse-response-lines (parsed cur-file cur-line-num)
  "Turn PARSED response lines into a list of property lists.
Using CUR-FILE and CUR-LINE-NUM to exclude jump origin."
  (let* ((records (--mapcat
                   (when it
                     (let* ((line-num (string-to-number (nth 1 it)))
                            (diff (- cur-line-num line-num)))
                       (list `(:path ,(nth 0 it)
                                     :line ,line-num
                                     :context ,(nth 2 it)
                                     :diff ,diff))))
                   parsed))
         (results (-non-nil records)))
    (--filter
     (not (and
           (string= (plist-get it :path) cur-file)
           (= (plist-get it :line) cur-line-num)))
     results)))

(defun ejump-parse-grep-response (resp cur-file cur-line-num)
  "Takes a grep response RESP and parses into a list of plists."
  (let* ((resp-no-warnings (--filter
                            (and (not (s-starts-with? "grep:" it))
                                 (not (s-contains? "No such file or" it)))
                            (s-split "\n" (s-trim resp))))
         (parsed (--map (ejump-parse-response-line it cur-file)
                        resp-no-warnings)))
    (ejump-parse-response-lines parsed cur-file cur-line-num)))

(defun ejump-parse-ag-response (resp cur-file cur-line-num)
  "Takes a ag response RESP and parses into a list of plists."
  (let* ((resp-lines (s-split "\n" (s-trim resp)))
         (parsed (--map (ejump-parse-response-line it cur-file) resp-lines)))
    (ejump-parse-response-lines parsed cur-file cur-line-num)))

(defun ejump-parse-rg-response (resp cur-file cur-line-num)
  "Takes a rg response RESP and parses into a list of plists."
  (let* ((resp-lines (s-split "\n" (s-trim resp)))
         (parsed (--map (ejump-parse-response-line it cur-file) resp-lines)))
    (ejump-parse-response-lines parsed cur-file cur-line-num)))

(defun ejump-parse-git-grep-response (resp cur-file cur-line-num)
  "Takes a git grep response RESP and parses into a list of plists."
  (let* ((resp-lines (s-split "\n" (s-trim resp)))
         (parsed (--map (ejump-parse-response-line it cur-file) resp-lines)))
    (ejump-parse-response-lines parsed cur-file cur-line-num)))

(defun ejump-re-match (re s)
  "Does regular expression RE match string S. If RE is nil return nil."
  (when (and re s)
    (s-match re s)))

(defun ejump-arg-joiner (prefix values)
  "Helper to generate command arg with its PREFIX for each value in VALUES."
  (let ((args (s-join (format " %s " prefix) values)))
    (if (and args values)
        (format " %s %s " prefix args)
      "")))

(defun ejump-populate-regexp (it look-for variant)
  "Populate IT regexp template with LOOK-FOR."
  (let ((boundary (cond ((eq variant 'rg) ejump-rg-word-boundary)
                        ((eq variant 'ag) ejump-ag-word-boundary)
                        ((eq variant 'git-grep-plus-ag) ejump-ag-word-boundary)
                        ((eq variant 'git-grep) ejump-git-grep-word-boundary)
                        (t ejump-grep-word-boundary))))
    (let ((text it))
      (setq text (s-replace "\\j" boundary text))
      (when (eq variant 'gnu-grep)
        (setq text (s-replace "\\s" "[[:space:]]" text)))
      (setq text (s-replace "JJJ" (regexp-quote look-for) text))
      (when (and (eq variant 'rg) (string-prefix-p "-" text))
        (setq text (concat "[-]" (substring text 1))))
      text)))

(defun ejump-populate-regexps (look-for regexps variant)
  "Take list of REGEXPS and populate the LOOK-FOR target and return that list."
  (--map (ejump-populate-regexp it look-for variant) regexps))

(defun ejump-generate-ag-command (look-for cur-file proj regexps
                                           file-patterns exclude-paths)
  ;; FIXME: ice.erl matches wxChoice.erl when the otp dir is traversed...
  ;;        how to indicate beginning-of-basename to the --file-search-regex ??
  "Generate the ag response based on the needle LOOK-FOR in the directory PROJ."
  (let* ((filled-regexps (ejump-populate-regexps look-for regexps 'ag))
         (proj-dir (file-name-as-directory proj))
         ;; TODO: --search-zip always? in case the include is the in gz area like emacs lisp code.
         (cmd (concat ejump-ag-cmd
                      " --nocolor --nogroup"
                      (if (s-ends-with? ".gz" cur-file)
                          " --search-zip"
                        "")
                      (when (not (s-blank? ejump-ag-search-args))
                        (concat " " ejump-ag-search-args))
                      (if (not file-patterns)
                          ;; FIXME: should search also .xrl and .yrl
                          " --erlang"
                        "")))
         (include-args (concat
                        " --file-search-regex "
                        (shell-quote-argument
                         (s-join "|" (--map (concat "(^|/)" it)
                                            file-patterns)))))
         (exclude-args (ejump-arg-joiner
                        "--ignore-dir" (--map (shell-quote-argument
                                               (s-replace proj-dir "" it))
                                              exclude-paths)))
         (regexp-args (shell-quote-argument (s-join "|" filled-regexps))))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd include-args exclude-args regexp-args proj))))

(defun ejump-get-git-grep-files-matching-symbol (symbol proj-root)
  "Search for the literal SYMBOL in the PROJ-ROOT via git grep for a list of file matches."
  (let* ((cmd (format "git grep --full-name -F -c %s %s"
                      (shell-quote-argument symbol) proj-root))
         (result (s-trim (shell-command-to-string cmd)))
         (matched-files (--map (first (s-split ":" it))
                               (s-split "\n" result))))
    matched-files))

(defun ejump-format-files-as-ag-arg (files proj-root)
  "Take a list of FILES and their PROJ-ROOT and return a `ag -G` argument."
  (format "'(%s)'" (s-join "|" (--map (file-relative-name
                                       (expand-file-name it proj-root))
                                      files))))

(defun ejump-get-git-grep-files-matching-symbol-as-ag-arg (symbol proj-root)
  "Get the files matching the SYMBOL via `git grep` in the PROJ-ROOT.
Return them formatted for `ag -G`."
  (ejump-format-files-as-ag-arg
   (ejump-get-git-grep-files-matching-symbol symbol proj-root)
   proj-root))

;; git-grep plus ag only recommended for huge repos like the linux kernel
(defun ejump-generate-git-grep-plus-ag-command (look-for cur-file proj
                                                         regexps
                                                         file-patterns
                                                         exclude-paths)
  "Generate the ag response based on the needle LOOK-FOR in the directory PROJ.
Using ag to search only the files found via git-grep literal symbol search."
  (let* ((filled-regexps (ejump-populate-regexps look-for regexps 'ag))
         (proj-dir (file-name-as-directory proj))
         (ag-files-arg (ejump-get-git-grep-files-matching-symbol-as-ag-arg
                        look-for proj-dir))
         (cmd (concat ejump-ag-cmd
                      " --nocolor --nogroup"
                      (if (s-ends-with? ".gz" cur-file)
                          " --search-zip"
                        "")
                      " -G " ag-files-arg
                      " "))
         (exclude-args (ejump-arg-joiner
                        "--ignore-dir" (--map (shell-quote-argument
                                               (s-replace proj-dir "" it))
                                              exclude-paths)))
         (regexp-args (shell-quote-argument (s-join "|" filled-regexps))))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd exclude-args regexp-args proj))))

(defun ejump-generate-rg-command (look-for _cur-file proj regexps
                                           file-patterns exclude-paths)
  "Generate the rg response based on the needle LOOK-FOR in the directory PROJ."
  (let* ((filled-regexps (ejump-populate-regexps look-for regexps 'rg))
         (proj-dir (file-name-as-directory proj))
         (cmd (concat ejump-rg-cmd
                      " --color never --no-heading --line-number -U"
                      (when (not (s-blank? ejump-rg-search-args))
                        (concat " " ejump-rg-search-args))
                      (if (not file-patterns)
                          ;; FIXME: should search also .xrl and .yrl
                          " --type erlang"
                        "")))
         (include-args (ejump-arg-joiner
                        "-g"  (--map (shell-quote-argument
                                      (format "%s/**/%s" proj it))
                                     file-patterns)))
         (exclude-args (ejump-arg-joiner
                        "-g" (--map (shell-quote-argument
                                     (concat "!" (s-replace proj-dir "" it)))
                                    exclude-paths)))
         (regexp-args (shell-quote-argument (s-join "|" filled-regexps))))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd include-args exclude-args regexp-args proj))))

(defun ejump-generate-git-grep-command (look-for cur-file proj regexps
                                                 file-patterns exclude-paths)
  "Generate the git grep response based on the needle LOOK-FOR in the PROJ dir."
  (let* ((filled-regexps (ejump-populate-regexps look-for regexps 'git-grep))
         (cmd (concat ejump-git-grep-cmd
                      " --color=never --line-number"
                      (when ejump-git-grep-search-untracked
                        " --untracked")
                      (when (not (s-blank? ejump-git-grep-search-args))
                        (concat " " ejump-git-grep-search-args))
                      " -E"))
         (fileexps (s-join " " (or (--map (shell-quote-argument
                                           (format "%s/**/%s" proj it))
                                          file-patterns)
                                   '(":/"))))
         (exclude-args (s-join " " (--map (shell-quote-argument
                                           (concat ":(exclude)" it))
                                          exclude-paths)))
         (regexp-args (shell-quote-argument (s-join "|" filled-regexps))))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd regexp-args "--" fileexps exclude-args))))

(defun ejump-generate-grep-command (look-for cur-file proj regexps
                                             file-patterns exclude-paths)
  "Find LOOK-FOR's CUR-FILE in the PROJ with REGEXPS for the LANG but not in EXCLUDE-PATHS."
  (let* ((filled-regexps (--map (shell-quote-argument it)
                                (ejump-populate-regexps look-for regexps
                                                        'grep)))
         (cmd (concat (if (eq system-type 'windows-nt)
                          ""
                        (concat ejump-grep-prefix " "))
                      (if (s-ends-with? ".gz" cur-file)
                          ejump-zgrep-cmd
                        ejump-grep-cmd)))
         (exclude-args (ejump-arg-joiner "--exclude-dir" exclude-paths))
         (include-args (or (--map (concat " --include "
                                          (shell-quote-argument it))
                                  file-patterns)
                           " --include \\*.erl "))
         (regexp-args (ejump-arg-joiner "-e" filled-regexps)))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd ejump-grep-args exclude-args include-args regexp-args proj))))

(defun ejump-generate-gnu-grep-command (look-for cur-file proj regexps
                                                 file-patterns _exclude-paths)
  "Find LOOK-FOR's CUR-FILE in the PROJ with REGEXPS for the LANG but not in EXCLUDE-PATHS."
  (let* ((filled-regexps (--map (shell-quote-argument it)
                                (ejump-populate-regexps look-for regexps
                                                        'gnu-grep)))
         (cmd (concat (if (eq system-type 'windows-nt)
                          ""
                        (concat ejump-grep-prefix " "))
                      (if (s-ends-with? ".gz" cur-file)
                          ejump-zgrep-cmd
                        ejump-grep-cmd)))
         ;; TODO: GNU grep doesn't support these, so skip them
         (exclude-args "")
         (include-args "")
         (regexp-args (ejump-arg-joiner "-e" filled-regexps)))
    (if (= (length regexps) 0)
        ""
      (ejump-concat-command cmd ejump-gnu-grep-args exclude-args
                            include-args regexp-args proj))))

(defun ejump-concat-command (&rest parts)
  "Concat the PARTS of a command if each part has a length."
  (s-join " " (-map #'s-trim (--filter (> (length it) 0) parts))))

;;;###autoload
(define-minor-mode ejump-mode
  "Minor mode for jumping to variable and function definitions"
  :global t
  :keymap ejump-mode-map)


;;; Xref Backend
(when (featurep 'xref)
  (dolist (obsolete
           '(ejump-mode
             ejump-go
             ejump-go-prefer-external-other-window
             ejump-go-prompt
             ejump-quick-look
             ejump-go-other-window
             ejump-go-current-window
             ejump-go-prefer-external
             ejump-go-current-window))
    (make-obsolete
     obsolete
     (format "`%s' has been obsoleted by the xref interface."
             obsolete)
     "2020-06-26"))
  (make-obsolete 'ejump-back
                 "`ejump-back' has been obsoleted by `xref-pop-marker-stack'."
                 "2020-06-26")

  (cl-defmethod xref-backend-identifier-at-point ((_backend (eql ejump)))
    (let ((identifier (erlang-get-identifier-at-point)))
      (if identifier
          (propertize (erlang-id-name identifier)
                      :ejump-id-at-point identifier
                      :ejump-buf (current-buffer))
        nil)))

  (cl-defmethod xref-backend-definitions ((_backend (eql ejump)) prompt)
    (ejump-xref-backend-search-and-get-results prompt 'find-defs))

  (cl-defmethod xref-backend-apropos ((_backend (eql ejump)) pattern)
    (xref-backend-definitions 'ejump pattern))

  (cl-defmethod xref-backend-references ((_backend (eql ejump)) prompt)
    (ejump-xref-backend-search-and-get-results prompt 'find-refs))

  (cl-defmethod xref-backend-identifier-completion-table ((_backend
                                                           (eql ejump)))
    nil)
  )

;;;###autoload
(defun ejump-xref-activate ()
  "Function to activate xref backend.
Add this function to `xref-backend-functions' for ejump to be activiated."
  (and (ejump-get-project-root default-directory)
       'ejump))

(provide 'ejump)
;;; ejump.el ends here
