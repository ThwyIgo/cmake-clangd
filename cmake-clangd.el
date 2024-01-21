;;; cmake-clangd.el --- Setup clangd settings for cmake projects  -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Thiago Pacheco Rocha

;; Author: Thiago Pacheco Rocha <thiagopachecorocha@hotmail.com>
;; Created: 06 Jan 2024
;; Version: 0.0.1

;; Keywords: tools
;; URL: https://example.com

;; Package-Requires: (eglot json)

;; This file is not part of GNU Emacs.

;;; Commentary:
;; Package that uses CMake's file API to correctly configure clangd LSP server.
;; It also adds functions to easily compile and run a CMake project.

;;; Code:

(require 'json)
(require 'eglot)

(defgroup cmake-clangd nil
  "Configure clangd to work with CMake."
  :prefix "cmake-clangd-"
  :group 'applications)

(defcustom cmake-clangd-build-dir "out/"
  "Directory where build files will be.
This is the directory used with \"-B\" cmake flag when configuring the project."
  :type 'directory
  :group 'cmake-clangd)

(defconst cmake-clangd-output-buffer "*cmake-clangd-output*"
  "The name of the buffer where output will be outputted.
It is a read-only buffer.")

(defvar cmake-clangd-last-flags '("-DCMAKE_BUILD_TYPE=Debug")
  "Last flags used with CMake. They will be suggested to the user when
configuring the project. It should be a list of strings.")

;;;###autoload
(defun cmake-clangd-setup ()
  "Configures clangd to use compile_commands.json generated by CMake."
  (interactive)

  (let* ((eglot-project-root (expand-file-name (project-root (eglot--current-project))))
         (cmake-project-root (if (file-exists-p (concat eglot-project-root "CMakeLists.txt"))
                                 eglot-project-root
                               (unless (null buffer-file-name)
                                 (cmake-clangd-find-file-up-dir "CMakeLists.txt" (file-name-parent-directory buffer-file-name))))))
    (cmake-clangd-log "Eglot project: " eglot-project-root)
    (unless (null cmake-project-root)
      (cmake-clangd-log "Found an initial CMakeLists.txt in " cmake-project-root))

    (when (interactive-p)
      (setq cmake-project-root
            (expand-file-name (file-name-parent-directory
                               (read-file-name "Top-level CMakeLists.txt: " cmake-project-root nil t "CMakeLists.txt"
                                               (lambda (file) (and
                                                               (file-exists-p file)
                                                               (string-match-p "CMakeLists\\.txt" file)))))))
      (cmake-clangd-log "User chose project root as: " cmake-project-root))

    (when (null cmake-project-root)
      (error "CMakeLists.txt not found"))

    ;; Call CMake to configure the project
    (let* ((inhibit-read-only t)
           (cmake-flags (cmake-clangd-configure cmake-project-root))
           (binary-dir (lax-plist-get cmake-flags "-B")))

      (cmake-clangd-log "CMake configure flags: " (format "%s" cmake-flags))
      ;; CMake can take a long time to configure
      (message "Configuring project...")
      (apply #'call-process "cmake" nil cmake-clangd-output-buffer nil
             cmake-flags)

      (cmake-clangd-set-compilationdatabase (concat cmake-project-root ".clangd") binary-dir)

      (message "cmake-clangd: finished setup!")
      (eglot-reconnect (eglot-current-server)) ;; Make clangd find .clangd
      )

    ;; Find executable targets with CMake file API
    ;; (let ((inhibit-read-only t)
    ;;       (cmake-api-dir (concat eglot-project-root cmake-clangd-build-dir
    ;;                              ".cmake/api/v1/"))
    ;;       (cmake-api-index nil))
    ;;   (make-empty-file (concat cmake-api-dir "query/codemodel-v2") t)
    ;;   (call-process "cmake" nil cmake-clangd-output-buffer nil
    ;;                 "-S" cmake-project-root
    ;;                 "-B" (concat eglot-project-root cmake-clangd-build-dir)
    ;;                 "-DCMAKE_BUILD_TYPE=Debug")
    ;;   (setq cmake-api-index
    ;;         (car-safe (directory-files (concat cmake-api-dir "reply/") t
    ;;                                    "index-.*\\.json")))
    ;;   (cmake-clangd-log "API index: " cmake-api-index)
    ;;   )
    )
  )

;;;###autoload
(defun cmake-clangd-build ()
  "Build a CMake project located in a directory.
Uses .clangd file the find the build directory."
  (interactive)
  (let ((dotclangd (concat (cmake-clangd-find-file-up-dir ".clangd" (file-name-parent-directory buffer-file-name))
                           ".clangd")))
    (cmake-clangd-log ".clangd dir: " dotclangd)
    (cmake-clangd-log "CompilationDatabase: " (cmake-clangd-get-compilationdatabase dotclangd))
    )
  )

(defun cmake-clangd-configure (cmake-project-root)
  "Returns CMake configure flags and updates `cmake-clangd-last-flags'."
  (let ((presets-file (concat cmake-project-root "CMakePresets.json"))
        (binary-dir (concat cmake-project-root cmake-clangd-build-dir)))
    (when (file-exists-p presets-file)
      (cmake-clangd-log "Presets found!")
      (let* ((presets-json (json-read-file presets-file))
             (configure-presets (alist-get 'configurePresets presets-json))
             (configure-presets-names
              (remove nil (mapcar (lambda (preset)
                                    (unless (alist-get 'hidden preset)
                                      (alist-get 'name preset)))
                                  configure-presets)))
             (chosen-preset-name (completing-read "Configure preset (or :none): " (append '(":none") configure-presets-names) nil t)))
        (cmake-clangd-log "Chosen preset: " chosen-preset-name)

        (unless (string-equal chosen-preset-name ":none")
          ;; Follow preset hierarchy until binaryDir is found. If it's not found, use `cmake-clangd-build-dir'
          (let* ((chosen-preset (seq-find (lambda (i)
                                            (string-equal chosen-preset-name (alist-get 'name i)))
                                          configure-presets))
                 (inherited-preset chosen-preset)
                 (temp-binary-dir nil))

            (while (and (null temp-binary-dir) inherited-preset)
              (setq temp-binary-dir (alist-get 'binaryDir inherited-preset))
              (when (null temp-binary-dir)
                (setq inherited-preset
                      (seq-find (lambda (i)
                                  (string-equal (alist-get 'inherits inherited-preset) (alist-get 'name i)))
                                configure-presets))
                ))
            ;; If a custom binaryDir is found in the preset
            (when temp-binary-dir
              (setq binary-dir temp-binary-dir))

            (setq binary-dir (string-replace "${sourceDir}" (directory-file-name cmake-project-root) binary-dir)
                  binary-dir (string-replace "${presetName}" chosen-preset-name binary-dir)
                  binary-dir (file-name-as-directory binary-dir))
            (cmake-clangd-log "Binary dir: " binary-dir)
            ))
        (setq cmake-clangd-last-flags (split-string
                                       (read-string "Additional CMake flags: " (mapconcat 'identity cmake-clangd-last-flags " "))))
        )
      ;; Return CMake flags
      (append `("-S" ,cmake-project-root
                "-B" ,binary-dir
                "-DCMAKE_EXPORT_COMPILE_COMMANDS=TRUE")
              cmake-clangd-last-flags)
      ))
  )

(defun cmake-clangd-set-compilationdatabase (dotclangd value)
  "Use regex to find where CompilationDatabase option is in `dotclangd' and replace
it with `value'. KISS.
If `dotclangd' doesn't exist, create it."
  (with-temp-buffer
    (if (file-exists-p dotclangd)
      (progn
        (insert-file-contents dotclangd)
        (if (re-search-forward "CompilationDatabase:" nil t)
            (kill-line)
          ;; else
          (if (re-search-forward "CompileFlags:" nil t)
              (insert "
    CompilationDatabase: ")
            ;; else
            (insert "CompileFlags:
    CompilationDatabase: "))))

      ;; if `dotclangd' file doesn't exist
      (insert "CompileFlags:
    CompilationDatabase: ")
      )
    (insert value)
    (write-file dotclangd)
    )
  )

(defun cmake-clangd-get-compilationdatabase (dotclangd)
  "Get CompileFlags:CompilationDatabase from a .clangd file using regex."
  (with-temp-buffer
    (insert-file-contents dotclangd)
    (when (re-search-forward "CompilationDatabase:" nil t)
      (forward-whitespace 1)
      (let ((initial-point (point)))
        (end-of-line)
        (buffer-substring initial-point (point))
        )))
  )

(defun cmake-clangd-find-file-up-dir (filename directory)
  "Starting from `directory', tries to find `filename' file; if not found, goes
up 1 level in the directory hierarchy and repeat.
Returns the directory where `filename' is located, or nil if it is not found."
  (let ((cmake-project-root directory))
    (while (and (not (null cmake-project-root))
                (not (file-readable-p (concat cmake-project-root filename))))
      (setq cmake-project-root (file-name-parent-directory cmake-project-root)))

    cmake-project-root
    )
  )

(defun cmake-clangd-log (&rest strings)
  "Append `strings' to `cmake-clangd-output-buffer'."
  (with-current-buffer (get-buffer-create cmake-clangd-output-buffer)
    (read-only-mode t)
    (end-of-buffer)
    (let ((inhibit-read-only t))
      (apply #'insert strings)
      (insert "\n"))
    )
  )

;;; cmake-clangd.el ends here
