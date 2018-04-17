;;; lsp-intellij.el --- intellij lsp client                   -*- lexical-binding: t; -*-

;; Copyright (C) 2018

;; Author:  Ruin0x11
;; Keywords: java
;; Package-Requires: ((emacs "25.1") (lsp-mode "4.1"))

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

;; lsp-mode client for intellij-lsp-server.
;; After installing lsp-mode, you can use it as follows:

;; (with-eval-after-load 'lsp-mode
;;   (require 'lsp-intellij)
;;   (add-hook 'java-mode-hook #'lsp-intellij-enable))

;; Then, after opening and configuring a project in your instance of
;; IDEA that has intellij-lsp-server, navigate to a Java file tracked
;; by that project.

;;; Code:

(require 'lsp-mode)
(require 'cl)

(defvar lsp-intellij-use-topmost-maven-root t
  "If non-nil, `lsp-intellij' will attempt to locate the topmost
Maven project in a nested hierarchy if a Maven subproject is opened
and set the LSP project root to it. Otherwise, `lsp-intellij' will set
the project root to be the root of the Maven subproject.")

;; copied from projectile to avoid a dependency
(defun lsp-intellij--parent (path)
  "Return the parent directory of PATH.
PATH may be a file or directory and directory paths may end with a slash."
  (directory-file-name (file-name-directory (directory-file-name (expand-file-name path)))))

;; copied from projectile to avoid a dependency
(defun lsp-intellij--root-top-down-recurring (dir list)
  "Identify a project root in DIR by recurring top-down search for files in LIST.
Return the last (bottommost) matched directory in the topmost sequence
of matched directories.  Nil otherwise."
  (cl-some
   (lambda (f)
     (locate-dominating-file
      dir
      (lambda (dir)
        (and (file-exists-p (expand-file-name f dir))
             (or (string-match locate-dominating-stop-dir-regexp (lsp-intellij--parent dir))
                 (not (file-exists-p (expand-file-name f (lsp-intellij--parent dir)))))))))
   list))

(defun lsp-intellij--any-value-in-hash (hash-table)
  (block nil
    (maphash (lambda (k v) (return v))
             hash-table)))

(defun lsp-intellij--is-extracted-jar-file (file-name)
  (or
   ;; extracted from archive-mode (prevents error when LSP mode hooks run)
   (and (string-match-p "\.jar:[a-zA-Z]+" file-name) (not (file-exists-p file-name)))
   ;; extracted using lsp-intellij
   (string-match-p (regexp-quote temporary-file-directory) file-name)))

(defun lsp-intellij--get-root ()
  (if (lsp-intellij--is-extracted-jar-file (buffer-file-name))
      (lsp--workspace-root (lsp-intellij--any-value-in-hash lsp--workspaces))
    (let ((file (locate-dominating-file (buffer-file-name)
                                        (lambda (parent)
                                          (when (directory-name-p parent)
                                            (directory-files parent nil ".*.iml"))))))
      (when (not file)
        (error "No root found."))
      (let* ((pom (directory-files (file-name-directory file) nil "pom.xml"))
             (has-pom (> (length pom) 0))
             (root (if (and has-pom lsp-intellij-use-topmost-maven-root)
                       (lsp-intellij--root-top-down-recurring file '("pom.xml"))
                     file)))
        (file-name-directory root)))))

(defun lsp-intellij--locations-to-xref-items (locations)
  "Return a list of `xref-item' from LOCATIONS, except for those inside JARs."
  (let* ((filtered-locs (seq-filter
                         (lambda (loc)
                           (string-prefix-p "file" (gethash "uri" loc)))
                         locations))
         (fn (lambda (loc) (lsp--uri-to-path (gethash "uri" loc))))
         ;; locations-by-file is an alist of the form
         ;; ((FILENAME . LOCATIONS)...), where FILENAME is a string of the
         ;; actual file name, and LOCATIONS is a list of Location objects
         ;; pointing to Ranges inside that file.
         (locations-by-file (seq-group-by fn filtered-locs))
         (items-by-file (mapcar #'lsp--get-xrefs-in-file locations-by-file)))
    (apply #'append items-by-file)))


(defun lsp-intellij--xref-backend () 'xref-lsp-intellij)

(cl-defmethod xref-backend-apropos ((_backend (eql xref-lsp-intellij)) pattern)
  (let* ((symbols (lsp--send-request (lsp--make-request
                                     "workspace/symbol"
                                     `(:query ,pattern))))
         ;; filter out paths inside JARs
         (filtered-syms (seq-filter
                         (lambda (sym)
                           (string-prefix-p "file" (gethash "uri" (gethash "location" sym))))
                         symbols)))
    (mapcar 'lsp--symbol-information-to-xref filtered-syms)))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql xref-lsp-intellij)))
  (xref-backend-identifier-at-point 'xref-lsp))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql xref-lsp-intellij)))
  (xref-backend-identifier-completion-table 'xref-lsp))

(cl-defmethod xref-backend-definitions ((_backend (eql xref-lsp-intellij)) identifier)
  (xref-backend-definitions 'xref-lsp identifier))

(cl-defmethod xref-backend-references ((_backend (eql xref-lsp-intellij)) identifier)
  (xref-backend-references 'xref-lsp identifier))

(defun lsp-intellij--make-jar-temp-path (jar-path internal-path)
  "Return a temporary path for a jar-internal file to be extracted to."
  (let* ((jar-file-name (file-name-base jar-path))
         (temp-path (concat temporary-file-directory "lsp-intellij/" jar-file-name "/")))
    temp-path))

(defun lsp-intellij--write-jar-metadata (archive-path dest)
  "Write a metadata file that points to ARCHIVE-PATH, a jar file path.

Used for allowing IntelliJ to find the actual jar an extracted jar file is contained in."
  (with-temp-buffer
    (insert (lsp--path-to-uri archive-path))
    (write-file (concat dest "jarpath") nil)))

(defun lsp-intellij--extract-archive-file (archive original-archive internal-path dest)
  "Extracts the file at INTERNAL-PATH inside a .jar ARCHIVE to DEST.

Also writes the location of ORIGINAL-ARCHIVE, containing the compiled classes, so IntelliJ can find it."
  (let* ((internal-dir (substring (file-name-directory internal-path) 1))
         (internal-file (file-name-nondirectory internal-path))
         (internal-name (file-name-sans-extension internal-file))
         (search-string (concat internal-dir internal-name)))
    (save-window-excursion
      (find-file archive)
      (let ((archive-buffer (current-buffer)))
        (goto-char (point-min))
        (re-search-forward search-string)
        (archive-extract)
        (let ((extract-buffer (current-buffer))
              (outpath (concat dest internal-dir (file-name-nondirectory (buffer-file-name)))))
          (mkdir (file-name-directory outpath) t)
          (lsp-intellij--write-jar-metadata original-archive dest)
          (write-file outpath nil)
          (kill-buffer archive-buffer)
          (kill-buffer extract-buffer)
          outpath)))))

(defconst lsp-intellij--file-extracted-from-jar-regex
  "\\\.\\(java\\|kt\\|scala\\|xml\\|MF\\)$")

(defun lsp-intellij--extracted-file-exists (temp-path internal-file-base)
  "Test if a file with a similar filename has already been extracted from a jar.

Used for finding the corresponding .java/.kt file from a jar's .class file.
Return the file path if found, nil otherwise."
  (cl-find-if (lambda (s) (and (eq (file-name-sans-extension s) internal-file-base)
                               (string-match-p lsp-intellij--file-extracted-from-jar-regex s)))
              (directory-files temp-path)))

(defun lsp-intellij--visit-jar-uri (uri)
  ;; the format is:
  ;; jar://C:/some/directory/my-lib.jar!/com/ruin/stuff/MyClass.class")
  (let* ((url (url-generic-parse-url uri))
         (drive-letter (url-host url))
         (raw (url-filename url))
         (paths (split-string raw "!"))
         (jar-path (concat drive-letter ":" (car paths)))
         (internal-path (cadr paths))
         (sources-jar-path (replace-regexp-in-string "\.jar$" "-sources.jar" jar-path))
         (jar-to-extract (if (file-exists-p sources-jar-path) sources-jar-path jar-path))
         (temp-path (lsp-intellij--make-jar-temp-path jar-to-extract internal-path)))
    ;; TODO: find attached sources using IntelliJ request, in case they live elsewhere
    ;; TODO: return cached dir if exists
    ;(lsp-intellij--extracted-file-exists temp-path (file-name-base internal-path))
    (lsp-intellij--extract-archive-file jar-to-extract jar-path internal-path temp-path)
    ;; the temp path has to be recognizable by the server as "this is from a jar" and associate the correct jar-internal VirtualFile, otherwise code awareness is lost
    ;; make the file read-only
    )
  )



(defun lsp-intellij-find-implementations ()
  "List all implementations for the Java element at point."
  (interactive)
  (let* ((impls (lsp--send-request (lsp--make-request
                                    "idea/implementations"
                                    (lsp--text-document-position-params))))
         (items (lsp-intellij--locations-to-xref-items impls)))
    (if items
        (xref--show-xrefs items nil)
      (message "No implementations found for: %s" (thing-at-point 'symbol t)))))

(defun lsp-intellij-open-project-structure ()
  "Opens the Project Structure dialogue for the current project."
  (interactive)
  (lsp--cur-workspace-check)
  (lsp--send-request
   (lsp--make-request
    "idea/openProjectStructure"
    (lsp--text-document-position-params))
   t))

(defun lsp-intellij-toggle-frame-visibility ()
  "Toggles visibility of the current project's frame."
  (interactive)
  (lsp--cur-workspace-check)
  (lsp--send-request
   (lsp--make-request
    "idea/toggleFrameVisibility"
    (lsp--text-document-position-params))
   t))

(defun lsp-intellij--render-string (str mode)
  (condition-case nil
    (with-temp-buffer
        (delay-mode-hooks (funcall mode))
        (insert str)
        (font-lock-ensure)
        (buffer-string))
    (error str)))

(defconst lsp-intellij-dummy-executable
  (if (eq system-type 'windows-nt)
      '("cmd")
    '("sh"))
  "Program that lsp-mode will open when initializing lsp-intellij.

lsp-mode requires a process to be opened when starting a server over
TCP, even if it isn't the one being communicated with.")

(defconst lsp-intellij--notification-handlers
  '(("idea/indexStarted" .
     (lambda (_w _p)
       (message "Indexing started.")
       (setq lsp-status "(indexing)")))
    ("idea/indexFinished" .
     (lambda (_w _p)
       (message "Indexing finished.")
       (setq lsp-status nil)))))

(defconst lsp-intellij--request-handlers
  '(("idea/temporaryDirectory" .
     (lambda (_w _p)
       (list :directory (lsp--path-to-uri temporary-file-directory))))))

(defun lsp-intellij--initialize-client (client)
  (mapcar #'(lambda (p) (lsp-client-on-notification client (car p) (cdr p)))
	  lsp-intellij--notification-handlers)
  (mapcar #'(lambda (p) (lsp-client-on-request client (car p) (cdr p)))
	  lsp-intellij--request-handlers)

  ;; Emacs strips out the \r in \r\n by default, even with lsp-mode,
  ;; so the proper coding system needs to be set to capture the \r\n.
  (setq-local default-process-coding-system (cons 'utf-8 'utf-8))
  (setq-local coding-system-for-read 'binary)
  (setq-local coding-system-for-write 'binary)
  ;; Ensure the client uses the server's sync method
  (setq-local lsp-document-sync-method nil)
  (add-hook 'lsp-after-open-hook (lambda () (setq-local xref-backend-functions (list #'lsp-intellij--xref-backend))))

  (lsp-provide-marked-string-renderer client "java" (lambda (s) (lsp-intellij--render-string s 'java-mode)))
  (lsp-provide-marked-string-renderer client "kotlin" (lambda (s) (lsp-intellij--render-string s 'kotlin-mode)))
  (lsp-client-register-uri-handler client "jar" 'lsp-intellij--visit-jar-uri))

(lsp-define-tcp-client lsp-intellij "intellij" #'lsp-intellij--get-root lsp-intellij-dummy-executable
                       "127.0.0.1" 8080
                       :initialize #'lsp-intellij--initialize-client)

(provide 'lsp-intellij)
;;; lsp-intellij.el ends here
