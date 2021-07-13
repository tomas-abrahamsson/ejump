;; Project-wide Emacs settings
(
 ;; For all modes (types of files)
 (nil . (
	 ;; use spaces to indent, not tabs
	 (indent-tabs-mode . nil)
	 ;; but if there are any tabs, the tab with is 8 chars anyway
	 (tab-width . 8)
	 ;; Lines no longer than this
	 (fill-column . 80)))

 ;; However, for Makefiles, tabs are important
 (makefile-mode . ((indent-tabs-mode . t))))
