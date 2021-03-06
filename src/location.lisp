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

;; Raster images can be represented by a regular grid. All cells of
;; the grid have equal sides and the length of each side is 1.

;; A particular cell location in space can be defined by the list of
;; axes, i.e. ranges from the image origin to the cell on each side
;; of the grid.

;; Because raster images can have different resolutions, that is the
;; length of a side, we should store resolution in the location to be
;; able to compare and scale images with different resolutions. Note
;; that we do not need to store resolution of each side because we
;; have the regular grid and it is sufficient to store the maximum
;; resolution to be able to compare images.  Also, for simplicity the
;; current implementation stores resolutions as power of two and the
;; minimum one is 1 (there is no sense to have images with one
;; element).

;;;; This file contains utilities for working with the locations.

;;; Code:

(in-package #:sharper)

;;; FIXME Can't inline `assert-resol' on SBCL.
;; (declaim (inline assert-resol))
(defun assert-resol (r)
  "Signal an error if the resolution R is less than 1."
  (assert (>= r 1) nil
          "Resolution R must be greater or equal to 1 ~
           but ~D was given" r))

(declaim (inline ilength))
(defun ilength (r)
  "Return the image length with the resolution R on one axis.
Do not check the value of the resolution R."
  (expt 2 r))

(defun locat (r x &rest more)
  "Make a location with coordinates (X . MORE) and the resolution R."
  (assert-resol r)
  (let ((axes (list* x more))
        (l (ilength r)))
   (mapc #'(lambda (x)
             (if (>= (abs x) l)
              (error "The value of some axis is ~D,~%~
                      which is greater or equal to the image length ~D."
                     x l)))
         axes)
   (cons r axes)))

(declaim (inline locat-r))
(defun locat-r (l)
  "Get resolution of the location L."
  (car l))

(declaim (inline locat-axes))
(defun locat-axes (l)
  "Get the axes list of the location L."
  (cdr l))

;;; TODO Consider another name: scale
(defun resol (r l)
  "Scale the location L to the resolution R."
  (assert-resol r)
  (let ((n (ilength (- (locat-r l) r))))
    (apply #'locat r (mapcar #'(lambda (x)
                                 (truncate (/ x n)))
                             (locat-axes l)))))

(defun unfold (l)
  "Reduce the number of dimensions of the image to one.
Return the result axis.

The form

  (unfold (locat r x y z))

is equivalent to

  (+ (* z (ilength r) (ilength r)) (* y (ilength r)) x)."
  (let ((m (ilength (locat-r l)))
        (n (length (locat-axes l))))
    (reduce #'+
            (reverse (locat-axes l))
            :key #'(lambda (x)
                     (* x (expt m (decf n)))))))

(defun tile (r l)
  "Split the image to tiles with the resolution R.
Find the tile which contains the location L and return the location L
relative to it.

The form

  (tile 1 (locat 3 1 2 5))

is equivalent to

  ((rem 1 (ilength 1))
   (rem 2 (ilength 1))
   (rem 5 (ilength 1)))."
  (assert-resol r)
  (let ((n (ilength r)))
   (apply #'locat r (mapcar #'(lambda (x) (rem x n))
                            (locat-axes l)))))

(defun walk-box (l1 l2 fn &optional (step 1))
  "Apply the function FN to each location in the box [L1; L2].
The box is specified by two corners: L1 and L2. Both corners are
included to the walking.

The function FN must take one argument: the current walking location.

The argument STEP may be a function or a number. In the first case,
the function STEP takes no arguments and return a number: who much to
walk from the current location to the next one.

The walking is performed in the following way:

  1. The walking begins from the location which is closest to the
  image origin and ends to the farthest one. Both locations may not to
  be equal to locations L1 and L2. They can be the other two corners
  of the box.

  2. The walking performs as the scanline rendering, row-by-row along
  the first axis.

At present, the walking performs only at resolution (locat-r L1)."
  ;; TODO Make cond-function (&body tests-llists-exprs)
  (let ((stepfn (if (functionp step)
                    step
                    #'(lambda () step)))
        (callfn #'(lambda (axes)
                    (funcall fn (apply #'locat (locat-r l1) axes)))))
    (funcall
     (reduce #'(lambda (fn range)
                 #'(lambda (axes)
                     (loop
                        with n = (car range)
                        while (<= n (cadr range))
                        do (funcall fn (cons n axes))
                        (incf n (funcall stepfn)))))
             (cons callfn (mapcar #'(lambda (a b)
                                      (if (< a b)
                                          (list a b)
                                          (list b a)))
                                  (locat-axes l1)
                                  (locat-axes l2))))
     nil)))

(defun map-axes (fn l &rest more)
  "Apply the function FN to each axis of the location L.
Use MORE locations if they are supplied.

The function FN must take the number of arguments equal to the number
of supplied locations (L + MORE). If resolutions of locations is not
equal then locations are `resol'ed to the maximum one."
  (let* ((ls (cons l more))
         (r (reduce #'max ls :key #'locat-r)))
    (apply #'locat r
           (apply #'mapcar fn
                  (mapcar #'(lambda (l)
                              (locat-axes (resol r l)))
                          ls)))))

(defmacro def-locat-op (name op)
  "Define the operation OP to be perfomed on locations.
Define the function NAME that applies the function `map-axes' with the
function OP to one or more locations."
  `(defun ,name (l &rest more)
     (apply #'map-axes #',op l more)))

(macrolet ((defops (&rest ops)
             `(progn
                ,@(mapcar #'(lambda (op)
                              `(def-locat-op
                                   ,(symbolicate 'locat op)
                                   ,op))
                          ops))))
  (defops + - * /))

(defun tile-origin (r l)
  "Return the location of the tile origin in the image.
Split the image to tiles with the resolution R as the function `tile'
does but return the location of the tile in the image which contains
the location L."
  (locat- l (apply #'locat
                   (locat-r l)
                   (locat-axes (tile r l)))))

;; (defun tile-box (r l l1 l2)
;;   "Return the box [L1; L2] clipped to the tile with the location L.
;; Split the image to tiles with the resolution R as the function `tile'
;; does. Return the box clipped with boundaries of the tile which
;; contains the location L. Return NIL if the tile and the box do not
;; overlap.")
