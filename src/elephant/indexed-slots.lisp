;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; slots.lisp -- persistent slot accesses
;;; 
;;; part of
;;;
;;; Elephant: an object-oriented database for Common Lisp
;;;
;;; Original Copyright (c) 2004 by Andrew Blumberg and Ben Lee
;;; <ablumberg@common-lisp.net> <blee@common-lisp.net>
;;;
;;; Portions Copyright (c) 2005-2007 by Robert Read and Ian Eslick
;;; <rread common-lisp net> <ieslick common-lisp net>
;;;
;;; Elephant users are granted the rights to distribute and use this software
;;; as governed by the terms of the Lisp Lesser GNU Public License
;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;

(in-package :elephant)

;; ======================================================
;; Indexed slot accesses
;; ======================================================

(defmethod (setf slot-value-using-class) :around
    (new-value (class persistent-metaclass) (instance persistent-object) (slot-def indexed-slot-definition))
  "Update indices when writing an indexed slot.  Make around method to ensure a single transaction
   for write + index update"
  (let ((sc (get-con instance))
	(oid (oid instance)))
    (ensure-transaction (:store-controller sc)
      (let ((idx (get-slot-def-index slot-def sc))
	    (old-value (when (slot-boundp-using-class class instance slot-def)
			 (slot-value-using-class class instance slot-def))))
	(unless idx
	  (setf idx (initialize-slot-def-index slot-def sc)))
	(when old-value 
	  (remove-kv-pair old-value oid idx))
	(setf (get-value new-value idx) oid))
      (call-next-method))))

    
(defun initialize-slot-def-index (slot-def sc)
  (let* ((master (controller-index-table sc))
	 (idx-ref (cons (indexed-slot-base slot-def) (slot-definition-name slot-def)) ))
    (aif (get-value idx-ref master)
	 (progn (add-slot-def-index it slot-def sc) it)
	 (let ((new-idx (make-dup-btree sc)))
	   (setf (get-value idx-ref master) new-idx)
	   (add-slot-def-index new-idx slot-def sc)
	   new-idx))))

(defmethod remove-kv-pair (key value (dbt dup-btree))
  "Yuck!  Is there a more efficient way to update an index than:
   Read, delete, write?  At least the read caches the delete page?"
  (let ((sc (get-con dbt)))
    (ensure-transaction (:store-controller sc)
      (with-btree-cursor (cur dbt)
	(multiple-value-bind (exists? k v)
	    (cursor-set-range cur key)
	  (declare (ignore k))
  	  (if (and exists? (eq v value))
	      (cursor-delete cur)
	      (loop do
		 (multiple-value-bind (exists? k v)
		     (cursor-next cur)
		   (declare (ignore k))
		   (when (not exists?)
		     (error "Cannot remove key/value ~A/~A from dup-btree ~A: not found"
			    key value dbt))
		   (when (eq v value)
		     (cursor-delete cur)
		     (return value))))))))))


;; =================================
;;   INTERNAL ACCESS TO INDICES
;; =================================

(defmethod find-inverted-index ((class symbol) slot &key (null-on-fail nil))
  (find-inverted-index (find-class class) slot :null-on-fail null-on-fail))

(defmethod find-inverted-index ((class persistent-metaclass) slot &key (null-on-fail nil) (sc *store-controller*))
  (ensure-finalized class)
  (flet ((assert-error ()
	   (when null-on-fail (return-from find-inverted-index nil))
	   (cerror "Return null and continue?"
		   "Inverted slot index ~A not found for class ~A with indexed slots: ~A" 
		   slot (class-name class) (indexed-slot-names class))))
    (let ((slot-def (find-slot-def-by-name class slot)))
      (when (or (not slot-def) 
		(not (eq (type-of slot-def) 'indexed-effective-slot-definition)))
	(assert-error))
      (let ((idx (get-slot-def-index slot-def sc)))
	(unless idx
	  (setf idx (initialize-slot-def-index slot-def sc)))
	idx))))

(defun ensure-finalized (class)
  (when (not (class-finalized-p class))
    (when *warn-on-manual-class-finalization*
      (warn "Manually finalizing class ~A" (class-name class)))
    (finalize-inheritance class)))

;; =================
;;   USER SET API 
;; =================

(defgeneric get-instances-by-class (persistent-metaclass)
  (:documentation "Retrieve all instances from the class index as a list of objects"))

(defgeneric get-instance-by-value (persistent-metaclass slot-name value)
  (:documentation "Retrieve instances from a slot index by value.  Will return only the first
                  instance if there are duplicates."))

(defgeneric get-instances-by-value (persistent-metaclass slot-name value)
  (:documentation "Returns a list of all instances where the slot value is equal to value."))

(defgeneric get-instances-by-range (persistent-metaclass slot-name start end)
  (:documentation "Returns a list of all instances that match
                   values between start and end.  An argument of
                   nil to start or end indicates, respectively,
                   the lowest or highest value in the index"))


(defun identity2 (k v)
  (declare (ignore k))
  v)

(defun identity3 (k v pk)
  (declare (ignore k pk))
  v)

(defmethod get-instances-by-class ((class symbol))
  (get-instances-by-class (find-class class)))

(defmethod get-instances-by-class ((class persistent-metaclass))
  (map-class #'identity class :collect t))

(defmethod get-instances-by-value ((class symbol) slot-name value)
  (get-instances-by-value (find-class class) slot-name value))

(defmethod get-instances-by-value ((class persistent-metaclass) slot-name value)
  (declare (type (or string symbol) slot-name))
  (map-inverted-index #'identity2 class slot-name :value value :collect t))

(defmethod get-instance-by-value ((class persistent-metaclass) slot-name value)
  (awhen (find-inverted-index class slot-name)
    (get-value value it)))

(defmethod get-instance-by-value ((class symbol) slot-name value)
 (get-instance-by-value (find-class class) slot-name value))

(defmethod get-instances-by-range ((class symbol) slot-name start end)
  (get-instances-by-range (find-class class) slot-name start end))

(defmethod get-instances-by-range ((class persistent-metaclass) idx-name start end)
  (declare (type (or number symbol string null) start end)
	   (type symbol idx-name))
  (map-inverted-index #'identity2 class idx-name :start start :end end :collect t))

(defun drop-instances (instances &key (sc *store-controller*))
  "Removes a list of persistent objects from all class indices
   and unbinds any slot values"
  (when instances
    (assert (consp instances))
    (do-subsets (subset 500 instances)
      (ensure-transaction (:store-controller sc)
	(mapc (lambda (instance)
		(drop-pobject instance)
		(remove-kv (oid instance) (find-class-index (class-of instance))))
	      subset)))))

;; ======================
;;    USER MAPPING API 
;; ======================

(defun map-class (fn class &key collect (sc *store-controller*))
  "Perform a map operation over all instances of class.  Takes a
   function of one argument, a class instance"
  (flet ((map-fn (cidx pcidx oid)
	   (declare (ignore cidx pcidx))
	   (funcall fn (controller-recreate-instance sc oid))))
    (map-index #'map-fn (controller-instance-class-index sc)
	       :value (schema-id (get-controller-schema (if (symbolp class) (find-class class) class) sc))
	       :collect collect)))

(defun map-inverted-index (fn class index &rest args &key start end (value nil value-p) from-end collect)
  "map-inverted-index maps a function of two variables, taking key
   and instance, over a subset of class instances in the order
   defined by the index.  Specify the class and index by quoted
   name.  The index may be a slot index or a derived index.

   To map only a subset of key-value pairs, specify the range
   using the :start and :end keywords; all elements greater than
   or equal to :start and less than or equal to :end will be
   traversed regardless of whether the start or end value is in
   the index.  

   Use nil in the place of start or end to specify the first
   element or last element, respectively.  

   To map a single value, iff it exists, use the :value keyword.
   This is the only way to travers all nil values.

   To map from :end to :start in descending order, set :from-end
   to true.  If :value is used, :from-end is ignored"
  (declare (dynamic-extent args)
	   (ignorable args))
  (let* ((index (if (symbolp index)
		    (find-inverted-index class index)
		    index)))
    (if value-p
	(map-dup-btree fn index :value value :collect collect)
	(map-dup-btree fn index :start start :end end :from-end from-end :collect collect))))

;; ===================
;;   USER CURSOR API
;; ===================

(defgeneric make-inverted-cursor (class name)
  (:documentation "Define a cursor on the inverted (slot or derived) index"))

(defgeneric make-class-cursor (class)
  (:documentation "Define a cursor over all class instances"))


(defmethod make-inverted-cursor ((class persistent-metaclass) name)
  (make-cursor (find-inverted-index class name)))

(defmethod make-inverted-cursor ((class symbol) name)
  (make-cursor (find-inverted-index class name)))

(defmacro with-inverted-cursor ((var class name) &body body)
  "Bind the var argument to an inverted cursor on the index
   specified the provided class and index name"
  `(let ((,var (make-inverted-cursor ,class ,name)))
     (unwind-protect (progn ,@body)
       (cursor-close ,var))))

(defmethod make-class-cursor ((class persistent-metaclass))
  (make-cursor (find-class-index class)))

(defmethod make-class-cursor ((class symbol))
  (make-cursor (find-class-index class)))

(defmacro with-class-cursor ((var class) &body body)
  "Bind the var argument in the body to a class cursor on the
   index specified the provided class or class name"
  `(let ((,var (make-class-cursor ,class)))
     (unwind-protect (progn ,@body)
       (cursor-close ,var))))



