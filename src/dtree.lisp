;;; Copyright 2012 Andrey Fainer

;;; This file is part of Sharper.

;;; Sharper is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

;;; Sharper is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.

;;; You should have received a copy of the GNU General Public License
;;; along with Sharper.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The multiresolution raster image or pyramid is a set of images
;; which represents the original image with several levels of
;; details. The highest level represents the image at maximum
;; resolution, i.e. the original image. The previous level
;; represents half-scaled version of the image. The previous of
;; previous level is a half-scaled version of the previous
;; representation. The first level resolution is 1, two elements per
;; image side.

;; The directory tree decomposes the image to smaller size pyramids.

;; The original image

;;        **
;;       ****
;;     ********
;; ****************

;; The decomposed image

;;          **        <- the root directory
;;     ----****----
;;    /    /  \    \
;;  **   **    **   **   <- kids of the root directory
;; **** ****  **** ****

;;; Code:

(in-package #:sharper)

;;; TODO All functions that take a directory pathname should apply
;;; `pathname-as-directory' on it. It is more convenient to give them
;;; the pathname as directory regardless of the last slash.

(defparameter *default-node-resolution* 4
  "The new node has the pyramid with this resolution.")

(defparameter *node-properties-filename* "prop"
  "The node properties filename.
The properties file is a file which is located in the node directory
and contains the list of offsets from the pyramid file beginning to
arrays in the pyramid. The list in the node properties file is defined
in the following way:

  (:offsets <offset-in-bytes-resolution1>
            <offset-in-bytes-resolution2>
            ...
            <offset-in-bytes-resolutionN>).")

(defparameter *node-pyramid-filename* "pyramid"
  "The filename of the pyramid in the node directory.")

(defun node-prop (node &optional key)
  "Get a property of the NODE by the key KEY.
See `*node-properties-filename*'. If key is NIL return the full node
property list."
  (let ((props (read-file (dir+file node *node-properties-filename*))))
    (if key
        (cdr (assoc key props))
        props)))

(defun kids (node)
  "Get the kids list of the node NODE."
  (remove-if #'(lambda (p)
                 (flet ((s= (p1 p2)
                          (aif (pathname-name p1)
                               (string= (namestring it) p2))))
                   ;; FIXME Remove all but directories with names as
                   ;; numbers
                   (or (s= p *node-properties-filename*)
                       (s= p *node-pyramid-filename*))))
             ;; TODO Use `cl-fad:walk-directory'.
             (directory (dir+file node "*/"))))

(defun kid (node num)
  "Get the kid number NUM of the node NODE.
Return NIL if the node NODE does not have the kid."
  (find (princ-to-string num)
        (kids node)
        :key #'(lambda (p)
                 ;; TODO We must handle symlinks!
                 (last1 (pathname-directory p)))
        :test #'string=))

;;; TODO Rename to node-res
(defun node-resolution (node)
  "Get the resolution of the node NODE."
  (pyramid-resolution (node-prop node :offsets)))

;;; TODO Rename to dtree-res
(defun dtree-resolution (root)
  "Calculate resolution of the dtree with the root node ROOT.
The dtree resolution is the resolution of the image decomposed by the
dtree."
  (+ (node-resolution root)
     (aif (kids root)
          (apply #'max (mapcar #'dtree-resolution it))
          0)))

(declaim (inline kid-num))
(defun kid-num (node loc)
  "Calculate the kid number of the node NODE at the location LOC.
The function does not check presence of the kid. It calculates what
the kid number should be at the location LOC. Note that the location
LOC is relative to the node."
  (unfold (tile (node-resolution node) loc)))

(declaim (inline kid-at))
(defun kid-at (node loc)
  "Get the kid of the node NODE at the location LOC.
Return NIL if NODE does not have the kid. The location LOC is relative
to the node."
  (kid node (kid-num node loc)))

;;; TODO The function is not used
(defun node-origin (loc &optional (node-res *default-node-resolution*))
  "Return the origin the node which is specified by the location LOC.
Return the tile origin with the resolution of the tile that is
multiple to the node resolution NODE-RES. See the function
`tile-origin'. "
  (let ((loc (resol (ceil (locat-r loc) node-res) loc)))
    (tile-origin node-res loc)))

(defmacro traverse-node (node res nodevar resvar kidargs &body res-low-forms)
  "Traverse the dtree from the root NODE to the resolution RES.

The dtree traversal is the same for many functions such as
`find-node', `create-node', `find-nodes-box' etc.  This macro helps to
make dtree traversal functions.  The algorithm consists of the
following steps:

1. Add the root NODE resolution to the resolution sum which is zero at
the beginning.

2. If the sum is equal or greater than the target resolution RES
evaluate the first form of the forms RES-LOW-FORMS.

3. Otherwise evaluate the rest of the forms RES-LOW-FORMS.

In scope of the forms two local macros are bound: `traverse-kid' and
`if-kid'.

`traverse-kid' kid &rest kidargs

Continue the traversal from the current node to its kid KID, i.e. do
the step 1 of the algorithm with the kid as the root and the current
resolution sum which is implicitly passed to the recursive call.  Also
pass to it other user-defined arguments KIDARGS.

`if-kid' loc then else

If the kid of the current node at the location LOC is present evaluate
the form THEN and bound the kid to the symbol IT, otherwise evaluate
the form ELSE."
  (with-gensyms (gtrav gres)
    (let* ((resform (car res-low-forms))
           (lowform `(progn ,@(cdr res-low-forms)))
           (travbody
            `(let ((,resvar (+ ,resvar (node-resolution ,nodevar))))
               (if (>= ,resvar ,gres)
                   ,resform
                   ,lowform))))
      `(macrolet ((if-kid (loc then &optional else)
                    `(aif (kid-at ,',nodevar ,loc)
                          ,then ,else))
                  (traverse-kid (kid ,@kidargs)
                    `(,',gtrav ,kid ,',resvar ,,@kidargs)))
         (let ((,gres ,res)
               (,nodevar ,node)
               (,resvar 0))
           (labels ((,gtrav (,nodevar ,resvar ,@kidargs)
                      ,travbody))
             ;; TODO Kidargs should be `let' clauses.  Bind them at
             ;; this point. Otherwise I need to wrap entire
             ;; traverse-node expression into the let form.
             ,travbody))))))

;;; FIXME There is a little mess with type of nodes.  Sometimes
;;; `create-nodes' and `find-node' return a string, sometimes a
;;; pathname.

;;; TODO Why `create-lowform' and `create-nodeform' are macros?
(defmacro create-lowform (&rest kidargs)
  "TODO Docstring"
  `(traverse-kid
    (let ((kid (pathname
                (format nil "~A~D/" curnode (kid-num curnode curloc)))))
      (ensure-directories-exist kid)
      (funcall writefn kid curloc)
      kid)
    ,@kidargs))

(defmacro create-root-form ()
  "TODO Docstring"
  `(if (cl-fad:directory-exists-p node)
       node
       (progn (ensure-directories-exist node)
              (funcall writefn node nil)
              node)))

(defmacro deftraverse-node (name args doc lowform &optional (nodeform 'node))
  "TODO Docstring"
  `(defun ,(symbolicate name '-node) (node loc ,@args)
     ,doc
     (traverse-node ,nodeform (locat-r loc) curnode cures ()
       curnode
       (let ((curloc (resol cures loc)))
         (if-kid curloc
                 (traverse-kid it)
                 ,lowform)))))

;; TODO Replace WRITEFN with corresponding closure in ROOT.
(deftraverse-node create (writefn)
  "Create the node at the location LOC in the dtree NODE.
Create parent nodes and the root NODE if they are not present.  If the
node at requested location is already exist do not recreate it
Also for its parents.

Make directories for each created node and call the function WRITEFN
which is responsible to create data for the node.  The function should
take the following arguments: the created node, the current location.
The current location is the requested location LOC but in case of
creation of parent nodes it has lower resolution (parent resolution).
If the root node is created the current location is NIL.

Return the last created node.  If there is no one return NIL."
  (create-lowform)
  (create-root-form))

;;; FIXME Return values of `find-node' should correlate with args to
;;; findfn passed by `find-nodes-box'.
(deftraverse-node find ()
  "Find the node at the location LOC in the dtree NODE.
Return two values: the found node and the requested location LOC.  If
there is no any node at requested resolution (locat-r LOC) return the
node at maximum available resolution and the location `resol''ed
\(scaled) to the resolution."
  (values curnode curloc))

(defun walk-node-box (res loc1 loc2 fn)
  "TODO Docstring"
  (multiple-value-bind (loc1 loc2) (sort-box loc1 loc2)
    (let* ((lr (- (locat-r loc1) res))
           (n (length (locat-axes loc1)))
           (tile1 (tile lr loc1))
           (tile2 (tile lr loc2))
           (kidloc1 (copy-locat tile1))
           (kidloc2 (maxloc lr n)))
      (flet ((mkbnd (axis kidloc loc)
               "TODO Docstring"
               #'(lambda (l)
                   (declare (ignore l))
                   (setf (locat-axis kidloc axis)
                         (locat-axis loc axis)))))
        (apply #'walk-box (resol res loc1) (resol res loc2)
               #'(lambda (l)
                   (funcall fn l
                            (copy-locat kidloc1)
                            (copy-locat kidloc2)))
               1
               (loop for i from 0 below n
                  collect (let ((i i))
                            (list
                             (mkbnd i kidloc1 tile1) ; Prebegin
                             (mkbnd i kidloc1 (zeroloc lr n)) ; Postbegin
                             (mkbnd i kidloc2 tile2) ; Preend
                             (mkbnd i kidloc2 (maxloc lr n)))))))))) ; Postend

(defmacro deftraverse-box (name doc fname resform lowform &optional nodeform)
  "TODO Docstring"
  ;; TODO Consider shorter names create-box and find-box
  `(defun ,(symbolicate name '-nodes-box) (node loc1 loc2 ,fname)
     (let ((parentloc (zeroloc 1
                               (length (locat-axes loc1))))
           (l1 loc1)
           (l2 loc2))
       (traverse-node ,(aif nodeform it 'node) (locat-r loc1)
           curnode cures
           (parentloc l1 l2)
         ,resform
         (walk-node-box
          (node-resolution curnode) l1 l2
          #'(lambda (l kl1 kl2)
              (let ((curloc (locat+ (resol cures parentloc)
                                    (apply #'locat cures (locat-axes l)))))
                (if-kid l
                        (traverse-kid it curloc kl1 kl2)
                        ,lowform))))))))

(deftraverse-box create
    "TODO Docstring"
  writefn
  nil
  (create-lowform curloc kl1 kl2)
  (create-root-form))

;; TODO The function `find-nodes-box' may have optional arg FINDFN. If it is nil then
;; function collect and return found nodes.
(deftraverse-box find
    "TODO Docstring"
  findfn
  (funcall findfn curnode (unless (pathname-eq node curnode) parentloc))
  (funcall findfn curnode curloc))
