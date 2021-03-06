;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;
;;; bdb-slots.lisp -- Implement the slot protocol
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

(in-package :db-bdb)

;;
;; Persistent slot protocol implementation
;;

(declaim #-elephant-without-optimize (optimize (speed 3) (safety 0) (debug 0) (space 0)))

(defmethod persistent-slot-reader ((sc bdb-store-controller) instance name &optional oids-only)
  (declare (ignore oids-only))
  (ensure-transaction (:store-controller sc)
    (with-buffer-streams (key-buf value-buf)
      (buffer-write-fixnum32 (the fixnum (oid instance)) key-buf)
      (serialize name key-buf sc)
      (let ((buf (db-get-key-buffered (controller-db sc)
                                      key-buf value-buf
                                      :transaction (my-current-transaction sc))))
        (if buf (deserialize buf sc)
            (slot-unbound (class-of instance) instance name))))))

(defmethod persistent-slot-writer ((sc bdb-store-controller) new-value instance name)
  (ensure-transaction (:store-controller sc)
    (with-buffer-streams (key-buf value-buf)
      (buffer-write-fixnum32 (oid instance) key-buf)
      (serialize name key-buf sc)
      (serialize new-value value-buf sc)
      (db-put-buffered (controller-db sc)
                       key-buf value-buf
                       :transaction (my-current-transaction sc))
      new-value)))

(defmethod persistent-slot-boundp ((sc bdb-store-controller) instance name)
  (ensure-transaction (:store-controller sc)
    (with-buffer-streams (key-buf value-buf)
      (buffer-write-fixnum32 (oid instance) key-buf)
      (serialize name key-buf sc)
      (let ((buf (db-get-key-buffered (controller-db sc)
                                      key-buf value-buf
                                      :transaction (my-current-transaction sc))))
        (if buf t nil)))))

(defmethod persistent-slot-makunbound ((sc bdb-store-controller) instance name)
  (ensure-transaction (:store-controller sc)
    (with-buffer-streams (key-buf)
      (buffer-write-fixnum32 (oid instance) key-buf)
      (serialize name key-buf sc)
      (db-delete-buffered (controller-db sc) key-buf
                          :transaction (my-current-transaction sc)))))

