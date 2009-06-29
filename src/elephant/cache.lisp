;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; migrate.lisp -- Migrate between repositories
;;; 
;;; Initial version 8/26/2004 by Ben Lee
;;; <blee@common-lisp.net>
;;; 
;;; part of
;;;
;;; Elephant: an object-oriented database for Common Lisp
;;;
;;; Copyright (c) 2004 by Andrew Blumberg and Ben Lee
;;; <ablumberg@common-lisp.net> <blee@common-lisp.net>
;;;
;;; Portions Copyright (c) 2005-2007 by Robert Read and Ian Eslick
;;; <rread common-lisp net> <ieslick common-lisp net>
;;;
;;; Elephant users are granted the rights to distribute and use this software
;;; as governed by the terms of the Lisp Lesser GNU Public License
;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;

(in-package "ELEPHANT")

(defclass cacheable-persistent-object (persistent-object)
  ((pchecked-out :accessor pchecked-out-p :initform nil)
   (checked-out :accessor checked-out-p :initform nil :transient t))
  (:metaclass persistent-metaclass)
  (:documentation 
   "Adds a special value slot to store checkout state"))

(defmethod shared-initialize :around ((instance cacheable-persistent-object) slot-names &key make-cached-instance &allow-other-keys)
  ;; User asked us to start in cached mode?  Otherwise default to not.
  (setf (slot-value instance 'pchecked-out) make-cached-instance)
  (setf (slot-value instance 'checked-out) make-cached-instance)
  (call-next-method))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Portable value-weak hash-tables for the cache: when the
;;; values are collected, the entries (keys) should be
;;; flushed from the table too

(defun make-cache-table (&rest args)
  "Make a values-weak hash table: when a value has been
collected, so are the keys."
  #+(or cmu sbcl scl)
  (apply #'make-hash-table args)
  #+allegro
  (apply #'make-hash-table :values :weak args)
  #+lispworks
  (apply #'make-hash-table :weak-kind :value args)
  #+openmcl
  (apply #'make-hash-table :weak :value args)
  #-(or cmu sbcl scl allegro lispworks openmcl)
  (apply #'make-hash-table args)
  )

#+(and openmcl (not ccl))
(defclass cleanup-wrapper ()
  ((cleanup :accessor cleanup :initarg :cleanup)
   (value :accessor value :initarg :value)))

#+(and openmcl (not ccl))
(defmethod ccl:terminate ((c cleanup-wrapper))
  (funcall (cleanup c)))

(defun get-cache (key cache)
  "Get a value from a cache-table."
  #+(or cmu sbcl)
  (let ((val (gethash key cache)))
    (if val (values (weak-pointer-value val) t)
	(values nil nil)))
  #+(and openmcl (not ccl))
  (let ((wrap (gethash key cache)))
    (if wrap (values (value wrap) t)
	(values nil nil)))
  #-(or (and openmcl (not ccl)) cmu sbcl scl)
  (gethash key cache)
  )

(defun make-finalizer (key cache)
  (declare (ignorable key cache))
  #+(or cmu sbcl)
  (lambda () (remhash key cache))
  #+(or allegro (and openmcl (not ccl)))
  (lambda (obj) (declare (ignore obj)) (remhash key cache))
  #-(or cmu sbcl allegro (and openmcl (not ccl)))
  (lambda () nil)
  )

(defun remcache (key cache)
  (remhash key cache))

(defun setf-cache (key cache value)
  "Set a value in a cache-table."
  #+(or cmu sbcl)
  (let ((w (make-weak-pointer value)))
    (finalize value (make-finalizer key cache))
    (setf (gethash key cache) w)
    value)
  #+(and openmcl (not ccl-1.3))
  (let ((w (make-instance 'cleanup-wrapper :value value
			  :cleanup (make-finalizer key cache))))
    (ccl:terminate-when-unreachable w)
    (setf (gethash key cache) w)
    value)
  #+allegro
  (progn
    (excl:schedule-finalization value (make-finalizer key cache))
    (setf (gethash key cache) value))
  #-(or allegro (and openmcl (not ccl)) cmu sbcl)
  (setf (gethash key cache) value)
  )

(defsetf get-cache setf-cache)

(defun map-cache (fn cache)
  (with-hash-table-iterator (nextfn cache)
    (loop  
       (multiple-value-bind (valid? key value) (nextfn)
	 (when (not valid?)
	   (return-from map-cache))
	 (funcall fn key 
		  #+(or cmu sbcl) (weak-pointer-value value)
		  #+(and openmcl (not ccl)) (value value)
		  #-(or cmu sbcl (and openmcl (not ccl))) value)))))

(defun dump-cache (cache)
  (format t "Dumping cache: ~A~%" cache)
  (map-cache #'(lambda (k v) 
		 (format t "key: ~A / value: ~A~%" k v))
	     cache))
