;;; neutral.lisp --- generate neutral versions of blackscholes
(require :software-evolution)
(in-package :software-evolution)
(mapc (lambda (pkg) (require pkg) (use-package pkg))
      (list :cl-ppcre :curry-compose-reader-macros))
(eval-when (:compile-toplevel :load-toplevel :execute)
  (enable-curry-compose-reader-macros))

(defvar infinity
  #+sbcl
  SB-EXT:DOUBLE-FLOAT-POSITIVE-INFINITY
  #-(or sbcl)
  (error "must specify a positive infinity value"))

(defvar *work-dir* "sh-runner/work/")

(defvar *num-tests* 5 "Number of tests in `*test*'.")

(defvar *script* "../../bin/host-test"
  "Script used to evaluate variants.
Note: This does not follow the normal test script format but rather it;
1. takes the path to a .s asm file
2. copies that file to a VM
3. runs the resulting program in Graphite in the VM
4. returns the full set of Graphite debug information")

(defclass graphite-asm (asm)
  ((stats :accessor stats :initform :not-run)))

(defvar *orig* (from-file (make-instance 'graphite-asm)
                          "data/blackscholes.m4.s"))

(defun parse-stdout (stdout)
  "Parse the Graphite output of host-test."
  (remove
      nil
      (mapcar
       (lambda (line)
         (let ((fields (split-sequence #\Space (regex-replace-all "" line "")
                                       :remove-empty-subseqs t)))
           (unless (null fields)
             (cons (make-keyword (string-upcase (car fields)))
                   (mapcar (lambda (c) (or (ignore-errors (parse-number c)) c))
                           (cdr fields))))))
       (remove-if (lambda (line) (or (scan "hooks" line)
                                (scan "warning" line)
                                (scan "spawn_master" line)))
                  (split-sequence #\Newline stdout :remove-empty-subseqs t)))))

(defun group-stats (stats &aux group results)
  (dolist (row stats (reverse (cons (reverse group) results)))
    (case (car row)
      ((:tile-summary :core-model-summary :network-summary :cache-summary)
       (setf group nil))
      ((:cache-l1-i :cache-l2 :cache-l1-d :dram-performance-model-summary)
       (when group (push (reverse group) results))
       (setf group row))
      (:network-model
       (when group
         (push (reverse group) results)
         (setf group nil))
       (push row group))
      (t
       (if group
           (push row group)
           (push row results))))))

(defun energy-delay-product (stats)
  (flet ((energy (group)
           (+ (reduce #'+ (cdr (assoc :static-power group)))
              (reduce #'+ (cdr (assoc :dynamic-energy group))))))
    (*
     ;; Runtime
     (reduce #'+ (aget :completion-time stats))
     ;; Energy
     (reduce #'+ (mapcar #'energy
                         (cons
                          (aget '(:network-model 2) stats :test #'tree-equal)
                          (mapcar {aget _ stats}
                                  '(:cache-l1-i :cache-l1-d :cache-l2
                                    :dram-performance-model-summary))))))))

(defun test (variant)
  (case (stats variant)
    (:not-run (with-temp-file-of (asm "s") (genome-string variant)
                (incf *fitness-evals*)
                (multiple-value-bind (stdout stderr errno)
                    (shell "~a blackscholes asm ~a" *script* asm)
                  (declare (ignorable stderr))
                  (if (zerop errno)
                      (setf (stats variant) (group-stats (parse-stdout stdout)))
                      (setf (stats variant) :failed))
                  (test variant))))
    (:failed infinity)
    (t (energy-delay-product (stats variant)))))

(defvar *mutate-chance* nil
  "Chance that each new individual will be mutated.")

(setf ;; Evolutionary parameters
 *max-population-size* (expt 2 8)
 *tournament-size*     2
 *fitness-predicate*   #'<
 *mutate-chance*       0.2
 *cross-chance*        0.2)

(defun tourny (&optional (predicate *fitness-predicate*) &aux competitors)
  "Select an individual from *POPULATION* with a tournament of size NUMBER."
  (assert *population* (*population*) "Empty population.")
  (extremum (dotimes (no *tournament-size* competitors)
              (declare (ignorable no))
              (push (random-elt *population*) competitors))
            predicate :key #'test))

(defun mutant ()
  "Generate a new mutant from a *POPULATION*."
  (let ((copy (copy (tourny #'test))))
    (if (< (random 1.0) *mutate-chance*)
        (mutate copy)
        copy)))

(defun crossed ()
  "Generate a new individual from *POPULATION* using crossover."
  (crossover (tourny) (tourny)))

(defun new-individual ()
  "Generate a new individual from *POPULATION*."
  (if (< (random 1.0) *cross-chance*) (crossed) (mutant)))

(defun evolver ()
  (loop :while *running* :do
     (push (new-individual) *population*)
     (loop :while (> (length *population*) *max-population-size*) :do
        (let ((loser (nth (random (length *population*)) *population*)))
          (setf *population* (remove loser *population* :count 1))))))

#+run
(progn
  (setf *population* (repeatedly *max-population-size* (copy *orig*)))
  (loop :for i :upto 24 :do
     (sb-thread:make-thread #'evolver :name (format nil "opt-~d" i))))

(defun opt-threads ()
  (remove-if-not (lambda (thread)
                   (string= "opt" (subseq (sb-thread:thread-name thread) 0 3)))
                 (sb-thread:list-all-threads)))
