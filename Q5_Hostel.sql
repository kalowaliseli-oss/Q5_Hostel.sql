/* =====================================================================
   ICT371  QUESTION 5 - Hostel Room Allocation                    [50]
   Rules: never exceed capacity; one ACTIVE allocation per student;
          ENDED allocations are history and do not occupy beds.
   ===================================================================== */
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - capacity > 0; status IN ('ACTIVE','ENDED').
   - chk_status_release ties status to released_on:
       ACTIVE -> released_on IS NULL,  ENDED -> released_on IS NOT NULL.
   - occupancy_snapshot has a COMPOSITE primary key (snapshot_date,
     room_id): "PK part" in the brief. room_id is also a FK to rooms.
   - Capacity / one-ACTIVE rules need other rows, so they are enforced by
     the trigger in (d), created before the seed allocations.
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students (student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms (room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(6)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_status_release CHECK (
           (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms (room_id),
    occupied_beds  INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds      INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),     -- will be FULL
    ('A102', 3),     -- will be PARTLY occupied
    ('A103', 2);     -- will be EMPTY (only ended history)

INSERT INTO students (student_number, full_name) VALUES
    ('2024020201', 'Mwila Banda'),
    ('2024020202', 'Chanda Phiri'),
    ('2024020203', 'Natasha Zulu'),
    ('2024020204', 'Joseph Mulenga'),
    ('2024020205', 'Grace Tembo'),
    ('2024020206', 'Peter Lungu');     -- has no allocation (used in tests)


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_free_beds                                        [6]
   - Only status = 'ACTIVE' rows are counted, so ENDED history never
     reduces availability.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_capacity rooms.capacity%TYPE;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM   rooms
    WHERE  room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM   allocations
    WHERE  room_id = p_room_id
    AND    status  = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_allocate_room                                   [8]
   - Validate student and room (locking both rows with FOR UPDATE so two
     clerks cannot fill the last bed or double-allocate a student at the
     same moment).
   - Reject a student who already has an ACTIVE allocation.
   - Check fn_free_beds > 0.
   - Insert one ACTIVE row with released_on NULL.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student id %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: BEFORE INSERT OR UPDATE, FOR EACH ROW               [8]
   - Same two rules as the procedure, but now ALSO for direct SQL.
   - Only a row that will be ACTIVE needs checking (ENDED rows occupy no
     bed), so ENDED rows return at once.
   - "Exclude the row being updated": on UPDATE, v_self_id = OLD id and
     every count ignores it. Example: a full room (2/2) and someone fixes
     a typo in allocated_on of one of its rows. Without the exclusion the
     row would count itself, see 2 others + itself, and be rejected.
   - Row locks on the student and room serialise concurrent changes.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_self_id  allocations.allocation_id%TYPE;     -- NULL on INSERT
    v_capacity rooms.capacity%TYPE;
    v_others   INTEGER;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_self_id := OLD.allocation_id;
    END IF;

    PERFORM 1 FROM students WHERE student_id = NEW.student_id FOR UPDATE;

    SELECT capacity INTO v_capacity
    FROM   rooms
    WHERE  room_id = NEW.room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room id %', NEW.room_id;
    END IF;

    -- Rule 1: one ACTIVE allocation per student
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id
               AND   status = 'ACTIVE'
               AND   allocation_id IS DISTINCT FROM v_self_id) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    -- Rule 2: capacity
    SELECT COUNT(*) INTO v_others
    FROM   allocations
    WHERE  room_id = NEW.room_id
    AND    status  = 'ACTIVE'
    AND    allocation_id IS DISTINCT FROM v_self_id;

    IF v_others >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_rules();


-- (a) continued: allocations giving FULL, PARTLY OCCUPIED and EMPTY rooms
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 60, 'ENDED'),   -- history in A103
    (5, 1, CURRENT_DATE - 80, CURRENT_DATE - 50, 'ENDED');   -- history in A101
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- A101 1/2
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);   -- A101 2/2 FULL
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);   -- A102 1/3
CALL pr_allocate_room(4, 2, CURRENT_DATE - 10);   -- A102 2/3 PARTLY
-- A103 has only an ENDED allocation -> EMPTY

SELECT * FROM allocations ORDER BY allocation_id;

-- Tests for (b)
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;  -- 0, 1, 2
CALL expect_error('SELECT fn_free_beds(99)');

-- Tests for (c)
CALL expect_error('CALL pr_allocate_room(6, 1, CURRENT_DATE)');    -- A101 full
CALL expect_error('CALL pr_allocate_room(1, 3, CURRENT_DATE)');    -- already ACTIVE
CALL expect_error('CALL pr_allocate_room(99, 3, CURRENT_DATE)');   -- unknown student
CALL expect_error('CALL pr_allocate_room(6, 99, CURRENT_DATE)');   -- unknown room

-- Tests for (d): direct SQL obeys the same rules
CALL expect_error($q$INSERT INTO allocations (student_id, room_id, allocated_on)
                     VALUES (6, 1, CURRENT_DATE)$q$);              -- capacity
CALL expect_error($q$INSERT INTO allocations (student_id, room_id, allocated_on)
                     VALUES (2, 3, CURRENT_DATE)$q$);              -- second ACTIVE
CALL expect_error($q$UPDATE allocations SET room_id = 1 WHERE student_id = 3 AND status = 'ACTIVE'$q$);
-- Exclusion of the updated row: editing a row in the FULL room succeeds
UPDATE allocations SET allocated_on = allocated_on - 1 WHERE student_id = 1 AND status = 'ACTIVE';
-- Releasing a student frees a bed (ENDED rows are not checked)
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE
WHERE  student_id = 2 AND status = 'ACTIVE';
CALL pr_allocate_room(6, 1, CURRENT_DATE);        -- now succeeds, A101 full again


/* ---------------------------------------------------------------------
   (e) VIEW v_room_occupancy                                        [5]
   - LEFT JOIN so rooms with NO allocations still appear.
   - The condition a.status = 'ACTIVE' is in the ON clause, NOT in WHERE.
     In WHERE it would remove the empty rooms (their a.status is NULL)
     and rooms with only ENDED history.
   - COUNT(a.allocation_id) counts only matched rows, so an empty room
     gives 0 (COUNT(*) would wrongly give 1).
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status  = 'ACTIVE'
GROUP  BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;   -- 2/0, 2/1, 0/2


/* ---------------------------------------------------------------------
   (f) INDEX                                                         [5]
   Query: WHERE room_id = ? AND status = 'ACTIVE'  (used by fn_free_beds,
          the procedure, the trigger and the view)
   - PARTIAL index on room_id WHERE status = 'ACTIVE': only current
     residents are indexed. Over the years ENDED history grows without
     limit while ACTIVE rows stay at most the number of beds, so the index
     stays small and every capacity check is fast.
   - The query must repeat status = 'ACTIVE' for the planner to use it.
   --------------------------------------------------------------------- */
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

EXPLAIN
SELECT COUNT(*) FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';

SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT COUNT(*) FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - Reads the view, so every room (even empty ones) gets a row.
   - Composite PK (snapshot_date, room_id) = one row per date and room;
     ON CONFLICT on that key replaces the values when rerun the same day.
   - '55 23 * * *' = 23:55 every day.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
SET search_path = q5, public
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM   v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET    occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();     -- rerun: still 3 rows for today
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',
    $$CALL q5.pr_refresh_occupancy()$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q5_refresh_occupancy';

