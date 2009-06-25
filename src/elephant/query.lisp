;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; query.lisp -- Implement conjunctive syntax as example for elephant query interface
;;; 
;;; By Ian S. Eslick, <ieslick common-lisp net>
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

(in-package :elephant)

(defparameter *string-relation-functions*
  `((< . ,#'string<)
    (<= . ,#'string<=)
    (> . ,#'string>)
    (>= . ,#'string>=)
    (= . ,#'equal)
    (!= . ,(lambda (x y) (not (equal x y))))))

(defparameter *number-relation-functions*
  `((< . ,#'<)
    (<= . , #'<=)
    (> . ,#'>)
    (>= . ,#'>=)
    (= . ,#'=)
    (!= . ,#'(lambda (x y) (not (= x y))))))

(defparameter *generic-relation-functions* 
  `((< . ,#'lisp-compare<)
    (<= . ,#'lisp-compare<=)
    (> . ,#'(lambda (x y)
	      (not (lisp-compare<= x y))))
    (>= . ,#'(lambda (x y)
	       (not (lisp-compare< x y))))
    (= . ,#'(lambda (x y)
	      (lisp-compare-equal x y)))
    (!= . ,#'(lambda (x y)
	       (not (lisp-compare-equal x y))))))

(defun relation-string-function (rel)
  (cdr (assoc rel *string-relation-functions*)))

(defun relation-number-function (rel)
  (cdr (assoc rel *number-relation-functions*)))

(defun relation-generic-function (rel)
  (cdr (assoc rel *generic-relation-functions*)))

(defun test-relation (rel ival tvals)
  (assert (or (and (numberp ival) (numberp (first tvals)))
	      (and (stringp ival) (stringp (first tvals)))))
  (typecase ival
    (string (funcall (relation-string-function rel) ival (first tvals)))
    (number (funcall (relation-number-function rel) ival (first tvals)))
    (t (funcall (relation-generic-function rel) ival (first tvals)))))
      
(defun get-query-instances (constraints)
  "Get a list of instances according to the query constraints"
  (declare (dynamic-extent constraints))
  (let ((list nil))
    (flet ((collect (inst)
	     (push inst list)))
      (map-class-query #'collect constraints))))

(defun map-class-query (fn constraints)
  "Map instances using the query constaints to filter objects, exploiting
   slot indices (for last query) and stack allocated test closures.  This is
   a minimally optimizing version that uses the first index it finds, and 
   then does a nested loop join on the rest of the parameters."
  (declare (dynamic-extent constraints))
  (assert (not (null constraints)))
  (destructuring-bind (class slot relation &rest values) (first constraints)
    (flet ((filter-by-relation (inst)
	     (when (test-relation relation (slot-value inst slot) values)
	       (funcall fn inst))))
      (declare (dynamic-extent #'filter-by-relation))
      (if (null (cdr constraints))
	  (if (find-inverted-index class slot)
	      (if (= (length values) 1)
		  (progn
		    (map-inverted-index fn class slot (first values) (first values))
		    (map-inverted-index fn class slot (first values) (second values))))
	      (map-class #'filter-by-relation class))
	  (map-class-query #'filter-by-relation (cdr constraints))))))
       
;;
;; Conjunctions of indices
;;

;;(defun map-classes (fn classes)
;;  (map-index-list fn (mapcar #'find-class-index classes)))

;;(defun map-index-list (fn indices)
;;  (dolist (index indices)
;;    (map-index fn index)))

(defparameter comparison-2ops '(< > >= <= = string= string< string> string<= string>=))

(defun query-select (fn expr)
  (destructuring-bind (select vars where) expr
    (declare (ignore select))
    (let ((bindings (make-bindings vars))
	  (classname (second (first vars)))
	  (constraints (list (cons 'and (cdr where)))))
      (flet ((filter-instance (inst)
	       (reset-bindings inst bindings)
	       (interpret-constraints fn constraints bindings)))
	(declare (dynamic-extent #'filter-instance))
	(map-class #'filter-instance classname)))))

(defun make-bindings (vars)
  (mapcar #'(lambda (def) (cons (first def) nil)) vars))

(defun satisfied-bindings-p (bindings)
  (every #'(lambda (binding)
	     (and (consp binding)
		  (cdr binding)))
;;		  (not (null (second binding)))))
	 bindings))

(defun reset-bindings (inst bindings)
  (setf (cdr (car bindings)) inst)
  (mapcar #'(lambda (binding) (setf (cdr binding) nil)) (cdr bindings)))

(defun var-type (var vars)
  (awhen (get-assoc-value var vars)
    (car it)))

(defun cdrs (list)
  (mapcar #'cdr list))

(defun match-symbol-name (sym1 sym2)
  (equal (symbol-name sym1)
	 (symbol-name sym2)))

;;
;; Instance-level constraint interpreter
;;

(defun interpret-constraints (fn constraints bindings)
  (if (null constraints) 
      (if (satisfied-bindings-p bindings)
	  (apply fn (cdrs bindings))
	  t)
      (let ((constraint (car constraints)))
	(cond ((and-expr-p constraint)
	       (interpret-and-constraint fn constraint (rest constraints) bindings))
	      ((or-expr-p constraint)
	       (interpret-or-constraint fn constraint (rest constraints) bindings))
	      ((member (car constraint) comparison-2ops) ;; simplify here
	       (let ((rval1 (reference-value (second constraint) bindings))
		     (rval2 (reference-value (third constraint) bindings)))
		 (cond ((query-variable? rval1)
			(let ((pair (assoc rval1 bindings)))
			  (if (consp pair)
			      (setf (cdr pair) rval2)
			      (error "Variable ~A not found in bindings: ~A" rval2 bindings))))
		       ((query-variable? rval2)
			(let ((pair (assoc rval2 bindings)))
			  (if (consp pair)
			      (setf (cdr pair) rval1)
			      (error "Variable ~A not found in bindings: ~A" rval2 bindings))))
		       (t (when (funcall (symbol-function (first constraint)) rval1 rval2)
			    (interpret-constraints fn (rest constraints) bindings))))))
	      (t (error "Expression: ~A unrecognized~%" constraint))))))

;;    (when (recurse constraints)
;;      (return-from filter-by-clauses (apply fn (cdrs bindings))))))

(defun interpret-single-constraint (fn constraint bindings)
  (interpret-constraints fn (list constraint) bindings))

(defun comparison-constraint-p (constraint)
  (member (car constraint) comparison-2ops))


(defun and-expr-p (expr)
  (match-symbol-name (car expr) :and))

(defun interpret-and-constraint (fn constraint rest bindings)
  (when (every #'(lambda (c) (interpret-single-constraint fn c bindings)) (rest constraint))
    (interpret-constraints fn rest bindings)))

(defun or-expr-p (expr)
  (match-symbol-name (car expr) :or))

(defun interpret-or-constraint (fn constraint rest bindings)
  (when (some #'(lambda (c) (interpret-single-constraint fn c bindings)) (rest constraint))
    (interpret-constraints fn rest bindings)))

(defun query-variable? (symbol)
  (and (symbolp symbol)
       (eq #\? (char (symbol-name symbol) 0))))

(defun get-assoc-value (value alist)
  (let ((pair (assoc value alist)))
    (when (consp pair) 
      (cdr pair))))

(defun reference-value (expr bindings)
  (cond ((null expr)
	 (error "Reference expression should not be null"))
	((not (consp expr))
	 (let ((val (get-assoc-value expr bindings)))
	   (if (null val)
	       expr
	       val)))
	(t (funcall (symbol-function (first expr))
		    (reference-value (second expr) bindings)))))


;; Some hacks for doing join-sorts where we extract an ordered set
;; of objects


(defun sort-tuples (seq order-by &optional (key-fn #'car))
  "Orders elements in the sequence using values returned by key-fn"
  (if order-by
      (stable-sort seq
		   (if (equalp (cdr order-by) :asc)
		       #'elephant::lisp-compare<
		       (lambda (a b)
			 (not (elephant::lisp-compare<= a b))))
		   :key #'key-fn)
      seq))

(defun map-tuple-range (seq range &optional (map-fn #'cdr))
  "Returns a list of elements from tuples returned by map-fn 
   on the sequence elements that are within the range on seq"
  (typecase seq
    (list (loop
	     for i from 0 upto (- (cdr range) (car range))
	     for tuple in (nthcdr (car range) seq) 
	     until (null tuple) 
	     collect
	       (funcall map-fn tuple)))
    (vector (loop
	       for i from (car range) upto (min (cdr range) (1- (length seq)))
	       collect
		 (funcall map-fn (aref seq i))))))


#|

(query
 :select ( (person person) (school school) )
 :with ( (sport sport) )
 :where (and (member sport (sports person))
	     (= school (school person))
	     (has-sport school)))

(do-query
    :return '((person person) (school school))
    :with '((sport sport))
    :where '(and ...))

(select ((?a person) (?b school))
  :with-vars (min max)
  :where (and (or (> (age ?a) min) (< (age ?a) max))
	      (= (school (father ?a)) ?b)
	      (= (school ?a) ?b)
	      (string> (name ?b) "Frederick Elementary"))
  :applying (lambda (x y) (print (list x y)))
  :returning)

Rewrites: (> age min) (< age max) => (range age min max)
Reorders: Link between ?a ?b must occur before ?b by itself in and/or
         Extract balanced inner (school ?p) ?s if wrapped in other calls and move up
Order-by: choose those with index, 




(:join (?a ?b)
  (:merge (?a) (:select (?a) (> (age ?a) (cons 10)))
	  (?a) (:select (?a) (< (age ?a) (var x))))
  (:join (?a ?b)
	 (:select (?a ?b) (= (father ?a) ?b))
	 (:join (:select (?b) (= (name ?b)))
		(:select (?a) (= (name (school ?a)) "Frederick Elementary")))))

;; Construct a query graph

(person age father school name)
(school name)

(for person 10 < age < 20 ;; index
     (= (name (father a)) "Fred")
     (= (name (school a)) "Fredirck ELementary")
     (return (list a (father a))))

|#
