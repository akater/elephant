;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; db-prevalence/clprev-controller.lisp -- Prevalence data store controller
;;; 
;;; Initial version 1/20/2009 by Ian Eslick
;;; 
;;; part of
;;;
;;; Elephant: an object-oriented database for Common Lisp
;;;
;;; Copyright (c) 2009 by Ian Eslick
;;; <ieslick common-lisp net>
;;;
;;; Elephant users are granted the rights to distribute and use this software
;;; as governed by the terms of the Lisp Lesser GNU Public License
;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;

(in-package :db-clp)

(defvar *loading* nil
  "Special behavior during snapshot restoration")

(defclass clp-controller (store-controller)
  ((prev-ctrl :accessor controller-prevalence-system)))

(defmethod flush-instance-cache ((sc clp-controller))
  nil)

;;
;; Backend registry
;;

(defun clp-test-and-construct (spec)
  (if (clp-store-spec-p spec)
      (make-instance 'clp-controller :spec spec)
      (error (format nil "Unrecognized database specifier: ~A" spec))))

(eval-when (:compile-toplevel :load-toplevel)
  (register-data-store-con-init :clp 'clp-test-and-construct))

(defun clp-store-spec-p (spec)
  (and (eq (first spec) :clp)
       (typecase (second spec)
	 (pathname t)
	 (string t)
	 (otherwise nil))))

;;
;; Override some of the prevalence behavior
;;  to deal with bootstrapping issues
;;

(defclass clp-prevalence-system (guarded-prevalence-system)
  ())

(defmethod restore ((system clp-prevalence-system))
;;  (unless *loading* 
    (call-next-method))


(defmethod snapshot ((system clp-prevalence-system))
;;  (with-open-file (out root-snapshot :direction :output
;;		       :if-does-not-exist :supersede)
  (call-next-method))

(defmethod execute ((system clp-prevalence-system) (transaction transaction))
  (if *loading*
      (apply (cl-prevalence::get-function transaction)
	     (cons system (cl-prevalence::get-args transaction)))
      (call-next-method)))


;;
;; Open and close the controller
;;

(defmethod open-controller ((sc clp-controller) &key &allow-other-keys)
  (let ((*store-controller* sc)
	(*loading* t)
	(*load-table* (make-hash-table)))
    (declare (special *store-controller* *loading* *load-table*))
    ;; Restore core data structures
    (let ((scprev 
	   (make-prevalence-system (second (controller-spec sc))
				   :prevalence-system-class
				   'clp-prevalence-system)))
      (setf (controller-prevalence-system sc) scprev)
      (initialize-serializer sc)
      (if (not (get-root-object scprev :cid-counter))
	  (progn
	    ;; Version
	    (set-database-version sc)
	    ;; IDs
	    (unless (get-root-object scprev :oid-counter)
	      (setf (get-root-object scprev :oid-counter) 3))
	    (unless (get-root-object scprev :cid-counter)
	      (setf (get-root-object scprev :cid-counter) 4))
	    ;; Slot values (we can do better than this! Need MOP upgrade though)
	    (setf (get-root-object scprev :slots) (make-slot-proxy))
	    (setf (get-root-object scprev :trees) (make-hash-table))

	    ;; Schema table (save the root tree)
	    (setf (slot-value sc 'schema-table)
		  (make-instance 'clp-indexed-btree :from-oid 3 :sc sc))
	    (setf (get-root-object scprev :schema-table)
		  (tree (slot-value sc 'schema-table)))
	    ;; Instance table
	    (setf (slot-value sc 'instance-table)
		  (make-instance 'clp-indexed-btree :from-oid 2 :sc sc))
	    (setf (get-root-object scprev :instance-table)
		  (tree (slot-value sc 'instance-table)))
	    ;; Index table
	    (setf (slot-value sc 'index-table)
		  (make-instance 'clp-btree :from-oid 1 :sc sc))
	    (setf (get-root-object scprev :index-table)
		  (tree (slot-value sc 'index-table)))
	    ;; Root
	    (setf (slot-value sc 'root)
		  (make-instance 'clp-btree :from-oid 0 :sc sc))
	    (setf (get-root-object scprev :root)
		  (tree (slot-value sc 'root)))
	    (snapshot scprev)
	    sc)

	  (progn
	    ;; Schema table cid->schema obj
	    (setf (slot-value sc 'schema-table)
		  (ele::controller-recreate-instance sc 3 'clp-indexed-btree))
	    (setf (tree (slot-value sc 'schema-table))
		  (get-root-object scprev :schema-table))
	    
	    ;; Instance table
	    (setf (slot-value sc 'instance-table)
		  (ele::controller-recreate-instance sc 2 'clp-indexed-btree))
	    (setf (tree (slot-value sc 'schema-table))
		  (get-root-object scprev :schema-table))

	    ;; Index table
	    (setf (slot-value sc 'index-table)
		  (ele::controller-recreate-instance sc 1 'clp-btree))
	    (setf (tree (slot-value sc 'index-table))
		  (get-root-object scprev :index-table))

	    ;; Root
	    (setf (slot-value sc 'root)
		  (ele::controller-recreate-instance sc 0 'clp-btree))
	    (setf (tree (slot-value sc 'root))
		  (get-root-object scprev :root))

	    (maphash (lambda (oid inst)
;;		       (when (> oid 3)
		       (ele::recreate-instance inst :from-oid oid :sc sc))
		     *load-table*)
	    )))))

(defmacro with-prev-store ((sc) &body body)
  `(let* ((*store-controller* ,sc)
	  (*clp* (controller-prevalence-system *store-controller*)))
     (declare (special *clp* *store-controller*))
     ,@body))

(defmethod close-controller ((sc clp-controller))
  (with-prev-store (sc)
    (snapshot *clp*)))

;;(defmethod initialize-serializer ((sc clp-controller))
;;  "Flag an error on a direct use as we don't use the default
;;   elephant serializer strategy"
;;  (setf (controller-serialize sc) nil)
;;  (setf (controller-deserialize sc) nil))

;;
;; ID's
;;

(defmethod next-oid ((sc clp-controller))
  "Must be used only inside a clp transaction"
  (with-prev-store (sc)
    (setf (get-root-object *clp* :oid-counter)
	  (incf (get-root-object *clp* :oid-counter)))))

(defmethod next-cid ((sc clp-controller))
  "Must be used only inside a clp transaction"
  (with-prev-store (sc)
    (setf (get-root-object *clp* :cid-counter)
	  (incf (get-root-object *clp* :cid-counter)))))

;;
;; Caching & Schema Evolution
;;

;; NOTE: No need to cache objects...
;;       Need to use class indexes to find objects; no need to store
;;       schemas or do schema evolution?

;;(defmethod cache-instance ((sc clp-controller) obj)
;;  obj)

;;(defmethod get-cached-instance ((sc clp-controller) oid)
;;  (get-value (ele::controller-instance-table sc) oid)

;;
;; "Root" objects
;;
  
(defmethod oid->schema-id (oid (sc clp-controller))
  (if (< oid 6)
      (case oid
	(0 1)
	(1 1)
	(2 3)
	(3 3)
	(4 4)
	(5 4))
      (call-next-method)))

(defmethod default-class-id (type (sc clp-controller))
  (ecase type
    (clp-btree 1)
    (clp-dup-btree 2)
    (clp-indexed-btree 3)
    (clp-btree-index 4)))

(defmethod default-class-id-type (cid (sc clp-controller))
  (case cid
    (1 'clp-btree)
    (2 'clp-dup-btree)
    (3 'clp-indexed-btree)
    (4 'clp-btree-index)))

(defmethod reserved-oid-p ((sc clp-controller) oid)
  (< oid 4))

;;
;; Versions
;;

(defmethod database-version ((sc clp-controller))
  (with-prev-store (sc)
    (get-root-object *clp* :version)))

(defun set-database-version (sc)
  (with-prev-store (sc)
    (setf (get-root-object *clp* :version) *elephant-code-version*)))


;;
;; Transactions
;;

(defmethod elephant::execute-transaction ((sc clp-controller) txn-fn &key)
  "We need to use this to wrap a txn context around primitives to
   aggregate updates into one txn object, call and disk sync"
  (funcall txn-fn))
	   
(defmacro internal-transaction (sc fn &body args)
  `(with-prev-store (,sc)
     (execute *clp* (make-transaction ,fn ,@args))))

;;
;; Slots
;;

;; NOTE: Need to globally protect all reads!
;; NOTE: How to override the default persistent slot access protocol here so
;;       we can use slot storage here?

(defmethod persistent-slot-reader ((sc clp-controller) instance name &optional oids-only)
  (declare (ignore oids-only))
  (with-prev-store (sc)
    (let ((proxy (get-root-object *clp* :slots)))
      (multiple-value-bind (value found?) 
	  (proxy-slot-value proxy (oid instance) name)
	(if found? value
	    (slot-unbound (class-of instance) instance name))))))

(defmethod persistent-slot-writer ((sc clp-controller) new-value instance name)
  (internal-transaction sc 'tx-write-object-slot
    (oid instance) name new-value))

(defmethod persistent-slot-boundp ((sc clp-controller) instance name)
  (with-prev-store (sc)
    (let ((proxy (get-root-object *clp* :slots)))
      (proxy-slot-boundp proxy (oid instance) name))))

(defmethod persistent-slot-makunbound ((sc clp-controller) instance name)
  (internal-transaction sc 'tx-unbind-slot
    (oid instance) name))


;; slot txn fns

(defmethod tx-write-object-slot (clp oid name value)
  "Insert/update key-value"
  (let ((proxy (get-root-object clp :slots)))
    (proxy-set-slot-value proxy oid name value)))

(defmethod tx-unbind-slot (clp oid name)
  "Remove key-value"
  (let ((proxy (get-root-object clp :slots)))
    (proxy-slot-makunbound proxy oid name)))


;;
;; Aggregates
;;


;;
;; Save copies of the proxy tree for any collection
;;

(defun save-proxy-tree (btree)
  "Make sure we record the proxy trees"
  (let* ((pc (controller-prevalence-system (get-con btree)))
	 (tree-hash (get-root-object pc :trees)))
    (setf (gethash (oid btree) tree-hash)
	  (tree btree))))

(defun load-proxy-tree (btree)
  (let* ((pc (controller-prevalence-system (get-con btree)))
	 (tree-hash (get-root-object pc :trees)))
    (setf (tree btree)
	  (gethash (oid btree) tree-hash))))

(defun drop-proxy-tree (btree)
  (let* ((pc (controller-prevalence-system (get-con btree)))
	 (tree-hash (get-root-object pc :trees)))
    (remhash (oid btree) tree-hash)))

;;
;; Default btree
;;

(defclass clp-btree (btree)
  ((tree :accessor tree 
	 :initarg :tree
	 :initform (make-btree-proxy))))

(defmethod initialize-instance :after ((btree clp-btree) &rest args)
  (declare (ignore args))
  (save-proxy-tree btree))

(defmethod drop-instance ((btree clp-btree))
  (drop-proxy-tree btree)
  (call-next-method))

(defmethod ele::recreate-instance :after ((btree clp-btree) &rest args)
  (declare (ignore args))
  (load-proxy-tree btree))

(defmethod build-btree ((sc clp-controller))
  (make-instance 'clp-btree))

;; NOTE: These need to be transactionally protected for
;;       consistency!
(defmethod get-value (key (bt clp-btree))
  (with-slots (tree) bt
    (get-item tree key)))

(defmethod existsp (key (bt clp-btree))
  (with-slots (tree) bt
    (exists tree key)))

(defmethod (setf get-value) (value key (bt clp-btree))
  (internal-transaction (get-con bt) 'tx-set-bt-value
    bt key value))

(defun tx-set-bt-value (clp bt key value)
  (declare (ignore clp))
  (unique-insert-item (tree bt) key value))

(defmethod remove-kv (key (bt clp-btree))
  (internal-transaction (get-con bt) 'tx-rem-bt-value
    bt key))

(defun tx-rem-bt-value (clp bt key)
  (declare (ignore clp))
  (remove-kv key (tree bt)))

   
(defmacro done-mapping-p ()
  `(or (and value (not (lisp-compare-equal key value)))
       (and from-end start (lisp-compare< key start))
       (and (not from-end) end 
	    (lisp-compare< end key))))

(defmethod map-btree (fn (bt clp-btree)
		      &key start end value from-end collect
		      &allow-other-keys)
  (let ((elts nil)
	(proxy (tree bt)))
    (labels ((collector (key value)
	       (push (funcall fn key value) elts)))
      (handler-case
	  (let ((node (get-start-node proxy value start end from-end)))
	    (loop 
	       (if (or (null node) (containers::node-empty-p node)) 
		   (return nil)
		   (destructuring-bind (key . val) (containers:element node)
		     (when (done-mapping-p)
		       (return nil))
		     (if collect
			 (funcall #'collector key val)
			 (funcall fn key val))
		     (setf node
			   (if from-end
			       (containers:predecessor proxy node)
			       (containers:successor proxy node)))))))
	(containers:element-not-found-error () nil))
      (nreverse elts))))

(defun get-start-node (proxy value start end from-end &optional (test 'proxy-equal))
  (cond (value (proxy-find-node proxy value nil test))
	(from-end
	 (if end
	     (proxy-find-node proxy end t test)
	     (containers::last-node proxy)))
	(start
	 (proxy-find-node proxy start nil test))
	(t (containers::first-node proxy))))

;;(defun get-dup-start-node (proxy value start end from-end)
;;  (get-start-node proxy value start end from-end 'dup-proxy-equal))


;; Indexed btree

(defclass clp-indexed-btree (indexed-btree clp-btree)
  ((indices :accessor indices :initarg :indices))
  (:metaclass persistent-metaclass))

(defmethod initialize-instance :after ((obj clp-indexed-btree) &rest initargs)
  (declare (ignore initargs))
  (setf (indices obj) (make-hash-table)))

(defmethod build-indexed-btree ((sc clp-controller))
  (make-instance 'clp-indexed-btree :sc sc))

(defmethod build-btree-index ((sc clp-controller) &key primary key-form)
  (make-instance 'clp-btree-index :primary primary :key-form key-form :sc sc))

(defmethod elephant::add-index ((bt clp-indexed-btree) &key index-name key-form (populate t))
  (if (and (not (null index-name))
	   (symbolp index-name)
	   (or (symbolp key-form) (listp key-form)))
      (internal-transaction (get-con bt) 'tx-add-index
	bt index-name key-form populate)
      (error "Invalid index initargs!")))

(defun tx-add-index (clp bt index-name key-form populate)
  (declare (ignore clp))
  (let ((index (build-btree-index (get-con bt) :primary bt :key-form key-form)))
    (setf (gethash index-name (indices bt)) index)
    (when populate (populate bt index))
    index))

;; Index management

(defmethod map-indices (fn (bt clp-indexed-btree))
  (maphash fn (indices bt)))
	
(defmethod get-index ((bt clp-indexed-btree) index-name)
  (gethash index-name (indices bt)))

(defmethod remove-index ((bt clp-indexed-btree) index-name)
  (internal-transaction (get-con bt) 'tx-remove-index
    bt index-name))

(defun tx-remove-index (clp bt index-name)
  (declare (ignore clp))
  (remhash index-name (indices bt)))

;; Updates

(defmethod (setf get-value) (value key (bt clp-indexed-btree))
  (internal-transaction (get-con bt) 'tx-set-indexed-value
    bt key value))

(defun tx-set-indexed-value (clp bt key value)
  (let ((old-value (get-value key bt)))
    (unique-insert-item (tree bt) key value)
    (labels ((update-index (name index)
	       (declare (ignore name))
	       (with-slots (tree key-fn) index
		 ;; Remove old value
		 (when old-value
		   (multiple-value-bind (index? old-skey)
		       (funcall key-fn index key old-value)
		     (when index?
		       (tx-remove-index-pair clp tree old-skey key))))
		 ;; Insert new one
		 (multiple-value-bind (index? skey)
		     (funcall key-fn index key value)
		   (when index? 
		     (insert-proxy-item tree skey key))))))
      (map-indices #'update-index bt))))

(defmethod populate ((bt clp-indexed-btree) index)
  "Should only be called at index creation time"
  (let ((key-fn (key-fn index))
	(ibtree (tree bt))
	(itree (tree index)))
    (labels ((popfn (element)
	       (destructuring-bind (key . value) element
		 (multiple-value-bind (index? skey)
		     (funcall key-fn index key value)
		   (when index? (insert-proxy-item itree skey key))))))
      (containers:iterate-elements ibtree #'popfn))))

(defmethod remove-kv (key (bt clp-indexed-btree))
  (internal-transaction (get-con bt) 
      'tx-remove-indexed-kv bt key))

(defun tx-remove-indexed-kv (clp bt key)
  (let ((old-value (get-value key bt)))
    (remove-kv key (tree bt))
    (labels ((update-index (name index)
	       (declare (ignore name))
	       (with-slots (tree key-fn) index
		 ;; Remove old value
		 (multiple-value-bind (index? old-skey)
		     (funcall key-fn index key old-value)
		   (when index?
		     (tx-remove-index-pair clp tree old-skey key))))))
      (map-indices #'update-index bt))
    (values old-value)))


;;
;; Btree index
;;

(defclass clp-btree-index (btree-index clp-btree)
  ((primary :accessor primary :initarg :primary)
   (tree :accessor tree :initarg :tree :initform (make-btree-proxy :duplicate-keys t)))
  (:metaclass persistent-metaclass))

;;(defmethod initialize-instance :after ((obj clp-btree-index) &rest initargs)
;;  (declare (ignore initargs)))
;;  (setf (tree obj) (make-btree-proxy :duplicate-keys t)))

(defmethod shared-initialize :after ((obj clp-btree-index) names &rest initargs)
  (declare (ignore names initargs))
  obj)

(defmethod get-value (key (idx clp-btree-index))
  "Returns one of any redundant values"
  (let ((key (get-primary-key key idx)))
    (when key
      (get-item (tree (primary idx)) key))))

(defmethod get-primary-key (key (idx clp-btree-index))
  (awhen (containers:find-successor-node (tree idx) (cons key nil))
    (let ((elt (containers:element it)))
      (when (lisp-compare-equal key (car elt))
	(values (cdr elt) t)))))

(defmethod remove-kv (key (idx clp-btree-index))
  (internal-transaction (get-con idx)
      'tx-index-remove-indexed-kv idx key))

(defun tx-index-remove-indexed-kv (clp idx ikey)
  (let ((pkey (get-primary-key ikey idx)))
    (unless pkey
      (error "Index out of sync with primary ~A for key ~A" (primary idx) ikey))
    (tx-remove-indexed-kv clp (primary idx) pkey)))

;;(defmethod remove-kv-pair (key value (idx clp-btree-index))
;;  (internal-transaction (get-con idx) 'tx-remove-index-pair
;;    idx key value))

(defun tx-remove-index-pair (clp tree key value)
  (declare (ignore clp))
  (remove-kv-pair key value tree))

(defmethod map-btree (fn (bt clp-btree-index)
		      &key start end value from-end collect
		      &allow-other-keys)
  (let ((elts nil)
	(proxy (tree bt)))
    (labels ((collector (key value)
	       (push (funcall fn key value) elts)))
      (handler-case
	  (let ((node (get-start-node proxy value start end from-end)))
	    (loop 
	       (if (or (null node) (containers::node-empty-p node)) (return nil)
		   (destructuring-bind (key . val) (containers:element node)
		     (when (done-mapping-p)
		       (return nil))
		     (if collect
			 (funcall #'collector key 
				  (get-item (tree (primary bt)) val))
			 (funcall fn key 
				  (get-item (tree (primary bt)) val)))
		     (setf node
			   (if from-end
			       (containers:predecessor proxy node)
			       (containers:successor proxy node)))))))
	(containers:element-not-found-error () nil))
      (nreverse elts))))

(defmethod map-index (fn (index clp-btree-index) &key start end value from-end collect &allow-other-keys)
  (let ((elts nil)
	(proxy (tree index))
	(parent-proxy (tree (primary index))))
    (labels ((collector (key pvalue pkey)
	       (push (funcall fn key pvalue pkey) elts)))
      (handler-case
	  (let ((node (get-start-node proxy value start end from-end)))
	    (loop do
		 (if (or (null node) (containers::node-empty-p node)) (return nil)
		     (destructuring-bind (key . val) (containers:element node)
		       (when (done-mapping-p)
			 (return nil))
		       (let ((pvalue (get-item parent-proxy val)))
			 (if collect
			     (funcall #'collector key pvalue val)
			     (funcall fn key pvalue val)))
		       (setf node
			     (if from-end
				 (containers:predecessor proxy node)
				 (containers:successor proxy node)))))))
	(containers:element-not-found-error () nil))
      (nreverse elts))))

;;
;; Duplicate btree
;;

(defclass clp-dup-btree (dup-btree clp-btree)
  ((tree :accessor tree :initarg :tree :initform (make-btree-proxy :duplicate-keys t))))

(defmethod build-dup-btree ((sc clp-controller))
  (make-instance 'clp-dup-btree :sc sc))
;;		 :tree (make-btree-proxy :duplicate-keys t)))

(defmethod get-value (key (bt clp-dup-btree))
  (awhen (containers:find-successor-node (tree bt) (cons key nil))
    (let ((elt (containers:element it)))
      (when (lisp-compare-equal key (car elt))
	(values (cdr elt) t)))))

(defmethod (setf get-value) (value key (bt clp-dup-btree))
  (internal-transaction (get-con bt) 'tx-set-dup-bt-value
    bt key value))

(defun tx-set-dup-bt-value (clp bt key value)
  (declare (ignore clp))
  (insert-proxy-item (tree bt) key value))

(defmethod remove-kv-pair (key value (bt clp-dup-btree))
  (internal-transaction (get-con bt) 'tx-remove-dup-pair
    bt key value))

(defun tx-remove-dup-pair (clp idx key value)
  (declare (ignore clp))
  (remove-kv-pair key value (tree idx)))

;; (defclass clp-pset (btree) ())

;;
;; Cursor API Stub
;;

(defclass clp-cursor (cursor)
  ((node :accessor cursor-node :initarg :initial-node :initform nil)))

(defmethod make-cursor ((bt clp-btree))
  (make-instance 'clp-cursor :btree bt))

(defmethod cursor-close ((cursor clp-cursor))
  (declare (ignore cursor)))

(defmethod cursor-duplicate ((cursor clp-cursor))
  (make-instance 'clp-cursor :oid (cursor-oid cursor)
                 :initialized-p (cursor-initialized-p cursor)
                 :initial-node (cursor-node cursor)))

(defmethod cursor-current ((cursor clp-cursor))
  (when (cursor-initialized-p cursor)
    (let ((kv-pair (containers:element (cursor-node cursor))))
      (values t (car kv-pair) (cdr kv-pair)))))

(defmethod cursor-first ((cursor clp-cursor))
  (let ((node (containers::first-node (tree (cursor-btree cursor)))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-last ((cursor clp-cursor))
  (let ((node (containers::last-node (tree (cursor-btree cursor)))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-next ((cursor clp-cursor))
  (let ((node (containers:successor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-prev ((cursor clp-cursor))
  (let ((node (containers:predecessor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-set ((cursor clp-cursor) key)
  (let ((node (containers:find-successor-node (tree (cursor-btree cursor))
                                    (cons key nil))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-set-range ((cursor clp-cursor) key)
  (let ((node (containers:find-successor-node (tree (cursor-btree cursor))
                                              (cons key nil))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-get-both ((cursor clp-cursor) key value)
  (let ((node (containers:find-successor-node (tree (cursor-btree cursor))
					      (cons key value))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-get-both-range ((cursor clp-cursor) key value)
  ;; the following isn't really correct... we want the node that is
  ;; greater or equal to value, not simply greater than value
  (let ((node (containers:find-successor-node (tree (cursor-btree cursor))
                                              (cons key value))))
    (if node
        (let ((kv-pair (containers:element node)))
          (setf (cursor-initialized-p cursor) t
                (cursor-node cursor) node)
          (values t (car kv-pair) (cdr kv-pair)))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-delete ((cursor clp-cursor))
  (when (cursor-initialized-p cursor)
    (containers:delete-node (cursor-btree cursor) (cursor-node cursor))
    (setf (cursor-initialized-p cursor) nil
          (cursor-node cursor) nil)))

(defmethod cursor-put ((cursor clp-cursor) value &key (key nil key-specified-p))
  (if key-specified-p
      (setf (containers:element
             (containers:find-successor-node (tree (cursor-btree cursor))
					     (cons key nil)))
            (cons key value))
      (if (cursor-initialized-p cursor)
          (setf (containers:element (cursor-node cursor)) (cons key value))
          (error "Can't put with uninitialized cursor!"))))

;;
;; Duplicate btree cursor ops
;;


(defclass clp-dup-cursor (clp-cursor)
  ())

(defmethod make-cursor ((bt clp-dup-btree))
  (make-instance 'clp-dup-cursor :btree bt))

(defmethod cursor-next-nodup ((cursor clp-dup-cursor))
  (let ((old-node (cursor-node cursor))
	(node (containers:successor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
        (let ((old-kv-pair (containers:element old-node))
	      (kv-pair (containers:element node)))
	  (setf (cursor-node cursor) node)
          (if (lisp-compare-equal (car kv-pair) (car old-kv-pair))
	      (cursor-next-nodup cursor)
	      (progn
		(setf (cursor-initialized-p cursor) t)
		(values t (car kv-pair) (cdr kv-pair)))))
        (setf (cursor-initialized-p cursor) nil))))

;;
;; Index cursor
;;

(defclass clp-index-cursor (clp-cursor)
  ())

(defmethod make-cursor ((bt clp-btree-index))
  (make-instance 'clp-index-cursor :btree bt))

(defun primary-cursor-value (idx-cursor pkey)
  (get-item (tree (primary (cursor-btree idx-cursor))) pkey))

(defmacro def-wrapped-cursor-method (name args &optional other)
  "Quick sugar to reduce copy & paste"
  `(defmethod ,name ((cursor clp-index-cursor) ,@args)
     (multiple-value-bind (found? key pkey)
	 ,(if other `(,other cursor ,@args)
	      '(call-next-method))
       (when found?
	 (values t key (primary-cursor-value cursor pkey) pkey)))))

(def-wrapped-cursor-method cursor-current ())
(def-wrapped-cursor-method cursor-pcurrent () cursor-current)
(def-wrapped-cursor-method cursor-first ())
(def-wrapped-cursor-method cursor-pfirst () cursor-first)
(def-wrapped-cursor-method cursor-last ())
(def-wrapped-cursor-method cursor-plast () cursor-last)
(def-wrapped-cursor-method cursor-next ())
(def-wrapped-cursor-method cursor-pnext () cursor-next)
(def-wrapped-cursor-method cursor-prev ())
(def-wrapped-cursor-method cursor-pprev () cursor-prev)
(def-wrapped-cursor-method cursor-set (key))
(def-wrapped-cursor-method cursor-pset (key) cursor-set)
(def-wrapped-cursor-method cursor-set-range (key))
(def-wrapped-cursor-method cursor-pset-range (key) cursor-set-range)
(def-wrapped-cursor-method cursor-get-both (key value))
(def-wrapped-cursor-method cursor-pget-both (key pkey) cursor-get-both)
(def-wrapped-cursor-method cursor-get-both-range (key value))
(def-wrapped-cursor-method cursor-pget-both-range (key pkey) cursor-get-both-range)

(defmethod cursor-delete ((cursor clp-index-cursor))
  (when (cursor-initialized-p cursor)
    (remove-kv (cdr (containers:element (cursor-node cursor)))
	       (primary (cursor-btree cursor)))
    (setf (cursor-initialized-p cursor) nil
          (cursor-node cursor) nil)))

(defmethod cursor-next-dup ((cursor clp-index-cursor))
  (let ((old-node (cursor-node cursor))
	(node (containers:successor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
	(let ((old-kv-pair (containers:element old-node))
	      (kv-pair (containers:element node)))
	  (if (lisp-compare-equal (car old-kv-pair) (car kv-pair))
	      (progn
		(setf (cursor-initialized-p cursor) t
		      (cursor-node cursor) node)
		(values t (car kv-pair) 
			(primary-cursor-value cursor (cdr kv-pair)) 
			(cdr kv-pair)))))
	      (setf (cursor-initialized-p cursor) nil))
	(setf (cursor-initialized-p cursor) nil)))

(defmethod cursor-pnext-dup ((cursor clp-index-cursor))
  (cursor-next-dup cursor))

(defmethod cursor-next-nodup ((cursor clp-index-cursor))
  (let ((old-node (cursor-node cursor))
	(node (containers:successor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
        (let ((old-kv-pair (containers:element old-node))
	      (kv-pair (containers:element node)))
	  (setf (cursor-node cursor) node)
          (if (lisp-compare-equal (car kv-pair) (car old-kv-pair))
	      (cursor-next-nodup cursor)
	      (progn
		(setf (cursor-initialized-p cursor) t)
		(values t (car kv-pair) 
			(primary-cursor-value cursor (cdr kv-pair)) 
			(cdr kv-pair)))))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-pnext-nodup ((cursor clp-index-cursor))
  (cursor-next-nodup cursor))


(defmethod cursor-prev-dup ((cursor clp-index-cursor))
  (let ((old-node (cursor-node cursor))
	(node (containers:predecessor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
	(let ((old-kv-pair (containers:element old-node))
	      (kv-pair (containers:element node)))
	  (if (lisp-compare-equal (car old-kv-pair) (car kv-pair))
	      (progn
		(setf (cursor-initialized-p cursor) t
		      (cursor-node cursor) node)
		(values t (car kv-pair) 
			(primary-cursor-value cursor (cdr kv-pair)) 
			(cdr kv-pair)))))
	      (setf (cursor-initialized-p cursor) nil)))	      
	(setf (cursor-initialized-p cursor) nil))

(defmethod cursor-pprev-dup ((cursor clp-index-cursor))
  (cursor-prev-dup cursor))


(defmethod cursor-prev-nodup ((cursor clp-index-cursor))
  (let ((old-node (cursor-node cursor))
	(node (containers:predecessor (tree (cursor-btree cursor)) (cursor-node cursor))))
    (if node
        (let ((old-kv-pair (containers:element old-node))
	      (kv-pair (containers:element node)))
	  (setf (cursor-node cursor) node)
          (if (lisp-compare-equal (car kv-pair) (car old-kv-pair))
	      (cursor-prev-nodup cursor)
	      (progn
		(setf (cursor-initialized-p cursor) t)
		(values t (car kv-pair) 
			(primary-cursor-value cursor (cdr kv-pair)) 
			(cdr kv-pair)))))
        (setf (cursor-initialized-p cursor) nil))))

(defmethod cursor-pprev-nodup ((cursor clp-index-cursor))
  (cursor-prev-nodup cursor))


