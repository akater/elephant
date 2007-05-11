;;; POSTMODERN-tests.lisp
;;;
;;; part of
;;;
;;; Elephant: an object-oriented database for Common Lisp
;;;
;;; Copyright (c) 2005,2006 by Robert L. Read
;;; <rread@common-lisp.net>
;;;
;;; Elephant users are granted the rights to distribute and use this software
;;; as governed by the terms of the Lisp Lesser GNU Public License
;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.

(asdf:operate 'asdf:load-op :elephant-tests)

(in-package "ELEPHANT-TESTS")

(defparameter *testpm-spec* '(:postmodern (:postgresql "127.0.0.1" "elepm" "user" "password")))

(setf *default-spec* *testpm-spec*)

(do-backend-tests)

