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

(defmethod (setf slot-value-using-class)
    (new-value (class persistent-metaclass) (instance persistent-object) (slot-def indexed-slot-definition))
  "Update indices when writing an indexed slot.  Make around method to ensure a single transaction
   for write + index update"
  (let ((sc (get-con instance)))
    (ensure-transaction (:store-controller sc)
      (update-slot-index sc class instance slot-def new-value)
      (call-next-method))))

(defmethod slot-makunbound-using-class ((class persistent-metaclass) (instance persistent-object) (slot-def indexed-slot-definition))
  "Removes the slot value from the database."
  (let ((sc (get-con instance))
	(oid (oid instance)))
    (ensure-transaction (:store-controller sc)
      (let ((idx (get-slot-def-index slot-def sc))
	    (old-value (when (slot-boundp-using-class class instance slot-def)
			 (slot-value-using-class class instance slot-def))))
	(unless idx
	  (setf idx (ensure-slot-def-index slot-def sc)))
	(when old-value 
	  (remove-kv-pair old-value oid idx)))
      (call-next-method))))

(defun update-slot-index (sc class instance slot-def new-value)
  "Update an index value when written"
  (let ((oid (oid instance)))
    (ensure-transaction (:store-controller sc)
      (let ((idx (get-slot-def-index slot-def sc))
	    (old-value (when (slot-boundp-using-class class instance slot-def)
			 (slot-value-using-class class instance slot-def))))
	(unless idx
	  (setf idx (ensure-slot-def-index slot-def sc)))
	(when old-value 
  	  (remove-kv-pair old-value oid idx))
	(setf (get-value new-value idx) oid)))))

(defun get-controller-index (slot-def sc)
  "Get the slot-def's index from the store"
  (let* ((master (controller-index-table sc))
	 (base (indexed-slot-base slot-def))
	 (name (slot-definition-name slot-def)))
    (get-value (cons base name) master)))

(defun ensure-slot-def-index (slot-def sc)
  "If a slot's index does not exist, create it"
  (aif (get-controller-index slot-def sc)
       (progn (add-slot-def-index it slot-def sc) it)
       (let ((new-idx (make-dup-btree sc)))
	 (add-slot-index sc new-idx (indexed-slot-base slot-def) (slot-definition-name slot-def))
	 (add-slot-def-index new-idx slot-def sc)
	 new-idx)))

(defmethod add-slot-index ((sc store-controller) new-index class-name index-name)
  (setf (get-value (cons class-name index-name) (controller-index-table sc))
	new-index))

(defmethod drop-slot-index ((sc store-controller) class-name index-name)
  (remove-kv (cons class-name index-name) (controller-index-table sc)))

;; =================================
;;   INTERNAL ACCESS TO INDICES
;; =================================

(defmethod find-inverted-index ((class symbol) slot &key (null-on-fail nil) (sc *store-controller*))
  (find-inverted-index (find-class class) slot :null-on-fail null-on-fail :sc sc))

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
	  (setf idx (ensure-slot-def-index slot-def sc)))
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
    (multiple-value-bind (oid found?)
	(get-value value it)
      (when found?
	(controller-recreate-instance (get-con it) oid)))))

(defmethod get-instance-by-value ((class symbol) slot-name value)
 (get-instance-by-value (find-class class) slot-name value))

(defmethod get-instances-by-range ((class symbol) slot-name start end)
  (get-instances-by-range (find-class class) slot-name start end))

(defmethod get-instances-by-range ((class persistent-metaclass) idx-name start end)
  (declare (type (or number symbol string null) start end)
	   (type symbol idx-name))
  (map-inverted-index #'identity2 class idx-name :start start :end end :collect t))

(defun drop-instances (instances &key (sc *store-controller*) (txn-size 500))
  "Removes a list of persistent objects from all class indices
   and unbinds any slot values"
  (when instances
    (assert (consp instances))
    (do-subsets (subset txn-size instances)
      (ensure-transaction (:store-controller sc)
	(mapc (lambda (instance)
		(drop-pobject instance))
	      subset)))))

;; ======================
;;    USER MAPPING API 
;; ======================

(defun map-class (fn class &key collect oids (sc *store-controller*))
  "Perform a map operation over all instances of class.  Takes a
   function of one argument, a class instance."
  (flet ((map-fn (cidx pcidx oid)
	   (declare (ignore cidx pcidx))
	   (funcall fn (controller-recreate-instance sc oid))))
    (declare (dynamic-extent map-fn))
    (let* ((classname (if (symbolp class) class (class-name class)))
	   (db-schemas (get-db-schemas sc classname))
	   (schema-ids (if db-schemas 
			   (mapcar #'schema-id (reverse db-schemas))
			   (list (lookup-schema sc (if (symbolp class) (find-class class) class))))))
;;      (dump-schema-status sc classname)
      (loop for schema-id in schema-ids appending
	   (map-index (if oids fn #'map-fn)
		      (controller-instance-class-index sc)
		      :value schema-id
		      :collect collect)))))

(defun map-inverted-index (fn class index &rest args &key start end (value nil value-p) from-end collect oids)
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
   to true.  If :value is used, :from-end is ignored

   The 'oids' argument passes the oid of the instance to the provided
   function instead of the recreated instance."
  (declare (dynamic-extent args)
	   (ignorable args))
  (let* ((index (if (symbolp index)
		    (find-inverted-index class index)
		    index))
	 (sc (get-con index)))
    (flet ((map-obj (value oid)
	     (funcall fn value (controller-recreate-instance sc oid))))
      (if value-p
	  (map-btree (if oids fn #'map-obj) index :value value :collect collect)
	  (map-btree (if oids fn #'map-obj) index :start start :end end :from-end from-end :collect collect)))))




