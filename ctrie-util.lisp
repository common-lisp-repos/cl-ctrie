;;;;; -*- mode: common-lisp;   common-lisp-style: modern;    coding: utf-8; -*-
;;;;;

(in-package :cl-ctrie)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Some Helpful Utility Functions and Macros
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#+swank 
(defun ^ (thing &optional wait)
  "inspect THING in the emacs SLIME inspector, optionally waiting
  for the inspector to be dismissed before continuing if WAIT is
  not null"
  (swank:inspect-in-emacs thing :wait wait))

(define-symbol-macro ?  (prog1 * (describe *)))

#+swank
(define-symbol-macro ?^ (prog1 * (^ *)))

(defvar *break* t
  "special variable used for dynamic control of break loops see {defun :break}")

;;; nikodemus/lisppaste 
(defun :break (name &rest values)
  "Demark an instrumented break-point that includes a STOP-BREAKING
   restart.  Subsequently calling (:break t) will re-enable :break
   breakpoints."
  (if *break* (restart-case (break "~A = ~{~S~^, ~}" name values)
                (stop-breaking ()
                  :report "Stop breaking"
                  (setf *break* nil)))
    (when (and (eq name t)(not values))
      (setf *break* t)))
  (values-list values))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 'Unique Value' Utilities
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun gensym-list (length)
  "generate a list of LENGTH uninterned symbols"
  (loop repeat length collect (gensym)))
  
(defmacro gensym-values (num)
  `(values ,@(loop REPEAT num COLLECT '(gensym))))

(defmacro gensym-let ((&rest symbols) &body body)
  (let ((n (length symbols)))
    `(multiple-value-bind ,symbols (gensyms-values ,n)
       ,@body)))

(defun random-string (&key (length 16))
  "Returns a random alphabetic string."
  (let ((id (make-string length)))
    (do ((x 0 (incf x)))
	(( = x length))
      (setf (aref id x) (code-char (+ 97 (random 26)))))
    id))

(defun create-unique-id-byte-vector ()
  "Create a universally unique 16-byte vector using unicly or uuid
  libraries if available, or else fall back to random generation."
  (or
    #+:unicly (unicly:uuid-bit-vector-to-byte-array
               (unicly:uuid-to-bit-vector (unicly:make-v4-uuid)))
    #+:uuid   (uuid:uuid-to-byte-array (uuid:make-v4-uuid))
    (let ((bytes (make-array 16 :element-type '(unsigned-byte 8))))
      (loop for i from 0 to 15 do (setf (aref bytes i) (random 255)))
      bytes)))

(defun create-null-id-byte-vector ()
  "Generate a 16-byte vector representing the NULL uuid."
  (make-array 16 :element-type '(unsigned-byte 8) :initial-element 0))

(defun byte-vector-to-hex-string (vector)
  "Return a 32 character string that maps uniquely to the given byte vector."
  (with-output-to-string (out)
    (loop for byte across vector do (format out "~2,'0x" byte))))

(defun hex-string-to-byte-vector (string)
  "Return the byte vector represented by the (hex) STRING, which is assumed
   to be valid, as by 'byte-vector-to-hex-string'"
  (let ((len (length string))
         (*read-base* 16))
    (loop 
      with bytes = (make-array (ceiling (/ len 2)) :element-type '(unsigned-byte 8))
      for i from 0 by 2 for j from 0 to (ceiling (/ len 2)) while (< i (1- len))
      do (setf (aref bytes j) (read-from-string string nil 0 :start i :end (+ 2 i)))
      finally (return bytes))))

(defun test-byte-vector-hex-string-roundrip ()
  (let* ((bv0 (create-unique-id-byte-vector))
          (bv1 (hex-string-to-byte-vector (byte-vector-to-hex-string bv0))))
    (assert (equalp bv0 bv1)) 
    (values bv0 bv1)))

;; (test-byte-vector-hex-string-roundrip)
;;   #(210 216 162 217 188 189 78 162 150 249 163 170 175 143 56 10)
;;   #(210 216 162 217 188 189 78 162 150 249 163 170 175 143 56 10)
;;
;; (test-byte-vector-hex-string-roundrip)
;;   #(18 84 222 74 74 46 68 53 134 219 105 134 17 177 38 185)
;;   #(18 84 222 74 74 46 68 53 134 219 105 134 17 177 38 185))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; macrology originating from LMJ's excellent LPARALLEL http://www.lparallel.com
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro let1 (var value &body body)
  "Make a single `let' binding, heroically saving three columns."
  `(let ((,var ,value))
     ,@body))

(defmacro defun/inline (name args &body body)
  "define a function automatically declared to be INLINE"
  `(progn
     (declaim (inline ,name))
     (defun ,name ,args ,@body)))

(defmacro once-only-1 (var &body body)
  (let ((tmp (gensym (symbol-name var))))
    ``(let ((,',tmp ,,var))
        ,(let ((,var ',tmp))
           ,@body))))

(defmacro once-only (vars &body body)
  (if vars
      `(once-only-1 ,(car vars)
         (once-only ,(cdr vars)
           ,@body))
      `(progn ,@body)))

(defun unsplice (form)
  (if form (list form) nil))

(defun has-docstring-p (body)
  (and (stringp (car body)) (cdr body)))

(defun has-declare-p (body)
  (and (consp (car body)) (eq (caar body) 'declare)))

(defmacro with-preamble ((preamble body-var) &body body)
  "Pop docstring and declarations off `body-var' and assign them to `preamble'."
  `(let ((,preamble (loop
                       :while (or (has-docstring-p ,body-var)
                                  (has-declare-p ,body-var))
                       :collect (pop ,body-var))))
     ,@body))

(defmacro defmacro/once (name params &body body)
  "Like `defmacro' except that params which are immediately preceded
   by `&once' are passed to a `once-only' call which surrounds `body'."
  (labels ((once-keyword-p (obj)
             (and (symbolp obj) (equalp (symbol-name obj) "&once")))
           (remove-once-keywords (params)
             (mapcar (lambda (x) (if (consp x) (remove-once-keywords x) x))
                     (remove-if #'once-keyword-p params)))
           (find-once-params (params)
             (mapcon (lambda (x)
                       (cond ((consp (first x))
                              (find-once-params (first x)))
                             ((once-keyword-p (first x))
                              (unless (and (cdr x) (atom (cadr x)))
                                (error "`&once' without parameter in ~a" name))
                              (list (second x)))
                             (t
                              nil)))
                     params)))
    (with-preamble (preamble body)
      `(defmacro ,name ,(remove-once-keywords params)
         ,@preamble
         (once-only ,(find-once-params params)
           ,@body)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Anaphora
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro anaphoric (op test &body body)
  "higher-order anaphoric operator creation macro."
  `(let ((it ,test))
     (,op it ,@body)))

(defmacro aprog1 (first &body rest)
  "Binds IT to the first form so that it can be used in the rest of the
  forms. The whole thing returns IT."
  `(anaphoric prog1 ,first ,@rest))

(defmacro awhen (test &body body)
  "Like WHEN, except binds the result of the test to IT (via LET) for the scope
  of the body."
  `(anaphoric when ,test ,@body))

(defmacro atypecase (keyform &body cases)
  "Like TYPECASE, except binds the result of the keyform to IT (via LET) for
  the scope of the cases."
  `(anaphoric typecase ,keyform ,@cases))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Atomic Update (sbcl src copied over until i update to a more recent release)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; TODO: unused?

(defmacro atomic-update (place update-fn &rest arguments &environment env) 
  "Updates PLACE atomically to the value returned by calling function
  designated by UPDATE-FN with ARGUMENTS and the previous value of PLACE.
  PLACE may be read and UPDATE-FN evaluated and called multiple times before the
  update succeeds: atomicity in this context means that value of place did not
  change between the time it was read, and the time it was replaced with the
  computed value. PLACE can be any place supported by SB-EXT:COMPARE-AND-SWAP.
  EXAMPLE: Conses T to the head of FOO-LIST:
  ;;;   (defstruct foo list)
  ;;;   (defvar *foo* (make-foo))
  ;;;   (atomic-update (foo-list *foo*) #'cons t)"
  (multiple-value-bind (vars vals old new cas-form read-form)
      (get-cas-expansion place env)
    `(let* (,@(mapcar 'list vars vals)
            (,old ,read-form))
       (loop for ,new = (funcall ,update-fn ,@arguments ,old)
             until (eq ,old (setf ,old ,cas-form))
             finally (return ,new)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Assorted
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Clozure Common Lisp (??)
(defmacro ppmx (form)
  "Pretty prints the macro expansion of FORM."
  `(let* ((exp1 (macroexpand-1 ',form))
           (exp (macroexpand exp1))
           (*print-circle* nil))
     (format *trace-output* "~%;; Form: ~W"  (quote ,form))
     #+() (pprint (quote ,form) *trace-output*)
     (cond ((equal exp exp1)
             (format *trace-output* "~%;;~%;; Macro expansion:~%")
             (pprint exp *trace-output*))
       (t (format *trace-output* "~&;; First step of expansion:~%")
         (pprint exp1 *trace-output*)
         (format *trace-output* "~%;;~%;; Final expansion:~%")
         (pprint exp *trace-output*)))
     (format *trace-output* "~%;;~%;; ")
     (values)))


;;; place utils (from ??)
(defmacro place-fn (place-form)
  "This creates a closure which can write to and read from the 'place'
   designated by PLACE-FORM."
  (with-gensyms (value value-supplied-p)
    `(sb-int:named-lambda place (&optional (,value nil ,value-supplied-p))
       (if ,value-supplied-p
           (setf ,place-form ,value)
         ,place-form))))


(defmacro map-fn (place-form)
  "This creates a closure which can write to and read from 'maps'"
  (with-gensyms (key value value-supplied-p)
    `(sb-int:named-lambda place (,key &optional (,value nil ,value-supplied-p))
       (if ,value-supplied-p
         (setf (,place-form ,key) ,value)
         (,place-form ,key)))))


(defmacro post-incf (place &optional (delta 1))
  "place++ ala C"
  `(prog1 ,place (incf ,place ,delta)))


;; KMRCL/USENET
(defmacro deflex (var val &optional (doc nil docp))
  "Defines a top level (global) lexical VAR with initial value VAL,
  which is assigned unconditionally as with DEFPARAMETER. If a DOC
  string is provided, it is attached to both the name |VAR| and the
  name *STORAGE-FOR-DEFLEX-VAR-|VAR|* as a documentation string of
  kind 'VARIABLE. The new VAR will have lexical scope and thus may
  be shadowed by LET bindings without affecting its global value."
  (let* ((s0 (load-time-value (symbol-name '#:*storage-for-deflex-var-)))
         (s1 (symbol-name var))
         (p1 (symbol-package var))
         (s2 (load-time-value (symbol-name '#:*)))
         (backing-var (intern (concatenate 'string s0 s1 s2) p1)))
    `(progn
      (defparameter ,backing-var ,val ,@(when docp `(,doc)))
      ,@(when docp
              `((setf (documentation ',var 'variable) ,doc)))
       (define-symbol-macro ,var ,backing-var))))

;;; emacs?
(defun mapappend (fun &rest args)
   (if (some 'null args)
       '()
       (append (apply fun (mapcar 'car args))
         (mapappend fun (mapcar 'cdr args)))))