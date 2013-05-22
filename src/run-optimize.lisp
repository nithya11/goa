;;; Code:
(load "src/optimize.lisp")
(in-package :optimize)

(defvar *help* "Usage: ~a program benchmark [OPTIONS...]
 Optimize a benchmark program

Options:
 -c,--config FILE ------ read configuration from FILE
 -l,--linker LINKER ---- linker to use
 -f,--flags FLAGS ------ flags to use when linking
 -t,--threads NUM ------ number of threads
 -w,--work-dir DIR ----- use an sh-runner/work directory
 -r,--res-dir DIR ------ save results to dir
                         default: program.opt/
 -E,--max-error NUM ---- maximum allowed error
 -m,--model NAME ------- model name
 -T,--tourny-size NUM -- tournament size
                         default: 4
 -e,--max-evals NUM ---- max number of fitness evals
                         default: 2^18
 -p,--pop-size NUM ----- population size
                         default: 2^9
 -P,--period NUM ------- period (in evals) of checkpoints
                         default: max-evals/(2^10)
 -v,--verbose NUM ------ verbosity level 0-4~%")

(defun throw-error (&rest args)
  (apply #'note 0 args)
  (sb-ext:exit :code 1))

(defmacro getopts (&rest forms)
  (let ((arg (gensym)))
    `(loop :for ,arg = (pop args) :while ,arg :do
        (cond
          ,@(mapcar (lambda-bind ((short long . body))
                      `((or (string= ,arg ,short) (string= ,arg ,long)) ,@body))
                    forms)))))

(defvar *checkpoint-func* #'checkpoint "Function to record checkpoints.")

(defun do-optimize ()
  (evolve #'test :max-evals *evals*
          :period *period* :period-func *checkpoint-func*))

(setf *note-level* 1)

(defun main (args)
  (flet ((arg-pop () (pop args)))
    (let ((bin-path (arg-pop)))

      ;; check command line arguments
      (when (or (< (length args) 2)
                (string= (subseq (car args) 0 2) "-h")
                (string= (subseq (car args) 0 3) "--h"))
        (format t *help* bin-path)
        (sb-ext:exit :code 1))

      ;; process command line arguments
      (setf
       *path* (arg-pop)
       *benchmark* (arg-pop)
       *orig* (from-file (make-instance 'asm-perf) *path*)
       *res-dir* (append (pathname-directory *path*)
                         (list (concatenate 'string
                                 (pathname-name *path*) ".opt"))))

      ;; process command line options
      (getopts
       ("-c" "--config"    (load (arg-pop)))
       ("-l" "--linker"    (setf (linker *orig*) (arg-pop)))
       ("-f" "--flags"     (setf (flags *orig*) (list (arg-pop))))
       ("-t" "--threads"   (setf *threads* (parse-integer (arg-pop))))
       ("-T" "--tourny-size" (setf *tournament-size* (parse-integer (arg-pop))))
       ("-e" "--max-evals" (setf *evals* (parse-integer (arg-pop))))
       ("-w" "--work-dir"  (setf *work-dir* (arg-pop)))
       ("-E" "--max-err"   (setf *max-err* (read-from-string (arg-pop))))
       ("-p" "--pop-size"  (setf *max-population-size*
                                 (parse-integer (arg-pop))))
       ("-m" "--model"     (setf *model* (intern (string-upcase (arg-pop)))))
       ("-P" "--period"    (setf *period* (parse-integer (arg-pop))))
       ("-v" "--verb"      (let ((lvl (parse-integer (arg-pop))))
                             (when (= lvl 4) (setf *shell-debug* t))
                             (setf *note-level* lvl)))
       ("-r" "--res-dir"   (setf *res-dir*
                                 (let ((dir (arg-pop)))
                                   (pathname-directory
                                    (if (string= (subseq dir (1- (length dir)))
                                                 "/")
                                        dir (concatenate 'string dir "/")))))))
      (unless *period* (setf *period* (ceiling (/ *evals* (expt 2 10)))))

      ;; directories for results saving and logging
      (unless (ensure-directories-exist (make-pathname :directory *res-dir*))
        (throw-error "Unable to make result directory `~a'.~%" *res-dir*))
      (let ((log-name (make-pathname :directory *res-dir*
                                     :name "optimize"
                                     :type "log")))
        (if (probe-file log-name)
            (throw-error "Log file already exists ~S.~%" log-name)
            (push (open log-name :direction :output) *note-out*)))

      (unless *model*
        (setf *model* (case (arch)
                        (:intel 'intel-sandybridge-energy-model)
                        (:amd   'amd-opteron-energy-model))))
      (when (symbolp *model*) (setf *model* (eval *model*)))

      ;; write out configuration parameters
      (note 1 "Parameters:~%~S~%"
            (mapcar (lambda (param)
                      (cons param (eval param)))
                    '(*path*
                      *benchmark*
                      (linker *orig*)
                      (flags *orig*)
                      *threads*
                      *tournament-size*
                      *evals*
                      *work-dir*
                      *max-err*
                      *max-population-size*
                      *model*
                      *period*
                      *note-level*
                      *res-dir*)))

      ;; Run optimization
      (unless (fitness *orig*)
        (note 1 "Evaluating the original.")
        (setf (fitness *orig*) (test *orig*)))
      (note 1 "~S~%" `((:orig-stats   . ,(stats *orig*))
                       (:orig-fitness . ,(fitness *orig*))))

      ;; sanity check
      (when (= (fitness *orig*) infinity)
        (throw-error "Original program has no fitness!"))

      ;; populate population
      (unless *population* ;; only if it hasn't already been populated
        (note 1 "Building the Population")
        (setf *population* (loop :for n :below *max-population-size*
                              :collect (copy *orig*))))

      ;; run optimization
      (note 1 "Kicking off ~a optimization threads" *threads*)

      (let (threads)
        ;; kick off optimization threads
        (loop :for n :below *threads* :do
           (push (sb-thread:make-thread #'do-optimize) threads))
        ;; wait for all threads to return
        (mapc #'sb-thread:join-thread threads))

      (sb-ext:gc :force t)
      (store *population* (make-pathname :directory *res-dir*
                                         :name "final-pop"
                                         :type "store"))

      (note 1 "done after ~a fitness evaluations~%" *fitness-evals*)
      (note 1 "results saved in ~a~%" *res-dir*)
      (close (pop *note-out*)))))
