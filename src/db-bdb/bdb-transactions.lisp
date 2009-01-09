;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; bdb-transactions.lisp -- Transaction support for Berkeley DB
;;; 
;;; By Ian Eslick, <ieslick common-lisp net>
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

(in-package :db-bdb)

(declaim #-elephant-without-optimize (optimize (speed 3))
	 #+elephant-without-optimize (optimize (speed 1) (safety 3) (debug 3)))

(defmethod execute-transaction ((sc bdb-store-controller) txn-fn
				&key 
				transaction parent environment
				(retries *default-retries*)
				degree-2 read-uncommitted txn-nosync 
				txn-nowait txn-sync (snapshot elephant::*default-mvcc*)
				inhibit-rollback-fn)
  (declare (ignorable transaction))
  (let ((env (if environment environment (controller-environment sc))))
    (loop 
       for count fixnum from 0 to retries
       for success of-type boolean = nil
       do
       (let ((txn (db-transaction-begin env
					:parent (if parent parent +NULL-VOID+)
					:degree-2 degree-2
					:read-uncommitted read-uncommitted
					:txn-nosync txn-nosync
					:txn-nowait txn-nowait
					:txn-sync txn-sync
					:snapshot snapshot)))
	 (declare (type pointer-void txn))
	 (let (result)
	   (let ((*current-transaction* (make-transaction-record sc txn *current-transaction*))
		 (*store-controller* sc))
	     (declare (special *current-transaction* *store-controller*))
	     (catch 'transaction
	       (unwind-protect
		    (progn
		      ;; Run body, capture any conditions
		      (handler-case
			  (setf result (multiple-value-list (funcall txn-fn)))
			(condition (c)
			  (if (and inhibit-rollback-fn (funcall inhibit-rollback-fn c))
			      ;; Commit if non-local exit is OK
			      (progn
				(db-transaction-commit txn 
						       :txn-nosync txn-nosync
						       :txn-sync txn-sync)
				(setq success t))
			      (setq success c))
			  (throw 'transaction nil)))
		      ;; Commit on regular exit
		      (db-transaction-commit txn 
					     :txn-nosync txn-nosync
					     :txn-sync txn-sync)
		      (setq success t))
		 ;; If unhandled non-local exit or commit failure: abort
		 (unless success
		   (db-transaction-abort txn)))))
	   ;; A positive success is either a legitimate value or a signal
	   (cond ((eq success t)
		  (return (values-list result)))
		 (success 
		  (break)
		  (if (subtypep (type-of success) 'error)
		      (error success) ;; contains an error condition (top-level debugger)
		      (signal success))) ;; contains a normal condition (no debugger)
		 (t nil))))
       finally (cerror "Retry transaction again?"
		       'transaction-retry-count-exceeded
		       :format-control "Transaction exceeded the ~A retries limit"
		       :format-arguments (list retries)
		       :count retries))))
		       
    
(defmethod controller-start-transaction ((sc bdb-store-controller)
					 &key 
					 parent
					 txn-nosync
					 txn-nowait
					 txn-sync
					 read-uncommitted
					 degree-2
					 (snapshot elephant::*default-mvcc*)
					 &allow-other-keys)
  (assert (not *current-transaction*))
  (db-transaction-begin (controller-environment sc)
			:parent (if parent parent +NULL-VOID+)
			:txn-nosync txn-nosync
			:txn-nowait txn-nowait
			:txn-sync txn-sync
			:read-uncommitted read-uncommitted
			:degree-2 degree-2
			:snapshot snapshot))
			

(defmethod controller-commit-transaction ((sc bdb-store-controller) transaction 
					  &key txn-nosync txn-sync &allow-other-keys)
  (assert (not *current-transaction*))
  (db-transaction-commit transaction :txn-nosync txn-nosync :txn-sync txn-sync))

(defmethod controller-abort-transaction ((sc bdb-store-controller) transaction &key &allow-other-keys)
  (assert (not *current-transaction*))
  (db-transaction-abort transaction))

