;;; optimize.lisp --- optimize metrics in a population of software variants

;; Copyright (C) 2012-2013  Eric Schulte

;;; Commentary:

;; Starting with an initial software object, generate a population of
;; variant implementations and then evolve to optimize some metric
;; such as fastest execution, least communication, lowest energy
;; consumption etc...

;;; Code:
(in-package :optimize)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (enable-curry-compose-reader-macros))


;;; Optimization Software Objects
(defclass asm-perf (asm)
  ((stats :initarg :stats :accessor stats :initform nil)))

(defclass asm-light (light asm)
  ((stats :initarg :stats :accessor stats :initform nil)))

(defun to-asm-light (asm)
  (with-slots (flags linker genome) asm
    (make-instance 'asm-light
      :flags flags
      :linker linker
      :genome (lines genome))))

(defclass asm-range (sw-range asm)
  ((stats :initarg :stats :accessor stats :initform nil)))

(defun to-asm-range (asm)
  (with-slots (flags linker genome) asm
    (make-instance 'asm-range
      :flags flags
      :linker linker
      :genome (list (cons 0 (1- (length genome))))
      :reference (coerce (lines asm) 'vector))))

(defmethod from-file ((asm asm-range) file)
  (setf (lines asm) (split-sequence #\Newline (file-to-string file)))
  asm)

(defmethod copy ((asm asm-range))
  (with-slots (genome linker flags reference) asm
    (make-instance (type-of asm)
      :fitness (fitness asm)
      :genome (copy-tree genome)
      :linker linker
      :flags flags
      :reference reference)))


;;; Configuration Fitness and Runtime
(defvar *script*    nil        "Script used to test benchmark application.")
(defvar *path*      nil        "Path to Assembly file.")
(defvar *rep*       nil        "Program representation to use.")
(defvar *mcmc*      nil        "Whether MCMC search should be used.")
(defvar *res-dir*   nil        "Directory in which to save results.")
(defvar *orig*      nil        "Original version of the program to be run.")
(defvar *period*    nil        "Period at which to run `checkpoint'.")
(defvar *threads*   1          "Number of cores to use.")
(defvar *evals*    (expt 2 18) "Maximum number of test evaluations.")
(defvar *max-err*   0          "Maximum allowed error.")
(defvar *fitness-function* 'fitness "Fitness function.")
(setf *max-population-size* (expt 2 9)
      *fitness-predicate* #'<
      *cross-chance* 2/3
      *tournament-size* 2
      *tournament-eviction-size* 2)
(defvar *git-version* nil "Used in optimize version string.")

(defun arch ()
  (let ((cpuinfo "/proc/cpuinfo"))
    (if (probe-file cpuinfo)
        (with-open-file (in cpuinfo)
          (loop :for line = (read-line in nil) :while line :do
             (cond ((scan "Intel" line) (return-from arch :intel))
                   ((scan "AMD" line)   (return-from arch :amd)))))
        :darwin)))

(defun parse-stdout (stdout)
  (mapcar (lambda-bind ((val key))
            (cons (make-keyword (string-upcase key))
                  (ignore-errors (parse-number val))))
          (mapcar {split-sequence #\,}
                  (split-sequence #\Newline
                    (regex-replace-all ":HG" stdout "")
                    :remove-empty-subseqs t))))

(defun run (asm)
  (with-temp-file (bin)
    (multiple-value-bind (info exit)
        (phenome asm :bin bin)
      (unless (zerop exit)
        (note 5 "ERROR [~a]: ~a" exit info)
        (error "error [~a]: ~a" exit info)))
    (note 4 "running ~S~%" asm)
    (multiple-value-bind (stdout stderr errno) (shell *script* bin)
      (declare (ignorable stderr))
      (append (or (ignore-errors (list (cons :fitness (parse-number stdout))))
                  (ignore-errors (parse-stdout stdout)))
              (list (cons :exit errno) (cons :error 0))))))

(defun apply-fitness-function (fitness-function stats)
  "Apply FITNESS-FUNCTION to STATS."
  (flet ((key-to-sym (keyword)
           (if (keywordp keyword)
               (intern (string-upcase (symbol-name keyword)) :optimize)
               keyword)))
    (let ((*error-output* (make-broadcast-stream))
          (*standard-output* (make-broadcast-stream))
          (expr `(let ,(mapcar (lambda (pair)
                                 (list (key-to-sym (car pair)) (cdr pair)))
                               stats)
                   ,fitness-function)))
      (values (eval expr) expr))))

(defvar infinity
  #+sbcl
  SB-EXT:DOUBLE-FLOAT-POSITIVE-INFINITY
  #+ccl
  CCL::DOUBLE-FLOAT-POSITIVE-INFINITY
  #-(or sbcl ccl)
  (error "must specify a positive infinity value"))

(declaim (inline worst))
(defun worst ()
  (cond ((equal #'< *fitness-predicate*) infinity)
        ((equal #'> *fitness-predicate*) 0)))

(defun test (asm)
  (note 4 "testing ~S~%" asm)
  (or (ignore-errors
        (unless (stats asm) (setf (stats asm) (run asm)))
        (note 4 "stats:~%~S~%" (stats asm))
        (when (and (zerop (aget :exit (stats asm)))
                   (<= (aget :error (stats asm)) *max-err*))
          (apply-fitness-function *fitness-function* (stats asm))))
      (worst)))

(defun checkpoint ()
  (note 1 "checkpoint after ~a fitness evaluations" *fitness-evals*)
  #+sbcl (sb-ext:gc :force t :full t)
  ;; save the best of the entire population
  (store (extremum *population* *fitness-predicate* :key #'fitness)
         (make-pathname :directory *res-dir*
                        :name (format nil "best-~a" *fitness-evals*)
                        :type "store"))
  ;; write out population stats
  (let ((fits  (mapcar #'fitness *population*))
        (sizes (mapcar [#'length #'genome] *population*))
        (stats (make-pathname :directory *res-dir* :name "stats" :type "txt")))
    (flet ((stats (s) (list (apply #'min s) (median s) (apply #'max s))))
      (with-open-file (out stats
                           :direction :output
                           :if-exists :append
                           :if-does-not-exist :create)
        (format out "~&~{~a~^ ~}~%"
                (mapcar (lambda (num) (if (= num infinity) "inf" num))
                        (mapcar #'float
                                `(,*fitness-evals*
                                  ,@(stats fits)
                                  ,@(stats sizes)))))))))


;;; Helpers
(defun quit (&optional (errno 0))
  #+sbcl (sb-ext:exit :code errno)
  #+ccl  (ccl:quit errno))

(defun better (orig new)
  "Return the fraction improvement of new over original."
  (/ (abs (- orig new)) orig))

(defun throw-error (&rest args)
  (apply #'note 0 args)
  (quit))

(defmacro getopts (&rest forms)
  (let ((arg (gensym)))
    `(loop :for ,arg = (pop args) :while ,arg :do
        (cond
          ,@(mapcar (lambda-bind ((short long . body))
                      `((or (and ,short (string= ,arg ,short))
                            (and ,long  (string= ,arg ,long)))
                        ,@body))
                    forms)))))

(defun covariance (a b)
  (declare (cl-user::optimize speed))
  (let ((ma (mean a))
        (mb (mean b))
        (total 0))
    (mapc (lambda (al bl) (incf total (* (- al ma) (- bl mb)))) a b)
    (/ total (- (length a) 1))))


;;; Command line optimization driver
(defvar *checkpoint-funcs* (list #'checkpoint)
  "Functions to record checkpoints.")

(defun store-final-population ()
  #+sbcl (sb-ext:gc :force t)
  (store *population* (make-pathname :directory *res-dir*
                                     :name "final-pop"
                                     :type "store")))

(defun store-final-best ()
  (store (extremum *population* *fitness-predicate* :key #'fitness)
         (make-pathname :directory *res-dir*
                        :name "final-best"
                        :type "store")))

(defvar *final-funcs*
  (list #'store-final-population #'store-final-best)
  "Functions to run at the end of optimization.")


;;; Genome Annotations
(defun asm-disassemble (bin func)
  (ignore-errors ;; TODO: debug parse-integer errors thrown within
    (let ((raw (shell "gdb --batch --eval-command=\"disassemble ~a\" ~a"
                      func bin))
          (rx "[ \t]*0x([a-zA-Z0-9]+)[ \t]*<\\+[0-9]+>:.*"))
      (remove nil
        (mapcar (lambda (line)
                  (multiple-value-bind (all matches) (scan-to-strings rx line)
                    (when all
                      (read-from-string (format nil "#x~a" (aref matches 0))))))
                (split-sequence #\Newline raw))))))

(defun perf-annotations (script)
  ;; Note: another option could use
  ;;       perf report --stdio -i perf.data --sort srcline
  (remove nil
    (mapcar (lambda (line)
              (multiple-value-bind (all matches)
                  (scan-to-strings "([0-9\.]+) +:[ \\t]+([a-fA-F0-9]+):" line)
                (when all
                  (cons (read-from-string (format nil "#x~a"
                                                  (aref matches 1)))
                        (parse-number (aref matches 0))))))
            (split-sequence #\Newline (shell script)))))

(defun genome-addrs (asm &key bin &aux func-addrs)
  (let ((my-bin (or bin (phenome asm))))
    (unwind-protect
         (mapcar
          (lambda (l)
            (multiple-value-bind (all matches)
                (scan-to-strings "^([^\\.][a-zA-Z0-9_]*):" (aget :line l))
              (if all
                  (prog1 nil
                    (setf func-addrs (asm-disassemble my-bin (aref matches 0))))
                  (when func-addrs (pop func-addrs)))))
          (genome asm))
      (when (not bin) (delete-file my-bin)))))

(defun genome-anns (asm annotations &key bin)
  (let ((my-bin (or bin (phenome asm))))
    (unwind-protect
         (mapcar {aget _ annotations}
                 (genome-addrs asm :bin my-bin))
      (when (not bin) (delete-file my-bin)))))

(defun smooth (list)
  (declare (cl-user::optimize speed))
  (mapcar (lambda (b3 b2 b1 o a1 a2 a3)
            (+ (* 0.006 (+ b3 a3))
               (* 0.061 (+ b2 a2))
               (* 0.242 (+ b1 a1))
               (* 0.383 o)))
          (append         (cdddr list) '(0 0 0))
          (append         (cddr  list) '(0 0))
          (append         (cdr   list) '(0))
          (append          list)
          (append '(0)     list)
          (append '(0 0)   list)
          (append '(0 0 0) list)))

(defun widen (list radius)
  "Widen the maximum values in LIST by RADIUS."
  (apply #'mapcar #'max (loop :for i :from (* -1 radius) :to radius :collect
                           (if (< i 0)
                               (append (drop (* i -1) list)
                                       (make-list (* i -1) :initial-element 0))
                               (append (make-list i :initial-element 0)
                                       (butlast list i))))))

(defun apply-annotations (asm annotations &key smooth widen flat bin loc)
  "Apply annotations to the genome of ASM.
Keyword argument SMOOTH will `smooth' the annotations with a Gaussian
blur.  Keyword argument WIDEN will `widen' the annotations.  If both
SMOOTH and WIDEN are given, widening is applied first.  Keyword
argument FLAT will produce flat annotations simply indicating if the
instruction was executed or not. LOCS indicates that annotations are
organized by line of code in the ASM file, and are not addresses."
  (when loc
    (assert (= (length annotations) (length (genome asm))) (annotations)
            "Annotations length ~d != genome length ~d"
            (length annotations) (length (genome asm))))
  (when widen
    (assert (numberp widen) (widen)
            "widen arg to `apply-annotations' isn't numeric: ~a"
            widen))
  (setf (genome asm)
        (mapcar
         (lambda (ann element)
           (cons (cons :annotation ann) element))
         ((lambda (raw)
            ((lambda (raw) (if smooth (smooth raw) raw))
             (if widen
                 (widen raw widen)
                 raw)))
          (mapcar (if flat
                      (lambda (ann) (if ann 1 0))
                      (lambda (ann) (or ann 0)))
                  (if loc
                      annotations
                      (genome-anns asm annotations :bin bin))))
         (genome asm))))


;;; Annotated lighter weight range representation
(defclass ann-range (asm-range)
  ((anns    :initarg :anns    :accessor anns    :initform nil)
   (ann-ref :initarg :ann-ref :accessor ann-ref :initform nil)))

(defun to-ann-range (asm)
  (with-slots (flags linker genome) asm
    (make-instance 'ann-range
      :flags flags
      :linker linker
      :genome (list (cons 0 (1- (length genome))))
      :reference (coerce (lines asm) 'vector)
      :anns (list (cons 0 (1- (length genome))))
      :ann-ref (coerce (mapcar {aget :annotation} genome) 'vector))))

(defmethod annotations ((asm asm)) (mapcar {aget :annotation} (genome asm)))

(defmethod annotations ((ann ann-range))
  (mapcan (lambda-bind ((start . end))
            (mapcar {aref (ann-ref ann)}
                    (loop :for i :from start :to end :collect i)))
          (anns ann)))

(defmethod copy ((asm ann-range))
  (with-slots (genome linker flags reference anns ann-ref) asm
    (make-instance (type-of asm)
      :fitness (fitness asm)
      :genome (copy-tree genome)
      :linker linker
      :flags flags
      :reference reference
      :anns anns
      :ann-ref ann-ref)))


;;; Main optimize executable
(defun optimize (args)
  (in-package :optimize)
  (let ((help "Usage: ~a TEST-SCRIPT ASM-FILE [OPTIONS...]
 Optimize the assembly code in ASM-FILE against TEST-SCRIPT.

TEST-SCRIPT:
  Command line used to evaluate executables.  If the test
  script contains the substring \"~~a\" it will be replaced
  with the name of the executable, otherwise the executable
  will be appended to the end of the test script.  The script
  should return a single numeric fitness or multiple metrics
  in csv format.

ASM-FILE:
  A text file of assembler code or (if using the \".store\"
  extension) a serialized assembly software object.

Options:
 -c,--cross-chance NUM - crossover chance (default 2/3)
 -C,--config FILE ------ read configuration from FILE
 -e,--eval SEXP -------- evaluate S-expression SEXP
 -E,--max-error NUM ---- maximum allowed error (default 0)
 -f,--fit-evals NUM ---- max number of fitness evaluations
                         default: 2^18
 -F,--fit-func FLAGS --- fitness function
                         default: output of TEST-SCRIPT
 --fit-pred PRED ------- fitness predicate (#'< or #'>)
                         default: #'<, minimize fit-func
 -g,--gc-size ---------- ~a
                         default: ~:d
 -l,--linker LINKER ---- linker to use
 -L,--lflags FLAGS ----- flags to use when linking
 -m,--mut-rate NUM ----- mutation rate (default 1)
 -M,--mcmc ------------- run MCMC search instead of GP
 -p,--pop-size NUM ----- population size
                         default: 2^9
 -P,--period NUM ------- period (in evals) of checkpoints
                         default: max-evals/(2^10)
 -r,--res-dir DIR ------ save results to dir
                         default: program.opt/
 -R,--rep REP ---------- use REP program representation
                         asm, light, or range (default)
 -s,--evict-size NUM --- eviction tournament size
                         default: 2
 -t,--threads NUM ------ number of threads
 -T,--tourny-size NUM -- selection tournament size
                         default: 1 (i.e., random selection)
 -v,--verbose NUM ------ verbosity level 0-4
 -V,--version ---------- print version and exit
 -w,--work-dir DIR ----- use an sh-runner/work directory~%")
        (self (pop args))
        (version
         (format nil
          #+ccl "optimize version ~a using Clozure Common Lisp (CCL)~%"
          #+sbcl "optimize version ~a using Steel Bank Common Lisp (SBCL)~%"
          *git-version*))
        (do-evolve
            (lambda ()
              #+ccl (note 1 "check in") ;; for ccl `*terminal-io*' sharing
              (evolve #'test :max-evals *evals*
                      :period *period*
                      :period-fn (lambda () (mapc #'funcall *checkpoint-funcs*)))))
        (*rep* 'range) linker flags)
    (setf *note-level* 1)
    ;; Set default GC threshold
    #+ccl (ccl:set-lisp-heap-gc-threshold (expt 2 30))
    #+sbcl (setf (sb-ext:bytes-consed-between-gcs) (expt 2 24))

    ;; check command line arguments
    (when (or (<= (length args) 2)
              (string= (subseq (car args) 0 2) "-h")
              (string= (subseq (car args) 0 3) "--h")
              (string= (car args) "-V")
              (string= (car args) "--version"))
      (if (or (string= (car args) "-V")
              (string= (car args) "--version"))
          (progn (format t version) (quit))
          (format t help self
                  #+ccl "space left after a full GC pass"
                  #+sbcl "bytes consed between every GC pass"
                  #+ccl (ccl:lisp-heap-gc-threshold)
                  #+sbcl (sb-ext:bytes-consed-between-gcs)))
      (quit))

    ;; process mandatory command line arguments
    (setf *script* (let ((script (pop args)))
                     (if (scan "~a" script)
                         script
                         (format nil "~a ~~a" script)))
          *path*   (pop args))

    (when (string= (pathname-type (pathname *path*)) "store")
      (setf *orig* (restore *path*)))

    ;; process command line options
    (getopts
     ("-c" "--cross-chance" (setf *cross-chance* (parse-number (pop args))))
     ("-C" "--config"    (load (pop args)))
     ("-e" "--eval"      (eval (read-from-string (pop args))))
     ("-E" "--max-err"   (setf *max-err* (read-from-string (pop args))))
     ("-f" "--fit-evals" (setf *evals* (parse-integer (pop args))))
     ("-F" "--fit-func" (setf *fitness-function* (read-from-string (pop args))))
     (nil "--fit-pred" (setf *fitness-predicate* (read-from-string (pop args))))
     ("-g" "--gc-size"
           #+ccl  (ccl:set-lisp-heap-gc-threshold (parse-integer (pop args)))
           #+sbcl (setf (sb-ext:bytes-consed-between-gcs)
                        (parse-integer (pop args))))
     ("-l" "--linker"    (setf linker (pop args)))
     ("-L" "--lflags"    (setf flags (split-sequence #\Space (pop args)
                                                     :remove-empty-subseqs t)))
     ("-m" "--mut-rate"  (setf *mut-rate* (parse-number (pop args))))
     ("-M" "--mcmc"      (setf *mcmc* t))
     ("-p" "--pop-size"  (setf *max-population-size*
                               (parse-integer (pop args))))
     ("-P" "--period"    (setf *period* (parse-integer (pop args))))
     ("-r" "--res-dir"   (setf *res-dir*
                               (let ((dir (pop args)))
                                 (pathname-directory
                                  (if (string= (subseq dir (1- (length dir)))
                                               "/")
                                      dir (concatenate 'string dir "/"))))))
     ("-R" "--rep"       (setf *rep* (intern (string-upcase (pop args)))))
     ("-s" "--evict-size" (setf *tournament-eviction-size*
                                (parse-integer (pop args))))
     ("-t" "--threads"   (setf *threads* (parse-integer (pop args))))
     ("-T" "--tourny-size" (setf *tournament-size* (parse-integer (pop args))))
     ("-v" "--verbose"   (let ((lvl (parse-integer (pop args))))
                           (when (>= lvl 4) (setf *shell-debug* t))
                           (setf *note-level* lvl)))
     ("-w" "--work-dir"  (setf *work-dir* (pop args))))
    (unless *period* (setf *period* (ceiling (/ *evals* (expt 2 10)))))
    (unless *orig*
      (setf *orig* (from-file (make-instance (case *rep*
                                               (asm 'asm-perf)
                                               (light 'asm-light)
                                               (range 'asm-range)))
                              *path*)))
    (when linker (setf (linker *orig*) linker))
    (when flags  (setf (flags  *orig*) flags))

    ;; directories for results saving and logging
    (unless (ensure-directories-exist (make-pathname :directory *res-dir*))
      (throw-error "Unable to make result directory `~a'.~%" *res-dir*))
    (let ((log-name (make-pathname :directory *res-dir*
                                   :name "optimize"
                                   :type "log")))
      (if (probe-file log-name)
          (throw-error "Log file already exists ~S.~%" log-name)
          (push
           #+ccl (open log-name :direction :output :sharing :external)
           #-ccl (open log-name :direction :output)
           *note-out*)))

    ;; write out version information
    (note 1 version)

    ;; write out configuration parameters
    (note 1 "Parameters:~%~S~%"
          (mapcar (lambda (param)
                    (cons param (eval param)))
                  '(*path*
                    *script*
                    *fitness-function*
                    *fitness-predicate*
                    (linker *orig*)
                    (flags *orig*)
                    *threads*
                    *mcmc*
                    *mut-rate*
                    *cross-chance*
                    *evals*
                    *tournament-size*
                    *tournament-eviction-size*
                    *work-dir*
                    *max-err*
                    *max-population-size*
                    *period*
                    *rep*
                    *note-level*
                    *res-dir*)))

    ;; Run optimization
    (unless (fitness *orig*)
      (note 1 "Evaluating the original.")
      (setf (fitness *orig*) (test *orig*)))
    (note 1 "~S~%" `((:orig-stats   . ,(stats *orig*))
                     (:orig-fitness . ,(fitness *orig*))))

    ;; sanity check
    (when (= (fitness *orig*) (worst))
      (throw-error "Original program has no fitness!"))

    ;; save the original
    (store *orig* (make-pathname :directory *res-dir*
                                 :name "original"
                                 :type "store"))

    ;; actually perform the optimization
    (if *mcmc*
        (progn
          (when (> *threads* 1)
            (throw-error "Multi-threaded MCMC is not supported."))
          (note 1 "Starting MCMC search")
          (setf *population* (list *orig*))
          (mcmc *orig* #'test :max-evals *evals*
                :every-fn
                (lambda (new)
                  (when (funcall *fitness-predicate* new (car *population*))
                    (setf *population* (list new))))
                :period *period*
                :period-fn (lambda () (mapc #'funcall *checkpoint-funcs*))))
        (progn
          ;; populate population
          (unless *population* ;; don't re-populate an existing population
            (note 1 "Building the Population")
            #+ccl (ccl:egc nil)
            (setf *population* (loop :for n :below *max-population-size*
                                  :collect (copy *orig*)))
            #+ccl (ccl:egc t))

          ;; run optimization
          (note 1 "Kicking off ~a optimization threads" *threads*)

          (let (threads
;;; see http://ccl.clozure.com/ccl-documentation.html#Background-Terminal-Input
                #+ccl
                (*default-special-bindings*
                 (list (cons '*terminal-io*
                             (make-two-way-stream
                              (make-string-input-stream "y")
                              (two-way-stream-output-stream
                               *terminal-io*))))))
            ;; kick off optimization threads
            (loop :for n :below *threads* :do
               (push (make-thread do-evolve :name (format nil "opt-~d" n))
                     threads))
            ;; wait for all threads to return
            (mapc #'join-thread threads))))

    ;; finish up
    (mapc #'funcall *final-funcs*)
    (note 1 "done after ~a fitness evaluations~%" *fitness-evals*)
    (note 1 "results saved in ~a~%" *res-dir*)
    (close (pop *note-out*))))
