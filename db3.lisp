;;;
;;; Tools to handle the DBF file format
;;;

(in-package :pgloader.db3)

(defvar *db3-pgsql-type-mapping*
  '(("C" . "text")			; ignore field-length
    ("N" . "numeric")			; handle both integers and floats
    ("L" . "boolean")			; PostgreSQL compatible representation
    ("D" . "date")			; no TimeZone in DB3 files
    ("M" . "text")))			; not handled yet

(defun convert-db3-type-to-pgsql (type length)
  "Convert a DB3 field type into a PostgreSQL data type."
  ;; we just ignore the length as we use text here
  (declare (ignore length))
  (cdr (assoc type *db3-pgsql-type-mapping* :test #'string=)))

(defun db3-create-table (input
			 &optional (table-name (pathname-name input)))
  "Return a CREATE TABLE suitable for PostgreSQL from reading the given db3
   file headers"
  (with-open-file (stream input
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (with-output-to-string (s)
      (let ((db3 (make-instance 'db3:db3)))
	(db3:load-header db3 stream)
	(format s "create table ~a (~%" table-name)
	(loop
	   for (field . more?) on (db3::fields db3)
	   for (name type) =
	     (list (db3::field-name field)
		   (convert-db3-type-to-pgsql (db3::field-type field)
					      (db3::field-length field)))
	   do (format s "~4T~a ~25T~a~:[~;,~]~%" name type more?))
	(format s ");")))))

(defun logical-to-boolean (value)
  "Convert a DB3 logical value to a PostgreSQL boolean."
  (declare (inline))
  (if (string= value "?") nil value))

(defun db3-trim-string (value)
  "DB3 Strings a right padded with spaces, fix that."
  (declare (inline))
  (string-right-trim '(#\Space) value))

(defun db3-date-to-pgsql-date (value)
  "Convert a DB3 date to a PostgreSQL date."
  (declare (inline))
  (let ((year  (subseq value 0 4))
	(month (subseq value 4 6))
	(day   (subseq value 6 8)))
    (format nil "~a-~a-~a" year month day)))

(defun transforms (input)
  "Return the list of transforms to apply to each row of data in order to
   convert values to PostgreSQL format"
  (with-open-file (stream input
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (let ((db3 (make-instance 'db3:db3)))
      (db3:load-header db3 stream)
      (loop
	 for field in (db3::fields db3)
	 for type = (db3::field-type field)
	 collect
	   (cond ((string= type "L") #'logical-to-boolean)
		 ((string= type "C") #'db3-trim-string)
		 ((string= type "D") #'db3-date-to-pgsql-date)
		 (t                  nil))))))


;;;
;;; Integration with pgloader
;;;
(defun map-rows (filename &key process-row-fn)
  "Extract DB3 data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row."
  (with-open-file (stream filename
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (let ((db3 (make-instance 'db3:db3)))
      (db3:load-header db3 stream)
      (loop
	 with count = (db3:record-count db3)
	 repeat count
	 for row-array = (db3:load-record db3 stream)
	 do (funcall process-row-fn (coerce row-array 'list))
	 finally (return count)))))

(defun copy-to (db3-filename pgsql-copy-filename)
  "Extract data from DB3 file into a PotgreSQL COPY TEXT formated file"
  (with-open-file (text-file pgsql-copy-filename
			     :direction :output
			     :if-exists :supersede
			     :external-format :utf-8)
    (let ((transforms (transforms db3-filename)))
      (map-rows db3-filename
		:process-row-fn
		(lambda (row)
		  (pgloader.pgsql:format-row text-file
					     row
					     :transforms transforms))))))

;;;
;;; Export MySQL data to our lparallel data queue. All the work is done in
;;; other basic layers, simple enough function.
;;;
(defun copy-to-queue (filename dataq table-name)
  "Copy data from DB3 file FILENAME into queue DATAQ"
  (let ((read (pgloader.queue:map-push-queue dataq #'map-rows filename)))
    (pgstate-incf *state* table-name :read read)))

(defun stream-file (filename
		    &key
		      dbname
		      (table-name (pathname-name filename))
		      (create-table t)
		      (truncate nil))
  "Open the DB3 and stream its content to a PostgreSQL database."
  (when create-table
    (pgloader.pgsql:execute dbname (db3-create-table filename)))

  (let* ((*state*     (pgloader.utils:make-pgstate))
	 (lp:*kernel* (lp:make-kernel 2 :bindings
				      `((*pgconn-host* . ,*pgconn-host*)
					(*pgconn-port* . ,*pgconn-port*)
					(*pgconn-user* . ,*pgconn-user*)
					(*pgconn-pass* . ,*pgconn-pass*)
					(*pg-settings* . ',*pg-settings*)
					(*state*       . ,*state*))))
	 (channel     (lp:make-channel))
	 (dataq       (lq:make-queue :fixed-capacity 4096)))

    ;; statistics
    (report-header)
    (pgstate-add-table *state* dbname table-name)
    (report-table-name table-name)

    (multiple-value-bind (res secs)
	(timing
	 (lp:submit-task channel #'copy-to-queue filename dataq table-name)

	 ;; and start another task to push that data from the queue to PostgreSQL
	 (lp:submit-task channel
			 #'pgloader.pgsql:copy-from-queue
			 dbname table-name dataq
			 :truncate truncate
			 :transforms (transforms filename))

	 ;; now wait until both the tasks are over, and kill the kernel
	 (loop for tasks below 2 do (lp:receive-result channel))
	 (lp:end-kernel))

      ;; report stats!
      (declare (ignore res))
      (pgstate-incf *state* table-name :secs secs)
      (report-pgtable-stats *state* table-name))))
