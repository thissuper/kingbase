-- Added new optimization & constraint configuration options to part_config & part_config_sub (optimize_trigger, optimize_constraint) (Github Issue #62)
    -- The premake config value now only controls what its name suggests (the number of future partitions to premake)
    -- For existing partition sets, the values for these columns will be set equal to the current premake value
    -- Default value for optimize_trigger is same as default for premake (4)
    -- Default value for optimize_constraint is 30 (30 days, 30 months, etc)
    -- Not added as parameters to create_parent() or create_sub_parent()
        --These can be changed later and normal maintenance will take care of updating the current partition set to match.

-- Time epoch partitioning is now possible (Github Issue #44)
    -- Control column can be an integer type but trigger, partition constraints and partition names will be based on a time interval.
    -- New boolean parameter to the create_parent()/create_sub_parent() functions. Ensure all of your current calls to this function account for it!

-- Fixed bug introduced in v2.1.0 that caused run_maintenance() to not catch up if partition creation fell behind. (Github Issue #67)
    -- The fix for this issue also introduces new (improved) behavior for time-based partition maintenance.
        -- Previously, the premade tables were determined by the current time at the time maintenance ran.
        -- It is now instead based off of the maximum value in the partition set.
        -- This is essentially the same behavior that serial partitioning has always had.
        -- This means that if no new data is being inserted, once the premake value is met, no new partitions will be made. Previously they would be created no matter what, indefinitely.
        -- Resumption of data insertion after a large gap in data and maintenance runs may cause data to go into the parent until run_maintenance() is called again. 
            -- New data should then go to new children, but data will then have to be cleaned out of the parent.
        -- This also means partitioning should work more predictably if data with a future timestamp is inserted. Previously this was not accounted for and could cause maintenance to work inconsistently.
    -- KNOWN BUGS: If you insert "future" data in a time-based, sub-partitioned set, maintenance may skip child tables in some partition sets depending how that data relates to the subpartition interval. 
        -- Working on a fix for this, but didn't want to hold this release up anymore. To work around this, 
            -- Increase the premake and/or optimize_trigger values appropriately to account for your normal data insertion window.
            -- Monitor for data going into parent tables and fix that as documented.

-- Fixed bug in show_partitions() when used against a quarterly partitioned set. Wouldn't return all tables in expected order.
-- Fixed bugs in reapply_constraints.py instroduced in v2.1.0 that prevented it from running. Increased minimum version requirement of sys_partman to 2.2.0.
-- Made creation of additional column constraints more efficient (if used) and less spammy in the run_maintenance() jobmon logs.
-- Added debug option to run_maintenance().

-- Fixed bug introduced in 2.1.0 that wasn't setting the retention config columns in part_config properly for multi-level subpartitions
    -- You may encounter an error during maintenance or during the upgrade related to inconsistent data in the part_config_sub table. There was a constraint in place before that tried to prevent this happening, but it was not doing it properly. There is now a new function in place that is part of routine maintenance that checks for this consistency. This checks to ensure that all sub-partition parents in part_config_sub that are themselves part of a sub-partition set have the same configuration values. You can run the function "check_subpart_sameconfig('parent_table')" for all sub-partitioned table sets to see which ones have inconsistent data. The function should only return a single row. If more than one row is returned then just update the config entries that are mismatched and this should clear the error. If you're still having problems, please open an Issue on Github with the error you receive and the full contents of your part_config & part_config_sub tables.
    -- If you encounter the error during the upgrade, run the following query using the parent table returned in the error for <<<schema.table>>> and setting <<<partman_schema>>> to the schema you installed sys_partman to. Only a single row should be returned. If not then fix the mismatched data.
/*
    WITH parent_info AS (
        SELECT c1.oid
        FROM sys_catalog.sys_class c1 
        JOIN sys_catalog.sys_namespace n1 ON c1.relnamespace = n1.oid
        WHERE n1.nspname||'.'||c1.relname = '<<<schema.table>>>'
    )
    , child_tables AS (
        SELECT n.nspname||'.'||c.relname AS tablename
        FROM sys_catalog.sys_inherits h
        JOIN sys_catalog.sys_class c ON c.oid = h.inhrelid
        JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
        JOIN parent_info pi ON h.inhparent = pi.oid
    )
    SELECT DISTINCT a.sub_partition_type
        , a.sub_control
        , a.sub_partition_interval
        , a.sub_constraint_cols
        , a.sub_premake
        , a.sub_inherit_fk
        , a.sub_retention
        , a.sub_retention_schema
        , a.sub_retention_keep_table
        , a.sub_retention_keep_index
        , a.sub_use_run_maintenance
        , a.sub_jobmon
    FROM <<<partman_schema>>>.part_config_sub a
    JOIN child_tables b on a.sub_parent = b.tablename;
*/

CREATE TEMP TABLE partman_preserve_privs_temp (statement text);

INSERT INTO partman_preserve_privs_temp 
SELECT 'GRANT EXECUTE ON FUNCTION @extschema@.run_maintenance(text, boolean, boolean, boolean) TO '||array_to_string(array_agg(grantee::text), ',')||';' 
FROM information_schema.routine_privileges
WHERE routine_schema = '@extschema@'
AND routine_name = 'run_maintenance'; 

INSERT INTO partman_preserve_privs_temp 
SELECT 'GRANT EXECUTE ON FUNCTION @extschema@.create_parent(text, text, text, text, text[], int, boolean, text, boolean, boolean, boolean, boolean) TO '||array_to_string(array_agg(grantee::text), ',')||';' 
FROM information_schema.routine_privileges
WHERE routine_schema = '@extschema@'
AND routine_name = 'create_parent'; 

INSERT INTO partman_preserve_privs_temp
SELECT 'GRANT EXECUTE ON FUNCTION @extschema@.create_sub_parent(text, text, text, text, text[], int, text, boolean, boolean, boolean, boolean) TO '||array_to_string(array_agg(grantee::text), ',')||';' 
FROM information_schema.routine_privileges
WHERE routine_schema = '@extschema@'
AND routine_name = 'create_sub_parent';

INSERT INTO partman_preserve_privs_temp
SELECT 'GRANT EXECUTE ON FUNCTION @extschema@.check_subpart_sameconfig(text) TO '||array_to_string(array_agg(grantee::text), ',')||';'
FROM information_schema.routine_privileges
WHERE routine_schema = '@extschema@'
AND routine_name = 'check_subpart_sameconfig';

DROP FUNCTION run_maintenance(text, boolean, boolean);
DROP FUNCTION @extschema@.create_parent(text, text, text, text, text[], int, boolean, text, boolean, boolean, boolean);
DROP FUNCTION @extschema@.create_sub_parent(text, text, text, text, text[], int, text, boolean, boolean, boolean);
ALTER TABLE @extschema@.part_config_sub DROP CONSTRAINT subpart_sameconfig_chk;
DROP FUNCTION @extschema@.check_subpart_sameconfig(text);

ALTER TABLE @extschema@.part_config ADD COLUMN epoch boolean NOT NULL DEFAULT false;
ALTER TABLE @extschema@.part_config ADD COLUMN optimize_trigger int NOT NULL DEFAULT 4;
ALTER TABLE @extschema@.part_config ADD COLUMN optimize_constraint int NOT NULL DEFAULT 30;
UPDATE @extschema@.part_config SET optimize_trigger = premake;
UPDATE @extschema@.part_config SET optimize_constraint = premake;

ALTER TABLE @extschema@.part_config_sub ADD COLUMN sub_epoch boolean NOT NULL DEFAULT false;
ALTER TABLE @extschema@.part_config_sub ADD COLUMN sub_optimize_trigger int NOT NULL DEFAULT 4;
ALTER TABLE @extschema@.part_config_sub ADD COLUMN sub_optimize_constraint int NOT NULL DEFAULT 30;
UPDATE @extschema@.part_config_sub SET sub_optimize_trigger = sub_premake;
UPDATE @extschema@.part_config_sub SET sub_optimize_constraint = sub_premake;

/*
 * Check for consistent data in part_config_sub table. Was unable to get this working properly as either a constraint or trigger. 
 * Would either delay raising an error until the next write (which I cannot predict) or disallow future edits to update a sub-partition set's configuration.
 * This is called by run_maintainance() and at least provides a consistent way to check that I know will run. 
 * If anyone can get a working constraint/trigger, please help!
*/
CREATE OR REPLACE INTERNAL FUNCTION @extschema@.check_subpart_sameconfig(p_parent_table text) 
RETURNS TABLE (sub_partition_type text
        , sub_control text
        , sub_partition_interval text
        , sub_constraint_cols text[]
        , sub_premake int
        , sub_inherit_fk boolean
        , sub_retention text
        , sub_retention_schema text
        , sub_retention_keep_table boolean
        , sub_retention_keep_index boolean
        , sub_use_run_maintenance boolean
        , sub_epoch boolean
        , sub_optimize_trigger int
        , sub_optimize_constraint int
        , sub_jobmon boolean)
LANGUAGE sql STABLE SECURITY DEFINER
AS $$

    WITH parent_info AS (
        SELECT c1.oid
        FROM sys_catalog.sys_class c1 
        JOIN sys_catalog.sys_namespace n1 ON c1.relnamespace = n1.oid
        WHERE n1.nspname||'.'||c1.relname = p_parent_table
    )
    , child_tables AS (
        SELECT n.nspname||'.'||c.relname AS tablename
        FROM sys_catalog.sys_inherits h
        JOIN sys_catalog.sys_class c ON c.oid = h.inhrelid
        JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
        JOIN parent_info pi ON h.inhparent = pi.oid
    )
    -- Column order here must match the RETURNS TABLE definition
    SELECT DISTINCT a.sub_partition_type
        , a.sub_control
        , a.sub_partition_interval
        , a.sub_constraint_cols
        , a.sub_premake
        , a.sub_inherit_fk
        , a.sub_retention
        , a.sub_retention_schema
        , a.sub_retention_keep_table
        , a.sub_retention_keep_index
        , a.sub_use_run_maintenance
        , a.sub_epoch
        , a.sub_optimize_trigger
        , a.sub_optimize_constraint
        , a.sub_jobmon
    FROM @extschema@.part_config_sub a
    JOIN child_tables b on a.sub_parent = b.tablename;
$$;

-- Do a check here to ensure configuration is consistent using above new function
DO $$
DECLARE
v_count int;
v_row   record;
BEGIN
    FOR v_row IN SELECT sub_parent FROM @extschema@.part_config_sub LOOP
        SELECT count(*) INTO v_count FROM @extschema@.check_subpart_sameconfig(v_row.sub_parent);
        IF v_count > 1 THEN
            RAISE EXCEPTION 'UPDATE ABORTED: Inconsistent data found in part_config_sub table for parent table %. Please see 2.2.0 release notes for why this occurred and how to fix it.', v_row.sub_parent;
        END IF;
    END LOOP;
END
$$;


/*
 * Create the trigger function for the parent table of an id-based partition set
 */
CREATE OR REPLACE FUNCTION create_function_id(p_parent_table text, p_job_id bigint DEFAULT NULL) RETURNS void
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_control                       text;
v_count                         int;
v_current_partition_name        text;
v_current_partition_id          bigint;
v_datetime_string               text;
v_final_partition_id            bigint;
v_function_name                 text;
v_higher_parent                 text := p_parent_table;
v_id_position                   int;
v_job_id                        bigint;
v_jobmon                        text;
v_jobmon_schema                 text;
v_last_partition                text;
v_max                           bigint;
v_next_partition_id             bigint;
v_next_partition_name           text;
v_old_search_path               text;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_interval            bigint;
v_premake                       int;
v_prev_partition_id             bigint;
v_prev_partition_name           text;
v_row_max_id                    record;
v_run_maint                     boolean;
v_step_id                       bigint;
v_top_parent                    text := p_parent_table;
v_trig_func                     text;
v_optimize_trigger              int;

BEGIN

SELECT partition_interval::bigint
    , control
    , premake
    , optimize_trigger
    , use_run_maintenance
    , jobmon
INTO v_partition_interval
    , v_control
    , v_premake
    , v_optimize_trigger
    , v_run_maint
    , v_jobmon
FROM @extschema@.part_config 
WHERE parent_table = p_parent_table
AND partition_type = 'id';

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

SELECT partition_tablename INTO v_last_partition FROM @extschema@.show_partitions(p_parent_table, 'DESC') LIMIT 1;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_catalog.sys_namespace n, sys_catalog.sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF p_job_id IS NULL THEN
        v_job_id := add_job(format('PARTMAN CREATE OR REPLACE INTERNAL FUNCTION: %s', p_parent_table));
    ELSE
        v_job_id = p_job_id;
    END IF;
    v_step_id := add_step(v_job_id, format('Creating partition function for table %s', p_parent_table));
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;
v_function_name := @extschema@.check_name_length(v_parent_tablename, '_part_trig_func', FALSE);

-- Get the highest level top parent if multi-level partitioned in order to get proper max() value below
WHILE v_higher_parent IS NOT NULL LOOP -- initially set in DECLARE
    WITH top_oid AS (
        SELECT i.inhparent AS top_parent_oid
        FROM sys_catalog.sys_inherits i
        JOIN sys_catalog.sys_class c ON c.oid = i.inhrelid
        JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname||'.'||c.relname = v_higher_parent
    ) SELECT n.nspname||'.'||c.relname
    INTO v_higher_parent
    FROM sys_catalog.sys_class c
    JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
    JOIN top_oid t ON c.oid = t.top_parent_oid
    JOIN @extschema@.part_config p ON p.parent_table = n.nspname||'.'||c.relname
    WHERE p.partition_type = 'id';

    IF v_higher_parent IS NOT NULL THEN
        -- initially set in DECLARE
        v_top_parent := v_higher_parent;
    END IF;

END LOOP;

-- Loop through child tables starting from highest to get current max value in partition set
-- Avoids doing a scan on entire partition set and/or getting any values accidentally in parent.
FOR v_row_max_id IN
    SELECT partition_schemaname, partition_tablename FROM @extschema@.show_partitions(v_top_parent, 'DESC')
LOOP
        EXECUTE format('SELECT max(%I) FROM %I.%I', v_control, v_row_max_id.partition_schemaname, v_row_max_id.partition_tablename) INTO v_max;
        IF v_max IS NOT NULL THEN
            EXIT;
        END IF;
END LOOP;
IF v_max IS NULL THEN
    v_max := 0;
END IF;
v_current_partition_id = v_max - (v_max % v_partition_interval);
v_next_partition_id := v_current_partition_id + v_partition_interval;
v_current_partition_name := @extschema@.check_name_length(v_parent_tablename, v_current_partition_id::text, TRUE);

v_trig_func := format('CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger LANGUAGE plsql AS $t$ 
    DECLARE
        v_count                     int;
        v_current_partition_id      bigint;
        v_current_partition_name    text;
        v_id_position               int;
        v_last_partition            text := %L;
        v_next_partition_id         bigint;
        v_next_partition_name       text;
        v_partition_created         boolean;
    BEGIN
    IF TG_OP = ''INSERT'' THEN 
        IF NEW.%I >= %s AND NEW.%I < %s THEN '
            , v_parent_schema
            , v_function_name
            , v_last_partition
            , v_control
            , v_current_partition_id
            , v_control
            , v_next_partition_id
        );
        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_current_partition_name;
        IF v_count > 0 THEN
            v_trig_func := v_trig_func || format(' 
            INSERT INTO %I.%I VALUES (NEW.*); ', v_parent_schema, v_current_partition_name);
        ELSE
            v_trig_func := v_trig_func || '
            -- Child table for current values does not exist in this partition set, so write to parent
            RETURN NEW;';
        END IF;

    FOR i IN 1..v_optimize_trigger LOOP
        v_prev_partition_id := v_current_partition_id - (v_partition_interval * i);
        v_next_partition_id := v_current_partition_id + (v_partition_interval * i);
        v_final_partition_id := v_next_partition_id + v_partition_interval;
        v_prev_partition_name := @extschema@.check_name_length(v_parent_tablename, v_prev_partition_id::text, TRUE);
        v_next_partition_name := @extschema@.check_name_length(v_parent_tablename, v_next_partition_id::text, TRUE);

        -- Check that child table exist before making a rule to insert to them.
        -- Handles optimize_trigger being larger than premake (to go back in time further) and edge case of changing optimize_trigger immediately after running create_parent().
        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_prev_partition_name;
        IF v_count > 0 THEN
            -- Only handle previous partitions if they're starting above zero
            IF v_prev_partition_id >= 0 THEN
                v_trig_func := v_trig_func ||format('
        ELSIF NEW.%I >= %s AND NEW.%I < %s THEN 
            INSERT INTO %I.%I VALUES (NEW.*); '
                , v_control
                , v_prev_partition_id
                , v_control
                , v_prev_partition_id + v_partition_interval
                , v_parent_schema
                , v_prev_partition_name
            );
            END IF;
        END IF;

        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname ||'.'||tablename = v_next_partition_name;
        IF v_count > 0 THEN
            v_trig_func := v_trig_func ||format('
        ELSIF NEW.%I >= %s AND NEW.%I < %s THEN 
            INSERT INTO %I.%I VALUES (NEW.*);'
                , v_control
                , v_next_partition_id
                , v_control
                , v_final_partition_id
                , v_parent_schema
                , v_next_partition_name
            );
        END IF;
    END LOOP;
    v_trig_func := v_trig_func ||format('
        ELSE
            v_current_partition_id := NEW.%I - (NEW.%I %% %s);
            v_current_partition_name := @extschema@.check_name_length(%L, v_current_partition_id::text, TRUE);
            SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = %L AND tablename = v_current_partition_name;
            IF v_count > 0 THEN 
                EXECUTE format(''INSERT INTO %%I.%%I VALUES($1.*)'', %L, v_current_partition_name) USING NEW;
            ELSE
                RETURN NEW;
            END IF;
        END IF;'
            , v_control
            , v_control
            , v_partition_interval
            , v_parent_tablename
            , v_parent_schema
            , v_parent_schema
        );

    IF v_run_maint IS FALSE THEN
        v_trig_func := v_trig_func ||format('
        v_current_partition_id := NEW.%I - (NEW.%I %% %s);
        IF (NEW.%I %% %s) > (%s / 2) THEN
            v_id_position := (length(v_last_partition) - position(''p_'' in reverse(v_last_partition))) + 2;
            v_next_partition_id := (substring(v_last_partition from v_id_position)::bigint) + %s;
            WHILE ((v_next_partition_id - v_current_partition_id) / %s) <= %s LOOP 
                v_partition_created := @extschema@.create_partition_id(%L, ARRAY[v_next_partition_id]);
                IF v_partition_created THEN
                    PERFORM @extschema@.create_function_id(%L);
                    PERFORM @extschema@.apply_constraints(%L);
                END IF;
                v_next_partition_id := v_next_partition_id + %s;
            END LOOP;
        END IF;'
            , v_control
            , v_control
            , v_partition_interval
            , v_control
            , v_partition_interval
            , v_partition_interval
            , v_partition_interval
            , v_partition_interval
            , v_premake
            , p_parent_table
            , p_parent_table
            , p_parent_table
            , v_partition_interval
        );
    END IF;

    v_trig_func := v_trig_func ||'
    END IF; 
    RETURN NULL; 
    END $t$;';

EXECUTE v_trig_func;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', format('Added function for current id interval: %s to %s', v_current_partition_id, v_final_partition_id-1));
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE OR REPLACE INTERNAL FUNCTION: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''Partition function maintenance for table %s failed'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Create the trigger function for the parent table of a time-based partition set
 */
CREATE OR REPLACE FUNCTION create_function_time(p_parent_table text, p_job_id bigint DEFAULT NULL) RETURNS void
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_control                       text;
v_count                         int;
v_current_partition_name        text;
v_current_partition_timestamp   timestamptz;
v_datetime_string               text;
v_epoch                         boolean;
v_final_partition_timestamp     timestamptz;
v_function_name                 text;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_old_search_path               text;
v_new_length                    int;
v_next_partition_name           text;
v_next_partition_timestamp      timestamptz;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_interval            interval;
v_prev_partition_name           text;
v_prev_partition_timestamp      timestamptz;
v_step_id                       bigint;
v_trig_func                     text;
v_optimize_trigger              int;
v_type                          text;

BEGIN

SELECT partition_type
    , partition_interval::interval
    , epoch
    , control
    , optimize_trigger
    , datetime_string
    , jobmon
INTO v_type
    , v_partition_interval
    , v_epoch
    , v_control
    , v_optimize_trigger
    , v_datetime_string
    , v_jobmon
FROM @extschema@.part_config 
WHERE parent_table = p_parent_table
AND (partition_type = 'time' OR partition_type = 'time-custom');

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_namespace n, sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF p_job_id IS NULL THEN
        v_job_id := add_job(format('PARTMAN CREATE OR REPLACE INTERNAL FUNCTION: %s', p_parent_table));
    ELSE
        v_job_id = p_job_id;
    END IF;
    v_step_id := add_step(v_job_id, format('Creating partition function for table %s', p_parent_table));
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;

v_function_name := @extschema@.check_name_length(v_parent_tablename, '_part_trig_func', FALSE);

IF v_type = 'time' THEN
    v_trig_func := format('CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger LANGUAGE plsql AS $t$
            DECLARE
            v_count                 int;
            v_partition_name        text;
            v_partition_timestamp   timestamptz;
        BEGIN 
        IF TG_OP = ''INSERT'' THEN 
            '
    , v_parent_schema
    , v_function_name);

    IF v_epoch = false THEN
        CASE
            WHEN v_partition_interval = '15 mins' THEN 
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', NEW.%I) + 
                    ''15min''::interval * floor(date_part(''minute'', NEW.%I) / 15.0);' , v_control , v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP) + 
                    '15min'::interval * floor(date_part('minute', CURRENT_TIMESTAMP) / 15.0);
            WHEN v_partition_interval = '30 mins' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', NEW.%I) + 
                    ''30min''::interval * floor(date_part(''minute'', NEW.%I) / 30.0);' , v_control , v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP) + 
                    '30min'::interval * floor(date_part('minute', CURRENT_TIMESTAMP) / 30.0);
            WHEN v_partition_interval = '1 hour' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP);
             WHEN v_partition_interval = '1 day' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''day'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('day', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 week' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''week'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('week', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 month' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''month'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('month', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '3 months' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''quarter'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('quarter', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 year' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''year'', NEW.%I);', v_control);
                v_current_partition_timestamp := date_trunc('year', CURRENT_TIMESTAMP);
        END CASE;
    ELSE -- epoch is true
        CASE
            WHEN v_partition_interval = '15 mins' THEN 
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', to_timestamp(NEW.%I)) + 
                    ''15min''::interval * floor(date_part(''minute'', NEW.%I) / 15.0);' , v_control , v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP) + 
                    '15min'::interval * floor(date_part('minute', CURRENT_TIMESTAMP) / 15.0);
            WHEN v_partition_interval = '30 mins' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', to_timestamp(NEW.%I)) + 
                    ''30min''::interval * floor(date_part(''minute'', NEW.%I) / 30.0);' , v_control , v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP) + 
                    '30min'::interval * floor(date_part('minute', CURRENT_TIMESTAMP) / 30.0);
            WHEN v_partition_interval = '1 hour' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''hour'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('hour', CURRENT_TIMESTAMP);
             WHEN v_partition_interval = '1 day' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''day'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('day', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 week' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''week'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('week', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 month' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''month'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('month', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '3 months' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''quarter'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('quarter', CURRENT_TIMESTAMP);
            WHEN v_partition_interval = '1 year' THEN
                v_trig_func := v_trig_func||format('v_partition_timestamp := date_trunc(''year'', to_timestamp(NEW.%I));', v_control);
                v_current_partition_timestamp := date_trunc('year', CURRENT_TIMESTAMP);
        END CASE;
    END IF;

    v_current_partition_name := @extschema@.check_name_length(v_parent_tablename, to_char(v_current_partition_timestamp, v_datetime_string), TRUE); 
    v_next_partition_timestamp := v_current_partition_timestamp + v_partition_interval::interval;

    IF v_epoch = false THEN
        v_trig_func := v_trig_func ||format('
            IF NEW.%I >= %L AND NEW.%I < %L THEN '
                , v_control
                , v_current_partition_timestamp
                , v_control
                , v_next_partition_timestamp);
    ELSE
        v_trig_func := v_trig_func ||format('
            IF to_timestamp(NEW.%I) >= %L AND to_timestamp(NEW.%I) < %L THEN '
                , v_control
                , v_current_partition_timestamp
                , v_control
                , v_next_partition_timestamp);
    END IF;
        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_current_partition_name;
        IF v_count > 0 THEN
            v_trig_func := v_trig_func || format('
                INSERT INTO %I.%I VALUES (NEW.*); ', v_parent_schema, v_current_partition_name);
        ELSE
            v_trig_func := v_trig_func || '
                -- Child table for current values does not exist in this partition set, so write to parent
                RETURN NEW;';
        END IF;
    FOR i IN 1..v_optimize_trigger LOOP
        v_prev_partition_timestamp := v_current_partition_timestamp - (v_partition_interval::interval * i);
        v_next_partition_timestamp := v_current_partition_timestamp + (v_partition_interval::interval * i);
        v_final_partition_timestamp := v_next_partition_timestamp + (v_partition_interval::interval);
        v_prev_partition_name := @extschema@.check_name_length(v_parent_tablename, to_char(v_prev_partition_timestamp, v_datetime_string), TRUE);
        v_next_partition_name := @extschema@.check_name_length(v_parent_tablename, to_char(v_next_partition_timestamp, v_datetime_string), TRUE);

        -- Check that child table exist before making a rule to insert to them.
        -- Handles optimize_trigger being larger than premake (to go back in time further) and edge case of changing optimize_trigger immediately after running create_parent().
        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_prev_partition_name;
        IF v_count > 0 THEN
            IF v_epoch = false THEN
                v_trig_func := v_trig_func ||format('
            ELSIF NEW.%I >= %L AND NEW.%I < %L THEN 
                INSERT INTO %I.%I VALUES (NEW.*);'
                    , v_control
                    , v_prev_partition_timestamp
                    , v_control
                    , v_prev_partition_timestamp + v_partition_interval::interval
                    , v_parent_schema
                    , v_prev_partition_name);
            ELSE
                v_trig_func := v_trig_func ||format('
            ELSIF to_timestamp(NEW.%I) >= %L AND to_timestamp(NEW.%I) < %L THEN 
                INSERT INTO %I.%I VALUES (NEW.*);'
                    , v_control
                    , v_prev_partition_timestamp
                    , v_control
                    , v_prev_partition_timestamp + v_partition_interval::interval
                    , v_parent_schema
                    , v_prev_partition_name);

            END IF;
        END IF;
        SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_next_partition_name;
        IF v_count > 0 THEN
            IF v_epoch = false THEN
                v_trig_func := v_trig_func ||format(' 
            ELSIF NEW.%I >= %L AND NEW.%I < %L THEN 
                INSERT INTO %I.%I VALUES (NEW.*);'
                    , v_control
                    , v_next_partition_timestamp
                    , v_control
                    , v_final_partition_timestamp
                    , v_parent_schema
                    , v_next_partition_name);
            ELSE
                v_trig_func := v_trig_func ||format(' 
            ELSIF to_timestamp(NEW.%I) >= %L AND to_timestamp(NEW.%I) < %L THEN 
                INSERT INTO %I.%I VALUES (NEW.*);'
                    , v_control
                    , v_next_partition_timestamp
                    , v_control
                    , v_final_partition_timestamp
                    , v_parent_schema
                    , v_next_partition_name);

            END IF;
        END IF;

    END LOOP;

    v_trig_func := v_trig_func||format('
            ELSE
                v_partition_name := @extschema@.check_name_length(%L, to_char(v_partition_timestamp, %L), TRUE);
                SELECT count(*) INTO v_count FROM sys_catalog.sys_tables WHERE schemaname = %L AND tablename = v_partition_name;
                IF v_count > 0 THEN 
                    EXECUTE format(''INSERT INTO %%I.%%I VALUES($1.*)'', %L, v_partition_name) USING NEW;
                ELSE
                    RETURN NEW;
                END IF;
            END IF;'
            , v_parent_tablename
            , v_datetime_string
            , v_parent_schema
            , v_parent_schema);

    v_trig_func := v_trig_func ||'
        END IF; 
        RETURN NULL; 
        END $t$;';

    EXECUTE v_trig_func;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Added function for current time interval: %s to %s' 
                                                        , v_current_partition_timestamp
                                                        , v_final_partition_timestamp-'1sec'::interval));
    END IF;

ELSIF v_type = 'time-custom' THEN

    v_trig_func := format('CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger LANGUAGE plsql AS $t$ 
        DECLARE
            v_child_schemaname  text;
            v_child_table       text;
            v_child_tablename   text;
        BEGIN
            '
        , v_parent_schema
        , v_function_name);

    IF v_epoch = false THEN
        v_trig_func := v_trig_func || format(' 

        SELECT child_table INTO v_child_table
        FROM @extschema@.custom_time_partitions 
        WHERE partition_range @> NEW.%I 
        AND parent_table = %L;'
        , v_control
        , v_parent_schema||'.'||v_parent_tablename);

    ELSE -- epoch true
        v_trig_func := v_trig_func || format(' 

        SELECT child_table INTO v_child_table
        FROM @extschema@.custom_time_partitions 
        WHERE partition_range @> to_timestamp(NEW.%I)
        AND parent_table = %L;'
        , v_control
        , v_parent_schema||'.'||v_parent_tablename);

    END IF;

    v_trig_func := v_trig_func || '

        SELECT schemaname, tablename INTO v_child_schemaname, v_child_tablename FROM sys_catalog.sys_tables WHERE schemaname ||''.''|| tablename = v_child_table;
        IF v_child_schemaname IS NOT NULL AND v_child_tablename IS NOT NULL THEN
            EXECUTE format(''INSERT INTO %I.%I VALUES ($1.*)'', v_child_schemaname, v_child_tablename) USING NEW;
        ELSE
            RETURN NEW;
        END IF;

        RETURN NULL; 
        END $t$;';

    EXECUTE v_trig_func;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Added function for custom time table: %s', p_parent_table));
    END IF;

ELSE
    RAISE EXCEPTION 'ERROR: Invalid time partitioning type given: %', v_type;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE OR REPLACE INTERNAL FUNCTION: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''Partition function maintenance for table %s failed'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Apply constraints managed by partman extension
 */
CREATE OR REPLACE FUNCTION apply_constraints(p_parent_table text, p_child_table text DEFAULT NULL, p_analyze boolean DEFAULT FALSE, p_job_id bigint DEFAULT NULL, p_debug boolean DEFAULT FALSE) RETURNS void
    LANGUAGE plsql
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_child_table                   text;
v_child_tablename               text;
v_col                           text;
v_constraint_cols               text[];
v_constraint_col_type           text;
v_constraint_name               text;
v_constraint_values             record;
v_control                       text;
v_datetime_string               text;
v_epoch                         boolean;
v_existing_constraint_name      text;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_last_partition                text;
v_last_partition_id             int; 
v_last_partition_timestamp      timestamp;
v_max_id                        bigint;
v_max_timestamp                 timestamp;
v_old_search_path               text;
v_optimize_constraint           int;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_interval            text;
v_partition_suffix              text;
v_row_max                       record;
v_sql                           text;
v_step_id                       bigint;
v_suffix_position               int;
v_type                          text;

BEGIN

SELECT partition_type
    , control
    , epoch
    , partition_interval
    , optimize_constraint
    , datetime_string
    , constraint_cols
    , jobmon
INTO v_type
    , v_control
    , v_epoch
    , v_partition_interval
    , v_optimize_constraint
    , v_datetime_string
    , v_constraint_cols
    , v_jobmon
FROM @extschema@.part_config
WHERE parent_table = p_parent_table
AND constraint_cols IS NOT NULL;

IF v_constraint_cols IS NULL THEN
    IF p_debug THEN
        RAISE NOTICE 'Given parent table (%) not set up for constraint management (constraint_cols is NULL)', p_parent_table;
    END IF;
    -- Returns silently to allow this function to be simply called by maintenance processes without having to check if config options are set.
    RETURN;
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_catalog.sys_namespace n, sys_catalog.sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF p_job_id IS NULL THEN
        v_job_id := add_job(format('PARTMAN CREATE CONSTRAINT: %s', p_parent_table));
    ELSE
        v_job_id = p_job_id;
    END IF;
END IF;

-- If p_child_table is null, figure out the partition that is the one right before the optimize_constraint value backwards.
IF p_child_table IS NULL THEN
    -- Loop through child tables starting from highest to get current max value in partition set
    -- Avoids doing a scan on entire partition set and/or getting any values accidentally in parent.
    FOR v_row_max IN
        SELECT partition_schemaname, partition_tablename FROM @extschema@.show_partitions(p_parent_table, 'DESC')
    LOOP
        IF (v_type = 'time' OR v_type = 'time-custom') THEN
            IF v_epoch = false THEN
                EXECUTE format('SELECT max(%I) FROM %I.%I', v_control, v_row_max.partition_schemaname, v_row_max.partition_tablename) INTO v_max_timestamp;
            ELSE
                EXECUTE format('SELECT to_timestamp(max(%I)) FROM %I.%I', v_control, v_row_max.partition_schemaname, v_row_max.partition_tablename) INTO v_max_timestamp;
            END IF;
            IF v_max_timestamp IS NOT NULL THEN
                SELECT suffix_timestamp FROM @extschema@.show_partition_name(p_parent_table, v_max_timestamp::text) INTO v_last_partition_timestamp;
                v_partition_suffix := to_char(v_last_partition_timestamp - (v_partition_interval::interval * (v_optimize_constraint + 1) ), v_datetime_string);
                EXIT;
            END IF;
        ELSIF v_type = 'id' THEN
            EXECUTE format('SELECT max(%I) FROM %I.%I', v_control, v_row_max.partition_schemaname, v_row_max.partition_tablename) INTO v_max_id;
            IF v_max_id IS NOT NULL THEN
                SELECT suffix_id FROM @extschema@.show_partition_name(p_parent_table, v_max_id::text) INTO v_last_partition_id;
                v_last_partition_id := v_last_partition_id - (v_partition_interval::int * (v_optimize_constraint + 1) );
                IF v_last_partition_id < 0 THEN
                    v_last_partition_id := 0;
                END IF;
                v_partition_suffix := v_last_partition_id::text; 
                EXIT;
            END IF;
        ELSE
            RAISE EXCEPTION 'Unknown type encountered in apply_constraints()';
        END IF;
        IF p_debug THEN
            RAISE NOTICE 'apply_constraint: p_parent_table: %, partition_schemaname: %, partition_tablename: %', p_parent_table , v_row_max.partition_schemaname, v_row_max.partition_tablename;
        END IF;
    END LOOP;
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Applying additional constraints: Automatically determining most recent child on which to apply constraints');
    END IF;
    IF p_debug THEN
        RAISE NOTICE 'apply_constraint: v_parent_tablename: % , v_partition_suffix: %', v_parent_tablename, v_partition_suffix;
    END IF;
    IF v_partition_suffix IS NULL THEN
        IF p_debug THEN
            RAISE NOTICE 'No values for control column found in any child table. Unable to automatically determine which child table to apply additional constraints to';
        END IF;
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'WARNING', 'No values for control column found in any child table. Unable to automatically determine which child table to apply additional constraints to');
            IF p_job_id IS NULL THEN
                -- If not part of a sub-job, fail this one with a warning
                PERFORM fail_job(v_job_id, 2);
            END IF;
        END IF;
        -- Return cleanly so that if maintenance calls under this condition it produces no errors that will interfere with other partition sets.
        RETURN;
    END IF;

    v_child_table := v_parent_schema ||'.'|| @extschema@.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Target child table: %s.%s', v_parent_schema, v_child_table));
    END IF;
ELSE
    v_child_table := p_child_table;
END IF;
    
IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Applying additional constraints: Checking if target child table exists');
END IF;

SELECT tablename INTO v_child_tablename FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = v_child_table;
IF v_child_tablename IS NULL THEN
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'NOTICE', format('Target child table (%s) does not exist. Skipping constraint creation.', v_child_table));
        IF p_job_id IS NULL THEN
            PERFORM close_job(v_job_id);
        END IF;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
    END IF;
    IF p_debug THEN
        RAISE NOTICE 'Target child table (%) does not exist. Skipping constraint creation.', v_child_table;
    END IF;
    RETURN;
ELSE
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

FOREACH v_col IN ARRAY v_constraint_cols
LOOP
    SELECT con.conname
    INTO v_existing_constraint_name
    FROM sys_catalog.sys_constraint con
    JOIN sys_class c ON c.oid = con.conrelid
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    JOIN sys_catalog.sys_attribute a ON con.conrelid = a.attrelid 
    WHERE c.relname = v_child_tablename
        AND n.nspname = v_parent_schema
        AND con.conname LIKE 'partmanconstr_%'
        AND con.contype = 'c' 
        AND a.attname = v_col
        AND ARRAY[a.attnum] <@ con.conkey 
        AND a.attisdropped = false;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Applying additional constraints: Applying new constraint on column: %s', v_col));
    END IF;

    IF v_existing_constraint_name IS NOT NULL THEN
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'NOTICE', format('Partman managed constraint already exists on this table (%s) and column (%s). Skipping creation.', v_child_table, v_col));
        END IF;
        IF p_debug THEN
            RAISE NOTICE 'Partman managed constraint already exists on this table (%) and column (%). Skipping creation.', v_child_table, v_col ;
        END IF;
        CONTINUE;
    END IF;

    -- Ensure column name gets put on end of constraint name to help avoid naming conflicts 
    v_constraint_name := @extschema@.check_name_length('partmanconstr_'||v_child_tablename, p_suffix := '_'||v_col);

    EXECUTE format('SELECT min(%I)::text AS min, max(%I)::text AS max FROM %I.%I', v_col, v_col, v_parent_schema, v_child_tablename) INTO v_constraint_values;

    IF v_constraint_values IS NOT NULL THEN
        v_sql := format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I >= %L AND %I <= %L)'
                            , v_parent_schema
                            , v_child_tablename
                            , v_constraint_name
                            , v_col
                            , v_constraint_values.min
                            , v_col
                            , v_constraint_values.max);
        IF p_debug THEN
            RAISE NOTICE 'Constraint creation query: %', v_sql;
        END IF;
        EXECUTE v_sql;

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', format('New constraint created: %s', v_sql));
        END IF;
    ELSE
        IF p_debug THEN
            RAISE NOTICE 'Given column (%) contains all NULLs. No constraint created', v_col;
        END IF;
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'NOTICE', format('Given column (%s) contains all NULLs. No constraint created', v_col));
        END IF;
    END IF;

END LOOP;

IF p_analyze THEN
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Applying additional constraints: Running analyze on partition set: %s', p_parent_table));
    END IF;
    IF p_debug THEN
        RAISE NOTICE 'Running analyze on partition set: %', p_parent_table;
    END IF;

    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE CONSTRAINT: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Function to turn a table into the parent of a partition set
 */
CREATE OR REPLACE FUNCTION create_parent(
    p_parent_table text
    , p_control text
    , p_type text
    , p_interval text
    , p_constraint_cols text[] DEFAULT NULL 
    , p_premake int DEFAULT 4
    , p_use_run_maintenance boolean DEFAULT NULL
    , p_start_partition text DEFAULT NULL
    , p_inherit_fk boolean DEFAULT true
    , p_epoch boolean DEFAULT false
    , p_jobmon boolean DEFAULT true
    , p_debug boolean DEFAULT false) 
RETURNS boolean 
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_base_timestamp                timestamp;
v_count                         int := 1;
v_datetime_string               text;
v_higher_parent                 text := p_parent_table;
v_id_interval                   bigint;
v_id_position                   int;
v_job_id                        bigint;
v_jobmon_schema                 text;
v_last_partition_created        boolean;
v_max                           bigint;
v_notnull                       boolean;
v_old_search_path               text;
v_parent_partition_id           bigint;
v_parent_partition_timestamp    timestamp;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_time                timestamp;
v_partition_time_array          timestamp[];
v_partition_id_array            bigint[];
v_row                           record;
v_run_maint                     boolean;
v_sql                           text;
v_start_time                    timestamp;
v_starting_partition_id         bigint;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_sub_parent                    text;
v_success                       boolean := false;
v_time_interval                 interval;
v_time_position                 int;
v_top_datetime_string           text;
v_top_parent                    text := p_parent_table;
v_top_schemaname                text;
v_top_tablename                 text;

BEGIN

IF position('.' in p_parent_table) = 0  THEN
    RAISE EXCEPTION 'Parent table must be schema qualified';
END IF;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname || '.' || tablename = p_parent_table;
    IF v_parent_tablename IS NULL THEN
        RAISE EXCEPTION 'Please create given parent table first: %', p_parent_table;
    END IF;

SELECT attnotnull INTO v_notnull 
FROM sys_catalog.sys_attribute a
JOIN sys_catalog.sys_class c ON a.attrelid = c.oid
JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
WHERE c.relname = v_parent_tablename
AND n.nspname = v_parent_schema
AND a.attname = p_control;
    IF v_notnull = false OR v_notnull IS NULL THEN
        RAISE EXCEPTION 'Control column given (%) for parent table (%) does not exist or must be set to NOT NULL', p_control, p_parent_table;
    END IF;

IF p_type = 'id' AND p_epoch = true THEN
    RAISE EXCEPTION 'p_epoch can only be used with time-based partitioning';
END IF;

IF NOT @extschema@.check_partition_type(p_type) THEN
    RAISE EXCEPTION '% is not a valid partitioning type', p_type;
END IF;

EXECUTE format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE', v_parent_schema, v_parent_tablename);

IF p_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_namespace n, sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF p_use_run_maintenance IS NOT NULL THEN
    IF p_use_run_maintenance IS FALSE AND (p_type = 'time' OR p_type = 'time-custom') THEN
        RAISE EXCEPTION 'p_run_maintenance cannot be set to false for time based partitioning';
    END IF;
    v_run_maint := p_use_run_maintenance;
ELSIF p_type = 'time' OR p_type = 'time-custom' THEN
    v_run_maint := TRUE;
ELSIF p_type = 'id' THEN
    v_run_maint := FALSE;
ELSE
    RAISE EXCEPTION 'use_run_maintenance value cannot be set NULL';
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN SETUP PARENT: %s', p_parent_table));
    v_step_id := add_step(v_job_id, format('Creating initial partitions on new parent table: %s', p_parent_table));
END IF;

-- If this parent table has siblings that are also partitioned (subpartitions), ensure this parent gets added to part_config_sub table so future maintenance will subpartition it
-- Just doing in a loop to avoid having to assign a bunch of variables (should only run once, if at all; constraint should enforce only one value.)
FOR v_row IN 
    WITH parent_table AS (
        SELECT h.inhparent AS parent_oid
        FROM sys_catalog.sys_inherits h
        JOIN sys_catalog.sys_class c ON h.inhrelid = c.oid
        JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
        WHERE c.relname = v_parent_tablename
        AND n.nspname = v_parent_schema
    ), sibling_children AS (
        SELECT i.inhrelid::regclass::text AS tablename 
        FROM sys_inherits i
        JOIN parent_table p ON i.inhparent = p.parent_oid
    )
    SELECT DISTINCT sub_partition_type
        , sub_control
        , sub_partition_interval
        , sub_constraint_cols
        , sub_premake
        , sub_inherit_fk
        , sub_retention
        , sub_retention_schema
        , sub_retention_keep_table
        , sub_retention_keep_index
        , sub_use_run_maintenance
        , sub_epoch
        , sub_optimize_trigger
        , sub_optimize_constraint
        , sub_jobmon
    FROM @extschema@.part_config_sub a
    JOIN sibling_children b on a.sub_parent = b.tablename LIMIT 1
LOOP
    INSERT INTO @extschema@.part_config_sub (
        sub_parent
        , sub_partition_type
        , sub_control
        , sub_partition_interval
        , sub_constraint_cols
        , sub_premake
        , sub_inherit_fk
        , sub_retention
        , sub_retention_schema
        , sub_retention_keep_table
        , sub_retention_keep_index
        , sub_use_run_maintenance
        , sub_epoch
        , sub_optimize_trigger
        , sub_optimize_constraint
        , sub_jobmon)
    VALUES (
        p_parent_table
        , v_row.sub_partition_type
        , v_row.sub_control
        , v_row.sub_partition_interval
        , v_row.sub_constraint_cols
        , v_row.sub_premake
        , v_row.sub_inherit_fk
        , v_row.sub_retention
        , v_row.sub_retention_schema
        , v_row.sub_retention_keep_table
        , v_row.sub_retention_keep_index
        , v_row.sub_use_run_maintenance
        , v_row.sub_epoch
        , v_row.sub_optimize_trigger
        , v_row.sub_optimize_constraint
        , v_row.sub_jobmon);
END LOOP;

IF p_type = 'time' OR p_type = 'time-custom' THEN

    CASE
        WHEN p_interval = 'yearly' THEN
            v_time_interval := '1 year';
        WHEN p_interval = 'quarterly' THEN
            v_time_interval := '3 months';
        WHEN p_interval = 'monthly' THEN
            v_time_interval := '1 month';
        WHEN p_interval  = 'weekly' THEN
            v_time_interval := '1 week';
        WHEN p_interval = 'daily' THEN
            v_time_interval := '1 day';
        WHEN p_interval = 'hourly' THEN
            v_time_interval := '1 hour';
        WHEN p_interval = 'half-hour' THEN
            v_time_interval := '30 mins';
        WHEN p_interval = 'quarter-hour' THEN
            v_time_interval := '15 mins';
        ELSE
            IF p_type <> 'time-custom' THEN
                RAISE EXCEPTION 'Must use a predefined time interval if not using type "time-custom". See documentation.';
            END IF;
            v_time_interval := p_interval::interval;
            IF v_time_interval < '1 second'::interval THEN
                RAISE EXCEPTION 'Partitioning interval must be 1 second or greater';
            END IF;
    END CASE;

    -- First partition is either the min premake or p_start_partition
    v_start_time := COALESCE(p_start_partition::timestamp, CURRENT_TIMESTAMP - (v_time_interval * p_premake));

    IF v_time_interval >= '1 year' THEN
        v_base_timestamp := date_trunc('year', v_start_time);
        IF v_time_interval >= '10 years' THEN
            v_base_timestamp := date_trunc('decade', v_start_time);
            IF v_time_interval >= '100 years' THEN
                v_base_timestamp := date_trunc('century', v_start_time);
                IF v_time_interval >= '1000 years' THEN
                    v_base_timestamp := date_trunc('millennium', v_start_time);
                END IF; -- 1000
            END IF; -- 100
        END IF; -- 10
    END IF; -- 1

    v_datetime_string := 'YYYY';
    IF v_time_interval < '1 year' THEN
        IF p_interval = 'quarterly' THEN
            v_base_timestamp := date_trunc('quarter', v_start_time);
            v_datetime_string = 'YYYY"q"Q';
        ELSE
            v_base_timestamp := date_trunc('month', v_start_time); 
            v_datetime_string := v_datetime_string || '_MM';
        END IF;
        IF v_time_interval < '1 month' THEN
            IF p_interval = 'weekly' THEN
                v_base_timestamp := date_trunc('week', v_start_time);
                v_datetime_string := 'IYYY"w"IW';
            ELSE 
                v_base_timestamp := date_trunc('day', v_start_time);
                v_datetime_string := v_datetime_string || '_DD';
            END IF;
            IF v_time_interval < '1 day' THEN
                v_base_timestamp := date_trunc('hour', v_start_time);
                v_datetime_string := v_datetime_string || '_HH24MI';
                IF v_time_interval < '1 minute' THEN
                    v_base_timestamp := date_trunc('minute', v_start_time);
                    v_datetime_string := v_datetime_string || 'SS';
                END IF; -- minute
            END IF; -- day
        END IF; -- month
    END IF; -- year

    v_partition_time_array := array_append(v_partition_time_array, v_base_timestamp);
    LOOP
        -- If current loop value is less than or equal to the value of the max premake, add time to array.
        IF (v_base_timestamp + (v_time_interval * v_count)) < (CURRENT_TIMESTAMP + (v_time_interval * p_premake)) THEN
            BEGIN
                v_partition_time := (v_base_timestamp + (v_time_interval * v_count))::timestamp;
                v_partition_time_array := array_append(v_partition_time_array, v_partition_time);
            EXCEPTION WHEN datetime_field_overflow THEN
                RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range. 
                    Child partition creation after time % skipped', v_partition_time;
                v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
                PERFORM update_step(v_step_overflow_id, 'CRITICAL', 'Child partition creation after time '||v_partition_time||' skipped');
                CONTINUE;
            END;
        ELSE
            EXIT; -- all needed partitions added to array. Exit the loop.
        END IF;
        v_count := v_count + 1;
    END LOOP;

    INSERT INTO @extschema@.part_config (
        parent_table
        , partition_type
        , partition_interval
        , epoch
        , control
        , premake
        , constraint_cols
        , datetime_string
        , use_run_maintenance
        , inherit_fk
        , jobmon) 
    VALUES (
        p_parent_table
        , p_type
        , v_time_interval
        , p_epoch
        , p_control
        , p_premake
        , p_constraint_cols
        , v_datetime_string
        , v_run_maint
        , p_inherit_fk
        , p_jobmon);
    v_last_partition_created := @extschema@.create_partition_time(p_parent_table, v_partition_time_array, false);

    IF v_last_partition_created = false THEN 
        -- This can happen with subpartitioning when future or past partitions prevent child creation because they're out of range of the parent
        -- First see if this parent is a subpartition managed by sys_partman
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM sys_catalog.sys_inherits i
            JOIN sys_catalog.sys_class c ON c.oid = i.inhrelid
            JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = v_parent_tablename
            AND n.nspname = v_parent_schema
        ) SELECT n.nspname||'.'||c.relname, p.datetime_string
        INTO v_top_parent, v_top_datetime_string
        FROM sys_catalog.sys_class c
        JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN @extschema@.part_config p ON p.parent_table = n.nspname||'.'||c.relname;
        IF v_top_parent IS NOT NULL THEN
            -- If so create the lowest possible partition that is within the boundary of the parent
            v_time_position := (length(p_parent_table) - position('p_' in reverse(p_parent_table))) + 2;
            v_parent_partition_timestamp := to_timestamp(substring(p_parent_table from v_time_position), v_top_datetime_string);
            IF v_base_timestamp >= v_parent_partition_timestamp THEN
                WHILE v_base_timestamp >= v_parent_partition_timestamp LOOP
                    v_base_timestamp := v_base_timestamp - v_time_interval;
                END LOOP;
                v_base_timestamp := v_base_timestamp + v_time_interval; -- add one back since while loop set it one lower than is needed
            ELSIF v_base_timestamp < v_parent_partition_timestamp THEN
                WHILE v_base_timestamp < v_parent_partition_timestamp LOOP
                    v_base_timestamp := v_base_timestamp + v_time_interval;
                END LOOP;
                -- Don't need to remove one since new starting time will fit in top parent interval
            END IF;
            v_partition_time_array := NULL;
            v_partition_time_array := array_append(v_partition_time_array, v_base_timestamp);
            v_last_partition_created := @extschema@.create_partition_time(p_parent_table, v_partition_time_array, false);
        ELSE
            -- Currently unknown edge case if code gets here
            RAISE EXCEPTION 'No child tables created. Unexpected edge case encountered. Please report this error to author with conditions that led to it.';
        END IF; 
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', format('Time partitions premade: %s', p_premake));
    END IF;
END IF;

IF p_type = 'id' THEN
    v_id_interval := p_interval::bigint;
    IF v_id_interval < 10 THEN
        RAISE EXCEPTION 'Interval for serial partitioning must be greater than or equal to 10';
    END IF;

    -- Check if parent table is a subpartition of an already existing id partition set managed by sys_partman. 
    WHILE v_higher_parent IS NOT NULL LOOP -- initially set in DECLARE
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM sys_catalog.sys_inherits i
            JOIN sys_catalog.sys_class c ON c.oid = i.inhrelid
            JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname||'.'||c.relname = v_higher_parent
        ) SELECT n.nspname||'.'||c.relname
        INTO v_higher_parent
        FROM sys_catalog.sys_class c
        JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN @extschema@.part_config p ON p.parent_table = n.nspname||'.'||c.relname
        WHERE p.partition_type = 'id';

        IF v_higher_parent IS NOT NULL THEN
            -- v_top_parent initially set in DECLARE
            v_top_parent := v_higher_parent;
        END IF;
    END LOOP;

    -- If custom start partition is set, use that.
    -- If custom start is not set and there is already data, start partitioning with the highest current value and ensure it's grabbed from highest top parent table
    SELECT schemaname, tablename INTO v_top_schemaname, v_top_tablename FROM sys_catalog.sys_tables WHERE schemaname||'.'||tablename = v_top_parent;
    v_sql := format('SELECT COALESCE(%L, max(%I)::bigint, 0) FROM %I.%I LIMIT 1'
                , p_start_partition::bigint
                , p_control
                , v_top_schemaname
                , v_top_tablename);
    EXECUTE v_sql INTO v_max;
    v_starting_partition_id := v_max - (v_max % v_id_interval);
    FOR i IN 0..p_premake LOOP
        -- Only make previous partitions if ID value is less than the starting value and positive (and custom start partition wasn't set)
        IF p_start_partition IS NULL AND 
            (v_starting_partition_id - (v_id_interval*i)) > 0 AND 
            (v_starting_partition_id - (v_id_interval*i)) < v_starting_partition_id 
        THEN
            v_partition_id_array = array_append(v_partition_id_array, (v_starting_partition_id - v_id_interval*i));
        END IF; 
        v_partition_id_array = array_append(v_partition_id_array, (v_id_interval*i) + v_starting_partition_id);
    END LOOP;

    INSERT INTO @extschema@.part_config (
        parent_table
        , partition_type
        , partition_interval
        , control
        , premake
        , constraint_cols
        , use_run_maintenance
        , inherit_fk
        , jobmon) 
    VALUES (
        p_parent_table
        , p_type
        , v_id_interval
        , p_control
        , p_premake
        , p_constraint_cols
        , v_run_maint
        , p_inherit_fk
        , p_jobmon);
    v_last_partition_created := @extschema@.create_partition_id(p_parent_table, v_partition_id_array, false);
    IF v_last_partition_created = false THEN
        -- This can happen with subpartitioning when future or past partitions prevent child creation because they're out of range of the parent
        -- See if it's actually a subpartition of a parent id partition
        WITH top_oid AS (
            SELECT i.inhparent AS top_parent_oid
            FROM sys_catalog.sys_inherits i
            JOIN sys_catalog.sys_class c ON c.oid = i.inhrelid
            JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = v_parent_tablename
            AND n.nspname = v_parent_schema
        ) SELECT n.nspname||'.'||c.relname
        INTO v_top_parent
        FROM sys_catalog.sys_class c
        JOIN sys_catalog.sys_namespace n ON n.oid = c.relnamespace
        JOIN top_oid t ON c.oid = t.top_parent_oid
        JOIN @extschema@.part_config p ON p.parent_table = n.nspname||'.'||c.relname
        WHERE p.partition_type = 'id';
        IF v_top_parent IS NOT NULL THEN
            -- Create the lowest possible partition that is within the boundary of the parent
            v_id_position := (length(p_parent_table) - position('p_' in reverse(p_parent_table))) + 2;
            v_parent_partition_id = substring(p_parent_table from v_id_position)::bigint;
            IF v_starting_partition_id >= v_parent_partition_id THEN
                WHILE v_starting_partition_id >= v_parent_partition_id LOOP
                    v_starting_partition_id := v_starting_partition_id - v_id_interval;
                END LOOP;
                v_starting_partition_id := v_starting_partition_id + v_id_interval; -- add one back since while loop set it one lower than is needed
            ELSIF v_starting_partition_id < v_parent_partition_id THEN
                WHILE v_starting_partition_id < v_parent_partition_id LOOP
                    v_starting_partition_id := v_starting_partition_id + v_id_interval;
                END LOOP;
                -- Don't need to remove one since new starting id will fit in top parent interval
            END IF;
            v_partition_id_array = NULL;
            v_partition_id_array = array_append(v_partition_id_array, v_starting_partition_id);
            v_last_partition_created := @extschema@.create_partition_id(p_parent_table, v_partition_id_array, false);
        ELSE
            -- Currently unknown edge case if code gets here
            RAISE EXCEPTION 'No child tables created. Unexpected edge case encountered. Please report this error to author with conditions that led to it.';
        END IF;
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Creating partition function');
END IF;
IF p_type = 'time' OR p_type = 'time-custom' THEN
    PERFORM @extschema@.create_function_time(p_parent_table, v_job_id);
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Time function created');
    END IF;
ELSIF p_type = 'id' THEN
    PERFORM @extschema@.create_function_id(p_parent_table, v_job_id);  
    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'ID function created');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Creating partition trigger');
END IF;
PERFORM @extschema@.create_trigger(p_parent_table);

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', 'Done');
    IF v_step_overflow_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

v_success := true;

RETURN v_success;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE PARENT: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''Partition creation for table '||p_parent_table||' failed'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Create a partition set that is a subpartition of an already existing partition set.
 * Given the parent table of any current partition set, it will turn all existing children into parent tables of their own partition sets
 *      using the configuration options given as parameters to this function.
 * Uses another config table that allows for turning all future child partitions into a new parent automatically.
 * To avoid logical complications and contention issues, ALL subpartitions must be maintained using run_maintenance().
 * This means the automatic, trigger based partition creation for serial partitioning will not work if it is a subpartition.
 */
CREATE OR REPLACE INTERNAL FUNCTION create_sub_parent(
    p_top_parent text
    , p_control text
    , p_type text
    , p_interval text
    , p_constraint_cols text[] DEFAULT NULL 
    , p_premake int DEFAULT 4
    , p_start_partition text DEFAULT NULL
    , p_inherit_fk boolean DEFAULT true
    , p_epoch boolean DEFAULT false
    , p_jobmon boolean DEFAULT true
    , p_debug boolean DEFAULT false) 
RETURNS boolean
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

v_last_partition    text;
v_row               record;
v_row_last_part     record;
v_run_maint         boolean;
v_sql               text;
v_success           boolean := false;
v_top_type          text;

BEGIN

SELECT use_run_maintenance INTO v_run_maint FROM @extschema@.part_config WHERE parent_table = p_top_parent;
IF v_run_maint IS NULL THEN
    RAISE EXCEPTION 'Cannot subpartition a table that is not managed by sys_partman already. Given top parent table not found in @extschema@.part_config: %', p_top_parent;
ELSIF v_run_maint = false THEN
    RAISE EXCEPTION 'Any parent table that will be part of a sub-partitioned set (on any level) must have use_run_maintenance set to true in part_config table, even for serial partitioning. See documentation for more info.';
END IF;

FOR v_row IN 
    -- Loop through all current children to turn them into partitioned tables
    SELECT partition_schemaname||'.'||partition_tablename AS child_table FROM @extschema@.show_partitions(p_top_parent)
LOOP
    -- Just call existing create_parent() function but add the given parameters to the part_config_sub table as well
    v_sql := format('SELECT @extschema@.create_parent(
             p_parent_table := %L
            , p_control := %L
            , p_type := %L
            , p_interval := %L
            , p_constraint_cols := %L
            , p_premake := %L
            , p_use_run_maintenance := %L
            , p_start_partition := %L
            , p_inherit_fk := %L
            , p_epoch := %L
            , p_jobmon := %L
            , p_debug := %L )'
        , v_row.child_table
        , p_control
        , p_type
        , p_interval
        , p_constraint_cols
        , p_premake
        , true
        , p_start_partition
        , p_inherit_fk
        , p_epoch
        , p_jobmon
        , p_debug);
    EXECUTE v_sql;

END LOOP;

INSERT INTO @extschema@.part_config_sub (
    sub_parent
    , sub_control
    , sub_partition_type
    , sub_partition_interval
    , sub_constraint_cols
    , sub_premake
    , sub_inherit_fk
    , sub_use_run_maintenance
    , sub_epoch
    , sub_jobmon)
VALUES (
    p_top_parent
    , p_control
    , p_type
    , p_interval
    , p_constraint_cols
    , p_premake
    , p_inherit_fk
    , true
    , p_epoch
    , p_jobmon);

v_success := true;

RETURN v_success;

END
$$;


/*
 * Function to create a child table in a time-based partition set
 */
CREATE OR REPLACE FUNCTION create_partition_time (p_parent_table text, p_partition_times timestamp[], p_analyze boolean DEFAULT true) 
RETURNS boolean
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_all                           text[] := ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'];
v_analyze                       boolean := FALSE;
v_control                       text;
v_datetime_string               text;
v_exists                        text;
v_epoch                         boolean;
v_grantees                      text[];
v_hasoids                       boolean;
v_inherit_fk                    boolean;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_old_search_path               text;
v_parent_grant                  record;
v_parent_owner                  text;
v_parent_schema                 text;
v_parent_tablename              text;
v_partition_created             boolean := false;
v_partition_name                text;
v_partition_suffix              text;
v_parent_tablespace             text;
v_partition_interval            interval;
v_partition_timestamp_end       timestamp;
v_partition_timestamp_start     timestamp;
v_quarter                       text;
v_revoke                        text;
v_row                           record;
v_sql                           text;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_sub_timestamp_max             timestamp;
v_sub_timestamp_min             timestamp;
v_trunc_value                   text;
v_time                          timestamp;
v_type                          text;
v_unlogged                      char;
v_year                          text;

BEGIN

SELECT partition_type
    , control
    , partition_interval
    , epoch
    , inherit_fk
    , jobmon
    , datetime_string
INTO v_type
    , v_control
    , v_partition_interval
    , v_epoch
    , v_inherit_fk
    , v_jobmon
    , v_datetime_string
FROM @extschema@.part_config
WHERE parent_table = p_parent_table
AND partition_type = 'time' OR partition_type = 'time-custom';

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_catalog.sys_namespace n, sys_catalog.sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

-- Determine if this table is a child of a subpartition parent. If so, get limits of what child tables can be created based on parent suffix
SELECT sub_min::timestamp, sub_max::timestamp INTO v_sub_timestamp_min, v_sub_timestamp_max FROM @extschema@.check_subpartition_limits(p_parent_table, 'time');

SELECT tableowner, schemaname, tablename, tablespace INTO v_parent_owner, v_parent_schema, v_parent_tablename, v_parent_tablespace FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN CREATE TABLE: %s', p_parent_table));
END IF;

FOREACH v_time IN ARRAY p_partition_times LOOP    
    v_partition_timestamp_start := v_time;
    BEGIN
        v_partition_timestamp_end := v_time + v_partition_interval;
    EXCEPTION WHEN datetime_field_overflow THEN
        RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range. 
            Child partition creation after time % skipped', v_time;
        v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
        PERFORM update_step(v_step_overflow_id, 'CRITICAL', 'Child partition creation after time '||v_time||' skipped');
        CONTINUE;
    END;

    -- Do not create the child table if it's outside the bounds of the top parent. 
    IF v_sub_timestamp_min IS NOT NULL THEN
        IF v_time < v_sub_timestamp_min OR v_time > v_sub_timestamp_max THEN
            CONTINUE;
        END IF;
    END IF;

    -- This suffix generation code is in partition_data_time() as well
    v_partition_suffix := to_char(v_time, v_datetime_string);
    v_partition_name := @extschema@.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);
    SELECT tablename INTO v_exists FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_partition_name;
    IF v_exists IS NOT NULL THEN
        CONTINUE;
    END IF;

    -- Ensure analyze is run if a new partition is created. Otherwise if one isn't, will be false and analyze will be skipped
    v_analyze := TRUE;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Creating new partition %s.%s with interval from %s to %s'
                                                , v_parent_schema
                                                , v_partition_name
                                                , v_partition_timestamp_start
                                                , v_partition_timestamp_end-'1sec'::interval));
    END IF;

    SELECT relpersistence INTO v_unlogged 
    FROM sys_catalog.sys_class c
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_parent_tablename
    AND n.nspname = v_parent_schema;
    v_sql := 'CREATE';
    IF v_unlogged = 'u' THEN
        v_sql := v_sql || ' UNLOGGED';
    END IF;
    v_sql := v_sql || format(' TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING STORAGE INCLUDING COMMENTS)'
                                , v_parent_schema
                                , v_partition_name
                                , v_parent_schema
                                , v_parent_tablename);
    SELECT relhasoids INTO v_hasoids 
    FROM sys_catalog.sys_class c
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_parent_tablename
    AND n.nspname = v_parent_schema;
    IF v_hasoids IS TRUE THEN
        v_sql := v_sql || ' WITH (OIDS)';
    END IF;
    EXECUTE v_sql;
    IF v_parent_tablespace IS NOT NULL THEN
        EXECUTE format('ALTER TABLE %I.%I SET TABLESPACE %I', v_parent_schema, v_partition_name, v_parent_tablespace);
    END IF;
    IF v_epoch = false THEN
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I >= %L AND %I < %L)'
                        , v_parent_schema
                        , v_partition_name
                        , v_partition_name||'_partition_check'
                        , v_control
                        , v_partition_timestamp_start
                        , v_control
                        , v_partition_timestamp_end);
    ELSE
        EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (to_timestamp(%I) >= %L AND to_timestamp(%I) < %L)'
                        , v_parent_schema
                        , v_partition_name
                        , v_partition_name||'_partition_check'
                        , v_control
                        , v_partition_timestamp_start
                        , v_control
                        , v_partition_timestamp_end);
    END IF;

    EXECUTE format('ALTER TABLE %I.%I INHERIT %I.%I'
                    , v_parent_schema
                    , v_partition_name
                    , v_parent_schema
                    , v_parent_tablename);

    -- If custom time, set extra config options.
    IF v_type = 'time-custom' THEN
        INSERT INTO @extschema@.custom_time_partitions (parent_table, child_table, partition_range)
        VALUES ( p_parent_table, v_parent_schema||'.'||v_partition_name, tstzrange(v_partition_timestamp_start, v_partition_timestamp_end, '[)') );
    END IF;

    FOR v_parent_grant IN 
        SELECT array_agg(DISTINCT privilege_type::text ORDER BY privilege_type::text) AS types, grantee
        FROM information_schema.table_privileges 
        WHERE table_schema ||'.'|| table_name = p_parent_table
        GROUP BY grantee 
    LOOP
        EXECUTE format('GRANT %s ON %I.%I TO %I'
                        , array_to_string(v_parent_grant.types, ',')
                        , v_parent_schema
                        , v_partition_name
                        , v_parent_grant.grantee);
        SELECT string_agg(r, ',') INTO v_revoke FROM (SELECT unnest(v_all) AS r EXCEPT SELECT unnest(v_parent_grant.types)) x;
        IF v_revoke IS NOT NULL THEN
            EXECUTE format('REVOKE %s ON %I.%I FROM %I CASCADE'
                            , v_revoke
                            , v_parent_schema
                            , v_partition_name
                            , v_parent_grant.grantee);
        END IF;
        v_grantees := array_append(v_grantees, v_parent_grant.grantee::text);
    END LOOP;
    -- Revoke all privileges from roles that have none on the parent
    IF v_grantees IS NOT NULL THEN
        FOR v_row IN 
            SELECT role FROM (
                SELECT DISTINCT grantee::text AS role FROM information_schema.table_privileges WHERE table_schema = v_parent_schema AND table_name = v_partition_name
                EXCEPT
                SELECT unnest(v_grantees)) x
        LOOP
            IF v_row.role IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON %I.%I FROM %I'
                            , v_parent_schema
                            , v_partition_name
                            , v_row.role);
            END IF;
        END LOOP;

    END IF;

    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', v_parent_schema, v_partition_name, v_parent_owner);

    IF v_inherit_fk THEN
        PERFORM @extschema@.apply_foreign_keys(p_parent_table, v_parent_schema||'.'||v_partition_name, v_job_id);
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    -- Will only loop once and only if sub_partitioning is actually configured
    -- This seemed easier than assigning a bunch of variables then doing an IF condition
    FOR v_row IN 
        SELECT sub_parent
            , sub_control
            , sub_partition_type
            , sub_partition_interval
            , sub_constraint_cols
            , sub_premake
            , sub_inherit_fk
            , sub_retention
            , sub_retention_schema
            , sub_retention_keep_table
            , sub_retention_keep_index
            , sub_use_run_maintenance
            , sub_epoch
            , sub_optimize_trigger
            , sub_optimize_constraint
            , sub_jobmon
        FROM @extschema@.part_config_sub
        WHERE sub_parent = p_parent_table
    LOOP
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, format('Subpartitioning %s.%s', v_parent_schema, v_partition_name));
        END IF;
        v_sql := format('SELECT @extschema@.create_parent(
                 p_parent_table := %L
                , p_control := %L
                , p_type := %L
                , p_interval := %L
                , p_constraint_cols := %L
                , p_premake := %L
                , p_use_run_maintenance := %L
                , p_inherit_fk := %L
                , p_epoch := %L
                , p_jobmon := %L )'
            , v_parent_schema||'.'||v_partition_name
            , v_row.sub_control
            , v_row.sub_partition_type
            , v_row.sub_partition_interval
            , v_row.sub_constraint_cols
            , v_row.sub_premake
            , v_row.sub_use_run_maintenance
            , v_row.sub_inherit_fk
            , v_row.sub_epoch
            , v_row.sub_jobmon);
        EXECUTE v_sql;

        UPDATE @extschema@.part_config SET 
            retention_schema = v_row.sub_retention_schema
            , retention_keep_table = v_row.sub_retention_keep_table
            , retention_keep_index = v_row.sub_retention_keep_index
            , optimize_trigger = v_row.sub_optimize_trigger
            , optimize_constraint = v_row.sub_optimize_constraint
        WHERE parent_table = v_parent_schema||'.'||v_partition_name;

    END LOOP; -- end sub partitioning LOOP

    v_partition_created := true;

END LOOP;

-- v_analyze is a local check if a new table is made.
-- p_analyze is a parameter to say whether to run the analyze at all. Used by create_parent() to avoid long exclusive lock or run_maintenence() to avoid long creation runs.
IF v_analyze AND p_analyze THEN
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Analyzing partition set: %s', p_parent_table));
    END IF;

    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF v_partition_created = false THEN
        v_step_id := add_step(v_job_id, format('No partitions created for partition set: %s. Attempted intervals: %s', p_parent_table, p_partition_times));
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    IF v_step_overflow_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

RETURN v_partition_created;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE TABLE: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Function to create id partitions
 */
CREATE OR REPLACE FUNCTION create_partition_id(p_parent_table text, p_partition_ids bigint[], p_analyze boolean DEFAULT true) RETURNS boolean
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context              text;
ex_detail               text;
ex_hint                 text;
ex_message              text;
v_all                   text[] := ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'];
v_analyze               boolean := FALSE;
v_control               text;
v_exists                text;
v_grantees              text[];
v_hasoids               boolean;
v_id                    bigint;
v_inherit_fk            boolean;
v_job_id                bigint;
v_jobmon                boolean;
v_jobmon_schema         text;
v_old_search_path       text;
v_parent_grant          record;
v_parent_owner          text;
v_parent_schema         text;
v_parent_tablename      text;
v_parent_tablespace     text;
v_partition_interval    bigint;
v_partition_created     boolean := false;
v_partition_name        text;
v_revoke                text;
v_row                   record;
v_sql                   text;
v_step_id               bigint;
v_sub_id_max            bigint;
v_sub_id_min            bigint;
v_unlogged              char;

BEGIN

SELECT control
    , partition_interval
    , inherit_fk
    , jobmon
INTO v_control
    , v_partition_interval
    , v_inherit_fk
    , v_jobmon
FROM @extschema@.part_config
WHERE parent_table = p_parent_table
AND partition_type = 'id';

IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_namespace n, sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

-- Determine if this table is a child of a subpartition parent. If so, get limits of what child tables can be created based on parent suffix
SELECT sub_min::bigint, sub_max::bigint INTO v_sub_id_min, v_sub_id_max FROM @extschema@.check_subpartition_limits(p_parent_table, 'id');

SELECT tableowner, schemaname, tablename, tablespace INTO v_parent_owner, v_parent_schema, v_parent_tablename, v_parent_tablespace FROM sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN CREATE TABLE: %s', p_parent_table));
END IF;

FOREACH v_id IN ARRAY p_partition_ids LOOP
-- Do not create the child table if it's outside the bounds of the top parent. 
    IF v_sub_id_min IS NOT NULL THEN
        IF v_id < v_sub_id_min OR v_id > v_sub_id_max THEN
            CONTINUE;
        END IF;
    END IF;

    v_partition_name := @extschema@.check_name_length(v_parent_tablename, v_id::text, TRUE);
    -- If child table already exists, skip creation
    SELECT tablename INTO v_exists FROM sys_catalog.sys_tables WHERE schemaname = v_parent_schema AND tablename = v_partition_name;
    IF v_exists IS NOT NULL THEN
        CONTINUE;
    END IF;

    -- Ensure analyze is run if a new partition is created. Otherwise if one isn't, will be false and analyze will be skipped
    v_analyze := TRUE;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Creating new partition '||v_partition_name||' with interval from '||v_id||' to '||(v_id + v_partition_interval)-1);
    END IF;

    SELECT relpersistence INTO v_unlogged 
    FROM sys_catalog.sys_class c
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_parent_tablename
    AND n.nspname = v_parent_schema;
    v_sql := 'CREATE';
    IF v_unlogged = 'u' THEN
        v_sql := v_sql || ' UNLOGGED';
    END IF;
    v_sql := v_sql || format(' TABLE %I.%I (LIKE %I.%I INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES INCLUDING STORAGE INCLUDING COMMENTS)'
            , v_parent_schema
            , v_partition_name
            , v_parent_schema
            , v_parent_tablename);
    SELECT relhasoids INTO v_hasoids 
    FROM sys_catalog.sys_class c
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_parent_tablename
    AND n.nspname = v_parent_schema;
    IF v_hasoids IS TRUE THEN
        v_sql := v_sql || ' WITH (OIDS)';
    END IF;
    EXECUTE v_sql;
    IF v_parent_tablespace IS NOT NULL THEN
        EXECUTE format('ALTER TABLE %I.%I SET TABLESPACE %I', v_parent_schema, v_partition_name, v_parent_tablespace);
    END IF;
    EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I >= %s AND %I < %s )'
        , v_parent_schema
        , v_partition_name
        , v_partition_name||'_partition_check'
        , v_control
        , v_id
        , v_control
        , v_id + v_partition_interval);
    EXECUTE format('ALTER TABLE %I.%I INHERIT %I.%I', v_parent_schema, v_partition_name, v_parent_schema, v_parent_tablename);

    FOR v_parent_grant IN 
        SELECT array_agg(DISTINCT privilege_type::text ORDER BY privilege_type::text) AS types, grantee
        FROM information_schema.table_privileges 
        WHERE table_schema ||'.'|| table_name = p_parent_table
        GROUP BY grantee 
    LOOP
        EXECUTE format('GRANT %s ON %I.%I TO %I'
            , array_to_string(v_parent_grant.types, ',')
            , v_parent_schema
            , v_partition_name
            , v_parent_grant.grantee);
        SELECT string_agg(r, ',') INTO v_revoke FROM (SELECT unnest(v_all) AS r EXCEPT SELECT unnest(v_parent_grant.types)) x;
        IF v_revoke IS NOT NULL THEN
            EXECUTE format('REVOKE %s ON %I.%I FROM %I CASCADE'
                , v_revoke
                , v_parent_schema
                , v_partition_name
                , v_parent_grant.grantee);
        END IF;
        v_grantees := array_append(v_grantees, v_parent_grant.grantee::text);
    END LOOP;
    -- Revoke all privileges from roles that have none on the parent
    IF v_grantees IS NOT NULL THEN
        FOR v_row IN 
            SELECT role FROM (
                SELECT DISTINCT grantee::text AS role FROM information_schema.table_privileges WHERE table_schema = v_parent_schema AND table_name = v_partition_name
                EXCEPT
                SELECT unnest(v_grantees)) x
        LOOP
            IF v_row.role IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON %I.%I FROM %I'
                            , v_parent_schema
                            , v_partition_name
                            , v_row.role);
            END IF;
        END LOOP;
    END IF;

    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', v_parent_schema, v_partition_name, v_parent_owner);

    IF v_inherit_fk THEN
        PERFORM @extschema@.apply_foreign_keys(p_parent_table, v_parent_schema||'.'||v_partition_name, v_job_id);
    END IF;

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    -- Will only loop once and only if sub_partitioning is actually configured
    -- This seemed easier than assigning a bunch of variables then doing an IF condition
    FOR v_row IN 
        SELECT sub_parent
            , sub_control
            , sub_partition_type
            , sub_partition_interval
            , sub_constraint_cols
            , sub_premake
            , sub_inherit_fk
            , sub_retention
            , sub_retention_schema
            , sub_retention_keep_table
            , sub_retention_keep_index
            , sub_use_run_maintenance
            , sub_epoch
            , sub_optimize_trigger
            , sub_optimize_constraint
            , sub_jobmon
        FROM @extschema@.part_config_sub
        WHERE sub_parent = p_parent_table
    LOOP
        IF v_jobmon_schema IS NOT NULL THEN
            v_step_id := add_step(v_job_id, 'Subpartitioning '||v_partition_name);
        END IF;
        v_sql := format('SELECT @extschema@.create_parent(
                 p_parent_table := %L
                , p_control := %L
                , p_type := %L
                , p_interval := %L
                , p_constraint_cols := %L
                , p_premake := %L
                , p_use_run_maintenance := %L
                , p_inherit_fk := %L
                , p_epoch := %L
                , p_jobmon := %L )'
            , v_parent_schema||'.'||v_partition_name
            , v_row.sub_control
            , v_row.sub_partition_type
            , v_row.sub_partition_interval
            , v_row.sub_constraint_cols
            , v_row.sub_premake
            , v_row.sub_use_run_maintenance
            , v_row.sub_inherit_fk
            , v_row.sub_epoch
            , v_row.sub_jobmon);
        EXECUTE v_sql;

        UPDATE @extschema@.part_config SET 
            retention_schema = v_row.sub_retention_schema
            , retention_keep_table = v_row.sub_retention_keep_table
            , retention_keep_index = v_row.sub_retention_keep_index
            , optimize_trigger = v_row.sub_optimize_trigger
            , optimize_constraint = v_row.sub_optimize_constraint
        WHERE parent_table = v_parent_schema||'.'||v_partition_name;

        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', 'Done');
        END IF;

    END LOOP; -- end sub partitioning LOOP

    v_partition_created := true;

END LOOP;

-- v_analyze is a local check if a new table is made.
-- p_analyze is a parameter to say whether to run the analyze at all. Used by create_parent() to avoid long exclusive lock or run_maintenence() to avoid long creation runs.
IF v_analyze AND p_analyze THEN
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Analyzing partition set: %s', p_parent_table));
    END IF;

    EXECUTE format('ANALYZE %I.%I', v_parent_schema, v_parent_tablename);

    IF v_jobmon_schema IS NOT NULL THEN
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    IF v_partition_created = false THEN
        v_step_id := add_step(v_job_id, format('No partitions created for partition set: %s', p_parent_table));
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;

    PERFORM close_job(v_job_id);
END IF;
 
IF v_jobmon_schema IS NOT NULL THEN
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

RETURN v_partition_created;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN CREATE TABLE: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Function to manage pre-creation of the next partitions in a set.
 * Also manages dropping old partitions if the retention option is set.
 * If p_parent_table is passed, will only run run_maintenance() on that one table (no matter what the configuration table may have set for it)
 * Otherwise, will run on all tables in the config table with p_run_maintenance() set to true.
 * For large partition sets, running analyze can cause maintenance to take longer than expected. Can set p_analyze to false to avoid a forced analyze run.
 * Be aware that constraint exclusion may not work properly until an analyze on the partition set is run. 
 */
CREATE OR REPLACE INTERNAL FUNCTION run_maintenance(p_parent_table text DEFAULT NULL, p_analyze boolean DEFAULT true, p_jobmon boolean DEFAULT true, p_debug boolean DEFAULT false) RETURNS void 
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context                      text;
ex_detail                       text;
ex_hint                         text;
ex_message                      text;
v_adv_lock                      boolean;
v_check_subpart                 int;
v_create_count                  int := 0;
v_current_partition             text;
v_current_partition_id          bigint;
v_current_partition_timestamp   timestamp;
v_datetime_string               text;
v_drop_count                    int := 0;
v_id_position                   int;
v_job_id                        bigint;
v_jobmon                        boolean;
v_jobmon_schema                 text;
v_last_partition                text;
v_last_partition_created        boolean;
v_last_partition_id             bigint;
v_last_partition_timestamp      timestamp;
v_max_id_parent                 bigint;
v_max_time_parent               timestamp;
v_next_partition_id             bigint;
v_next_partition_timestamp      timestamp;
v_old_search_path               text;
v_parent_schema                 text;
v_parent_tablename              text;
v_premade_count                 int;
v_premake_id_max                bigint;
v_premake_id_min                bigint;
v_premake_timestamp_min         timestamp;
v_premake_timestamp_max         timestamp;
v_quarter                       text;
v_row                           record;
v_row_max_id                    record;
v_row_max_time                  record;
v_row_sub                       record;
v_skip_maint                    boolean;
v_step_id                       bigint;
v_step_overflow_id              bigint;
v_step_serial_id                bigint;
v_sub_id_max                    bigint;
v_sub_id_max_suffix             bigint;
v_sub_id_min                    bigint;
v_sub_parent                    text;
v_sub_timestamp_max             timestamp;
v_sub_timestamp_max_suffix      timestamp;
v_sub_timestamp_min             timestamp;
v_tablename                     text;
v_tables_list_sql               text;
v_time_position                 int;
v_year                          text;

BEGIN

v_adv_lock := sys_try_advisory_xact_lock(hashtext('sys_partman run_maintenance'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'Partman maintenance already running.';
    RETURN;
END IF;

IF p_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_catalog.sys_namespace n, sys_catalog.sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job('PARTMAN RUN MAINTENANCE');
    v_step_id := add_step(v_job_id, 'Running maintenance loop');
END IF;

-- Check for consistent data in part_config_sub table. Was unable to get this working properly as either a constraint or trigger. 
-- Would either delay raising an error until the next write (which I cannot predict) or disallow future edits to update a sub-partition set's configuration.
-- This way at least provides a consistent way to check that I know will run. If anyone can get a working constraint/trigger, please help!
-- Don't have to worry about this in the serial trigger maintenance since subpartitioning requires run_maintenance().
FOR v_row IN 
    SELECT sub_parent FROM @extschema@.part_config_sub
LOOP
    SELECT count(*) INTO v_check_subpart FROM @extschema@.check_subpart_sameconfig(v_row.sub_parent);
    IF v_check_subpart > 1 THEN
        RAISE EXCEPTION 'Inconsistent data in part_config_sub table. Sub-partition tables that are themselves sub-partitions cannot have differing configuration values among their siblings. 
        Run this query: "SELECT * FROM @extschema@.check_subpart_sameconfig(''%'');" This should only return a single row or nothing. 
        If multiple rows are returned, results are all children of the given parent. Update the differing values to be consistent for your desired values.', v_row.sub_parent;
    END IF;
END LOOP;

v_row := NULL; -- Ensure it's reset


v_tables_list_sql := 'SELECT parent_table
                , partition_type
                , partition_interval
                , control
                , premake
                , datetime_string
                , undo_in_progress
                , sub_partition_set_full
                , epoch
            FROM @extschema@.part_config
            WHERE sub_partition_set_full = false';

IF p_parent_table IS NULL THEN
    v_tables_list_sql := v_tables_list_sql || ' AND use_run_maintenance = true';
ELSE
    v_tables_list_sql := v_tables_list_sql || format(' AND parent_table = %L', p_parent_table);
END IF;

FOR v_row IN EXECUTE v_tables_list_sql
LOOP

    CONTINUE WHEN v_row.undo_in_progress;
    v_skip_maint := true; -- reset every loop

    SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = v_row.parent_table;

    SELECT partition_tablename INTO v_last_partition FROM @extschema@.show_partitions(v_row.parent_table, 'DESC') LIMIT 1;
    IF p_debug THEN
        RAISE NOTICE 'run_maint: parent_table: %, v_last_partition: %', v_row.parent_table, v_last_partition;
    END IF;

    IF v_row.partition_type = 'time' OR v_row.partition_type = 'time-custom' THEN

        v_time_position := (length(v_last_partition) - position('p_' in reverse(v_last_partition))) + 2;
        IF v_row.partition_interval::interval <> '3 months' OR (v_row.partition_interval::interval = '3 months' AND v_row.partition_type = 'time-custom') THEN
           v_last_partition_timestamp := to_timestamp(substring(v_last_partition from v_time_position), v_row.datetime_string);
        ELSE
            -- to_timestamp doesn't recognize 'Q' date string formater. Handle it
            v_year := split_part(substring(v_last_partition FROM v_time_position), 'q', 1);
            v_quarter := split_part(substring(v_last_partition FROM v_time_position), 'q', 2);
            CASE
                WHEN v_quarter = '1' THEN
                    v_last_partition_timestamp := to_timestamp(v_year || '-01-01', 'YYYY-MM-DD');
                WHEN v_quarter = '2' THEN
                    v_last_partition_timestamp := to_timestamp(v_year || '-04-01', 'YYYY-MM-DD');
                WHEN v_quarter = '3' THEN
                    v_last_partition_timestamp := to_timestamp(v_year || '-07-01', 'YYYY-MM-DD');
                WHEN v_quarter = '4' THEN
                    v_last_partition_timestamp := to_timestamp(v_year || '-10-01', 'YYYY-MM-DD');
            END CASE;
        END IF;

        -- Loop through child tables starting from highest to get current max value in partition set
        -- Avoids doing a scan on entire partition set and/or getting any values accidentally in parent.
        FOR v_row_max_time IN
            SELECT partition_schemaname, partition_tablename FROM @extschema@.show_partitions(v_row.parent_table, 'DESC')
        LOOP
            IF v_row.epoch = false THEN
                EXECUTE format('SELECT max(%I)::text FROM %I.%I'
                                    , v_row.control
                                    , v_row_max_time.partition_schemaname
                                    , v_row_max_time.partition_tablename
                                ) INTO v_current_partition_timestamp;
            ELSE
                EXECUTE format('SELECT to_timestamp(max(%I))::text FROM %I.%I'
                                    , v_row.control
                                    , v_row_max_time.partition_schemaname
                                    , v_row_max_time.partition_tablename
                                ) INTO v_current_partition_timestamp;
            END IF;
            IF v_current_partition_timestamp IS NOT NULL THEN
                SELECT suffix_timestamp INTO v_current_partition_timestamp FROM show_partition_name(v_row.parent_table, v_current_partition_timestamp::text);
                EXIT;
            END IF;
        END LOOP;
        -- Check for values in the parent table. If they are there and greater than all child values, use that instead
        -- This allows maintenance to continue working properly if there is a large gap in data insertion. Data will remain in parent, but new tables will be created
        IF v_row.epoch = false THEN
            EXECUTE format('SELECT max(%I) FROM ONLY %I.%I', v_row.control, v_parent_schema, v_parent_tablename) INTO v_max_time_parent;
        ELSE
            EXECUTE format('SELECT to_timestamp(max(%I)) FROM ONLY %I.%I', v_row.control, v_parent_schema, v_parent_tablename) INTO v_max_time_parent;
        END IF;
        IF p_debug THEN
            RAISE NOTICE 'run_maint: v_current_partition_timestamp: %, v_max_time_parent: %', v_current_partition_timestamp, v_max_time_parent;
        END IF;
        IF v_max_time_parent > v_current_partition_timestamp THEN
            SELECT suffix_timestamp INTO v_current_partition_timestamp FROM show_partition_name(v_row.parent_table, v_max_time_parent::text);
        END IF;
        IF v_current_partition_timestamp IS NULL THEN
            -- Partition set is completely empty. Nothing to do
            CONTINUE;
        END IF;

        -- If this is a subpartition, determine if the last child table has been made. If so, mark it as full so future maintenance runs can skip it
        SELECT sub_min::timestamp, sub_max::timestamp INTO v_sub_timestamp_min, v_sub_timestamp_max FROM @extschema@.check_subpartition_limits(v_row.parent_table, 'time');
        IF v_sub_timestamp_max IS NOT NULL THEN
            SELECT suffix_timestamp INTO v_sub_timestamp_max_suffix FROM @extschema@.show_partition_name(v_row.parent_table, v_sub_timestamp_max::text);
            IF v_sub_timestamp_max_suffix = v_last_partition_timestamp THEN
                -- Final partition for this set is created. Set full and skip it
                UPDATE @extschema@.part_config SET sub_partition_set_full = true WHERE parent_table = v_row.parent_table;
                CONTINUE;
            END IF;
        END IF;

        -- Check and see how many premade partitions there are.
        v_premade_count = round(EXTRACT('epoch' FROM age(v_last_partition_timestamp, v_current_partition_timestamp)) / EXTRACT('epoch' FROM v_row.partition_interval::interval));
        v_next_partition_timestamp := v_last_partition_timestamp;
        IF p_debug THEN
            RAISE NOTICE 'run_maint before loop: current_partition_timestamp: %, v_premade_count: %, v_sub_timestamp_min: %, v_sub_timestamp_max: %'
                , v_current_partition_timestamp 
                , v_premade_count
                , v_sub_timestamp_min
                , v_sub_timestamp_max;
        END IF;
        -- Loop premaking until config setting is met. Allows it to catch up if it fell behind or if premake changed
        WHILE (v_premade_count < v_row.premake) LOOP
            IF p_debug THEN
                RAISE NOTICE 'run_maint: parent_table: %, v_premade_count: %, v_next_partition_timestamp: %', v_row.parent_table, v_premade_count, v_next_partition_timestamp;
            END IF;
            IF v_next_partition_timestamp < v_sub_timestamp_min OR v_next_partition_timestamp > v_sub_timestamp_max THEN
                -- With subpartitioning, no need to run if the timestamp is not in the parent table's range
                EXIT;
            END IF;
            BEGIN
                v_next_partition_timestamp := v_next_partition_timestamp + v_row.partition_interval::interval;
            EXCEPTION WHEN datetime_field_overflow THEN
                v_premade_count := v_row.premake; -- do this so it can exit the premake check loop and continue in the outer for loop 
                IF v_jobmon_schema IS NOT NULL THEN
                    v_step_overflow_id := add_step(v_job_id, 'Attempted partition time interval is outside PostgreSQL''s supported time range.');
                    PERFORM update_step(v_step_overflow_id, 'CRITICAL', 'Child partition creation skippd for parent table '||v_partition_time);
                END IF;
                RAISE WARNING 'Attempted partition time interval is outside PostgreSQL''s supported time range. Child partition creation skipped for parent table %', v_row.parent_table;
                CONTINUE;
            END;
            v_last_partition_created := @extschema@.create_partition_time(v_row.parent_table, ARRAY[v_next_partition_timestamp], p_analyze); 
            IF v_last_partition_created THEN
                v_create_count := v_create_count + 1;
                PERFORM @extschema@.create_function_time(v_row.parent_table, v_job_id);
            END IF;

            v_premade_count = round(EXTRACT('epoch' FROM age(v_next_partition_timestamp, v_current_partition_timestamp)) / EXTRACT('epoch' FROM v_row.partition_interval::interval));
        END LOOP;
    ELSIF v_row.partition_type = 'id' THEN
        -- Loop through child tables starting from highest to get current max value in partition set
        -- Avoids doing a scan on entire partition set and/or getting any values accidentally in parent.
        FOR v_row_max_id IN
            SELECT partition_schemaname, partition_tablename FROM @extschema@.show_partitions(v_row.parent_table, 'DESC')
        LOOP
            EXECUTE format('SELECT max(%I)::text FROM %I.%I'
                            , v_row.control
                            , v_row_max_id.partition_schemaname
                            , v_row_max_id.partition_tablename) INTO v_current_partition_id;
            IF v_current_partition_id IS NOT NULL THEN
                SELECT suffix_id INTO v_current_partition_id FROM show_partition_name(v_row.parent_table, v_current_partition_id::text);
                EXIT;
            END IF;
        END LOOP;
        -- Check for values in the parent table. If they are there and greater than all child values, use that instead
        -- This allows maintenance to continue working properly if there is a large gap in data insertion. Data will remain in parent, but new tables will be created
        EXECUTE format('SELECT max(%I) FROM ONLY %I.%I', v_row.control, v_parent_schema, v_parent_tablename) INTO v_max_id_parent;
        IF v_max_id_parent > v_current_partition_id THEN
            SELECT suffix_id INTO v_current_partition_id FROM show_partition_name(v_row.parent_table, v_max_id_parent::text);
        END IF;
        IF v_current_partition_id IS NULL THEN
            -- Partition set is completely empty. Nothing to do
            CONTINUE;
        END IF;

        v_id_position := (length(v_last_partition) - position('p_' in reverse(v_last_partition))) + 2;
        v_last_partition_id = substring(v_last_partition from v_id_position)::bigint;
        -- Determine if this table is a child of a subpartition parent. If so, get limits to see if run_maintenance even needs to run for it.
        SELECT sub_min::bigint, sub_max::bigint INTO v_sub_id_min, v_sub_id_max FROM @extschema@.check_subpartition_limits(v_row.parent_table, 'id');
        IF v_sub_id_max IS NOT NULL THEN
            SELECT suffix_id INTO v_sub_id_max_suffix FROM @extschema@.show_partition_name(v_row.parent_table, v_sub_id_max::text);
            IF v_sub_id_max_suffix = v_last_partition_id THEN
                -- Final partition for this set is created. Set full and skip it
                UPDATE @extschema@.part_config SET sub_partition_set_full = true WHERE parent_table = v_row.parent_table;
                CONTINUE;
            END IF;
        END IF;

        v_next_partition_id := v_last_partition_id;
        v_premade_count := ((v_last_partition_id - v_current_partition_id) / v_row.partition_interval::bigint);
        -- Loop premaking until config setting is met. Allows it to catch up if it fell behind or if premake changed.
        WHILE (v_premade_count < v_row.premake) LOOP 
            IF p_debug THEN
                RAISE NOTICE 'run_maint: parent_table: %, v_premade_count: %, v_next_partition_id: %', v_row.parent_table, v_premade_count, v_next_partition_id;
            END IF;
            IF v_next_partition_id < v_sub_id_min OR v_next_partition_id > v_sub_id_max THEN
                -- With subpartitioning, no need to run if the id is not in the parent table's range
                EXIT;
            END IF;
            v_next_partition_id := v_next_partition_id + v_row.partition_interval::bigint;
            v_last_partition_created := @extschema@.create_partition_id(v_row.parent_table, ARRAY[v_next_partition_id], p_analyze);
            IF v_last_partition_created THEN
                v_create_count := v_create_count + 1;
                PERFORM @extschema@.create_function_id(v_row.parent_table, v_job_id);
            END IF;
            v_premade_count := ((v_next_partition_id - v_current_partition_id) / v_row.partition_interval::bigint);
        END LOOP;

    END IF; -- end main IF check for time or id

    -- Manage additonal constraints if set
    PERFORM @extschema@.apply_constraints(p_parent_table := v_row.parent_table, p_job_id := v_job_id, p_debug := p_debug);

END LOOP; -- end of creation loop

-- Manage dropping old partitions if retention option is set
FOR v_row IN 
    SELECT parent_table FROM @extschema@.part_config WHERE retention IS NOT NULL AND undo_in_progress = false AND 
        (partition_type = 'time' OR partition_type = 'time-custom')
LOOP
    IF p_parent_table IS NULL THEN
        v_drop_count := v_drop_count + @extschema@.drop_partition_time(v_row.parent_table);   
    ELSE -- Only run retention on table given in parameter
        IF p_parent_table <> v_row.parent_table THEN
            CONTINUE;
        ELSE
            v_drop_count := v_drop_count + @extschema@.drop_partition_time(v_row.parent_table);   
        END IF;
    END IF;
    IF v_drop_count > 0 THEN
        PERFORM @extschema@.create_function_time(v_row.parent_table, v_job_id);
    END IF;
END LOOP; 
FOR v_row IN 
    SELECT parent_table FROM @extschema@.part_config WHERE retention IS NOT NULL AND undo_in_progress = false AND partition_type = 'id'
LOOP
    IF p_parent_table IS NULL THEN
        v_drop_count := v_drop_count + @extschema@.drop_partition_id(v_row.parent_table);
    ELSE -- Only run retention on table given in parameter
        IF p_parent_table <> v_row.parent_table THEN
            CONTINUE;
        ELSE
            v_drop_count := v_drop_count + @extschema@.drop_partition_id(v_row.parent_table);
        END IF;
    END IF;
    IF v_drop_count > 0 THEN
        PERFORM @extschema@.create_function_id(v_row.parent_table, v_job_id);
    END IF;
END LOOP; 

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', format('Partition maintenance finished. %s partitons made. %s partitions dropped.', v_create_count, v_drop_count));
    IF v_step_overflow_id IS NOT NULL OR v_step_serial_id IS NOT NULL THEN
        PERFORM fail_job(v_job_id);
    ELSE
        PERFORM close_job(v_job_id);
    END IF;
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN RUN MAINTENANCE'')', v_jobmon_schema) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Populate the child table(s) of a time-based partition set with old data from the original parent
 */
CREATE OR REPLACE FUNCTION partition_data_time(p_parent_table text, p_batch_count int DEFAULT 1, p_batch_interval interval DEFAULT NULL, p_lock_wait numeric DEFAULT 0, p_order text DEFAULT 'ASC') RETURNS bigint
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

v_control                   text;
v_datetime_string           text;
v_current_partition_name    text;
v_epoch                     boolean;
v_last_partition            text;
v_lock_iter                 int := 1;
v_lock_obtained             boolean := FALSE;
v_max_partition_timestamp   timestamp;
v_min_partition_timestamp   timestamp;
v_parent_schema             text;
v_parent_tablename          text;
v_partition_interval        interval;
v_partition_suffix          text;
v_partition_timestamp       timestamp[];
v_quarter                   text;
v_rowcount                  bigint;
v_sql                       text;
v_start_control             timestamp;
v_time_position             int;
v_total_rows                bigint := 0;
v_type                      text;
v_year                      text;

BEGIN

SELECT partition_type
    , partition_interval::interval
    , control
    , datetime_string
    , epoch
INTO v_type
    , v_partition_interval
    , v_control
    , v_datetime_string
    , v_epoch
FROM @extschema@.part_config 
WHERE parent_table = p_parent_table
AND (partition_type = 'time' OR partition_type = 'time-custom');
IF NOT FOUND THEN
    RAISE EXCEPTION 'ERROR: no config found for %', p_parent_table;
END IF;

IF p_batch_interval IS NULL OR p_batch_interval > v_partition_interval THEN
    p_batch_interval := v_partition_interval;
END IF;

SELECT partition_tablename INTO v_last_partition FROM @extschema@.show_partitions(p_parent_table, 'DESC') LIMIT 1;
SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;

FOR i IN 1..p_batch_count LOOP

    IF v_epoch = false THEN
        IF p_order = 'ASC' THEN
            EXECUTE format('SELECT min(%I) FROM ONLY %I.%I', v_control, v_parent_schema, v_parent_tablename) INTO v_start_control;
        ELSIF p_order = 'DESC' THEN
            EXECUTE format('SELECT max(%I) FROM ONLY %I.%I', v_control, v_parent_schema, v_parent_tablename) INTO v_start_control;
        ELSE
            RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
        END IF;
    ELSE
        IF p_order = 'ASC' THEN
            EXECUTE format('SELECT to_timestamp(min(%I)) FROM ONLY %I.%I', v_control, v_parent_schema, v_parent_tablename) INTO v_start_control;
        ELSIF p_order = 'DESC' THEN
            EXECUTE format('SELECT to_timestamp(max(%I)) FROM ONLY %I.%I', v_control, v_parent_schema, v_parent_tablename) INTO v_start_control;
        ELSE
            RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
        END IF;
    END IF;

    IF v_start_control IS NULL THEN
        EXIT;
    END IF;

    IF v_type = 'time' THEN
        CASE
            WHEN v_partition_interval = '15 mins' THEN
                v_min_partition_timestamp := date_trunc('hour', v_start_control) + 
                    '15min'::interval * floor(date_part('minute', v_start_control) / 15.0);
            WHEN v_partition_interval = '30 mins' THEN
                v_min_partition_timestamp := date_trunc('hour', v_start_control) + 
                    '30min'::interval * floor(date_part('minute', v_start_control) / 30.0);
            WHEN v_partition_interval = '1 hour' THEN
                v_min_partition_timestamp := date_trunc('hour', v_start_control);
            WHEN v_partition_interval = '1 day' THEN
                v_min_partition_timestamp := date_trunc('day', v_start_control);
            WHEN v_partition_interval = '1 week' THEN
                v_min_partition_timestamp := date_trunc('week', v_start_control);
            WHEN v_partition_interval = '1 month' THEN
                v_min_partition_timestamp := date_trunc('month', v_start_control);
            WHEN v_partition_interval = '3 months' THEN
                v_min_partition_timestamp := date_trunc('quarter', v_start_control);
            WHEN v_partition_interval = '1 year' THEN
                v_min_partition_timestamp := date_trunc('year', v_start_control);
        END CASE;
    ELSIF v_type = 'time-custom' THEN
        -- Keep going backwards, checking if the time interval encompases the current v_start_control value
        v_time_position := (length(v_last_partition) - position('p_' in reverse(v_last_partition))) + 2;
        v_min_partition_timestamp := to_timestamp(substring(v_last_partition from v_time_position), v_datetime_string);
        v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
        LOOP
            IF v_start_control >= v_min_partition_timestamp AND v_start_control < v_max_partition_timestamp THEN
                EXIT;
            ELSE
                v_max_partition_timestamp := v_min_partition_timestamp;
                BEGIN
                    v_min_partition_timestamp := v_min_partition_timestamp - v_partition_interval;
                EXCEPTION WHEN datetime_field_overflow THEN
                    RAISE EXCEPTION 'Attempted partition time interval is outside PostgreSQL''s supported time range. 
                        Unable to create partition with interval before timestamp % ', v_min_partition_interval;
                END;
            END IF;
        END LOOP;

    END IF;

    v_partition_timestamp := ARRAY[v_min_partition_timestamp];
    IF p_order = 'ASC' THEN
        IF (v_start_control + p_batch_interval) >= (v_min_partition_timestamp + v_partition_interval) THEN
            v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
        ELSE
            v_max_partition_timestamp := v_start_control + p_batch_interval;
        END IF;
    ELSIF p_order = 'DESC' THEN
        -- Must be greater than max value still in parent table since query below grabs < max
        v_max_partition_timestamp := v_min_partition_timestamp + v_partition_interval;
        -- Make sure minimum doesn't underflow current partition minimum
        IF (v_start_control - p_batch_interval) >= v_min_partition_timestamp THEN
            v_min_partition_timestamp = v_start_control - p_batch_interval;
        END IF;
    ELSE
        RAISE EXCEPTION 'Invalid value for p_order. Must be ASC or DESC';
    END IF;

-- do some locking with timeout, if required
    IF p_lock_wait > 0  THEN
        v_lock_iter := 0;
        WHILE v_lock_iter <= 5 LOOP
            v_lock_iter := v_lock_iter + 1;
            BEGIN
                IF v_epoch = false THEN
                    v_sql := format('SELECT * FROM ONLY %I.%I WHERE %I >= %L AND %I < %L FOR UPDATE NOWAIT'
                                        , v_parent_schema
                                        , v_parent_tablename
                                        , v_control
                                        , v_min_partition_timestamp
                                        , v_control
                                        , v_max_partition_timestamp);
                ELSE
                    v_sql := format('SELECT * FROM ONLY %I.%I WHERE to_timestamp(%I) >= %L AND to_timestamp(%I) < %L FOR UPDATE NOWAIT'
                                        , v_parent_schema
                                        , v_parent_tablename
                                        , v_control
                                        , v_min_partition_timestamp
                                        , v_control
                                        , v_max_partition_timestamp);
                END IF;
                EXECUTE v_sql;
                v_lock_obtained := TRUE;
            EXCEPTION
                WHEN lock_not_available THEN
                    PERFORM sys_sleep( p_lock_wait / 5.0 );
                    CONTINUE;
            END;
            EXIT WHEN v_lock_obtained;
        END LOOP;
        IF NOT v_lock_obtained THEN
           RETURN -1;
        END IF;
    END IF;

    PERFORM @extschema@.create_partition_time(p_parent_table, v_partition_timestamp);
    -- This suffix generation code is in create_partition_time() as well
    v_partition_suffix := to_char(v_min_partition_timestamp, v_datetime_string);
    v_current_partition_name := @extschema@.check_name_length(v_parent_tablename, v_partition_suffix, TRUE);

    IF v_epoch = false THEN
        v_sql := format('WITH partition_data AS (
                            DELETE FROM ONLY %I.%I WHERE %I >= %L AND %I < %L RETURNING *)
                         INSERT INTO %I.%I SELECT * FROM partition_data'
                            , v_parent_schema
                            , v_parent_tablename
                            , v_control
                            , v_min_partition_timestamp
                            , v_control
                            , v_max_partition_timestamp
                            , v_parent_schema
                            , v_current_partition_name);
    ELSE
        v_sql := format('WITH partition_data AS (
                            DELETE FROM ONLY %I.%I WHERE to_timestamp(%I) >= %L AND to_timestamp(%I) < %L RETURNING *)
                         INSERT INTO %I.%I SELECT * FROM partition_data'
                            , v_parent_schema
                            , v_parent_tablename
                            , v_control
                            , v_min_partition_timestamp
                            , v_control
                            , v_max_partition_timestamp
                            , v_parent_schema
                            , v_current_partition_name);
    END IF;
    EXECUTE v_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    v_total_rows := v_total_rows + v_rowcount;
    IF v_rowcount = 0 THEN
        EXIT;
    END IF;

END LOOP; 

PERFORM @extschema@.create_function_time(p_parent_table);

RETURN v_total_rows;

END
$$;


/*
 * Function to undo time-based partitioning created by this extension
 */
CREATE OR REPLACE FUNCTION undo_partition_time(p_parent_table text, p_batch_count int DEFAULT 1, p_batch_interval interval DEFAULT NULL, p_keep_table boolean DEFAULT true, p_lock_wait numeric DEFAULT 0) RETURNS bigint
    LANGUAGE plsql SECURITY DEFINER
    AS $$
DECLARE

ex_context              text;
ex_detail               text;
ex_hint                 text;
ex_message              text;
v_adv_lock              boolean;
v_batch_loop_count      int := 0;
v_child_min             timestamptz;
v_child_loop_total      bigint := 0;
v_child_table           text;
v_control               text;
v_epoch                 boolean;
v_function_name         text;
v_inner_loop_count      int;
v_lock_iter             int := 1;
v_lock_obtained         boolean := FALSE;
v_job_id                bigint;
v_jobmon                boolean;
v_jobmon_schema         text;
v_move_sql              text;
v_old_search_path       text;
v_parent_schema         text;
v_parent_tablename      text;
v_partition_interval    interval;
v_row                   record;
v_rowcount              bigint;
v_step_id               bigint;
v_sub_count             int;
v_total                 bigint := 0;
v_trig_name             text;
v_type                  text;
v_undo_count            int := 0;

BEGIN

v_adv_lock := sys_try_advisory_xact_lock(hashtext('sys_partman undo_partition_time'));
IF v_adv_lock = 'false' THEN
    RAISE NOTICE 'undo_partition_time already running.';
    RETURN 0;
END IF;

SELECT partition_type
    , partition_interval::interval
    , control
    , jobmon
    , epoch
INTO v_type
    , v_partition_interval
    , v_control
    , v_jobmon
    , v_epoch
FROM @extschema@.part_config 
WHERE parent_table = p_parent_table 
AND (partition_type = 'time' OR partition_type = 'time-custom');

IF v_partition_interval IS NULL THEN
    RAISE EXCEPTION 'Configuration for given parent table not found: %', p_parent_table;
END IF;

-- Check if any child tables are themselves partitioned or part of an inheritance tree. Prevent undo at this level if so.
-- Need to either lock child tables at all levels or handle the proper removal of triggers on all child tables first 
--  before multi-level undo can be performed safely.
FOR v_row IN 
    SELECT partition_schemaname, partition_tablename FROM @extschema@.show_partitions(p_parent_table)
LOOP
    SELECT count(*) INTO v_sub_count
    FROM sys_catalog.sys_inherits i
    JOIN sys_catalog.sys_class c ON i.inhparent = c.oid
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = v_row.partition_tablename
    AND n.nspname = v_row.partition_schemaname;
    IF v_sub_count > 0 THEN
        RAISE EXCEPTION 'Child table for this parent has child table(s) itself (%). Run undo partitioning on this table or remove inheritance first to ensure all data is properly moved to parent', v_row.partition_schemaname||'.'||v_row.partition_tablename;
    END IF;
END LOOP;

IF v_jobmon THEN
    SELECT nspname INTO v_jobmon_schema FROM sys_namespace n, sys_extension e WHERE e.extname = 'sys_jobmon' AND e.extnamespace = n.oid;
    IF v_jobmon_schema IS NOT NULL THEN
        SELECT current_setting('search_path') INTO v_old_search_path;
        EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', '@extschema@,'||v_jobmon_schema, 'false');
    END IF;
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    v_job_id := add_job(format('PARTMAN UNDO PARTITIONING: %s', p_parent_table));
    v_step_id := add_step(v_job_id, format('Undoing partitioning for table %s', p_parent_table));
END IF;

IF p_batch_interval IS NULL THEN
    p_batch_interval := v_partition_interval;
END IF;

-- Stops new time partitons from being made as well as stopping child tables from being dropped if they were configured with a retention period.
UPDATE @extschema@.part_config SET undo_in_progress = true WHERE parent_table = p_parent_table;
-- Stop data going into child tables.
SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_tables WHERE schemaname ||'.'|| tablename = p_parent_table;
v_trig_name := @extschema@.check_name_length(p_object_name := v_parent_tablename, p_suffix := '_part_trig'); 
v_function_name := @extschema@.check_name_length(v_parent_tablename, '_part_trig_func', FALSE);

SELECT tgname INTO v_trig_name FROM sys_catalog.sys_trigger t WHERE tgname = v_trig_name;
IF v_trig_name IS NOT NULL THEN
    -- lockwait for trigger drop
    IF p_lock_wait > 0  THEN
        v_lock_iter := 0;
        WHILE v_lock_iter <= 5 LOOP
            v_lock_iter := v_lock_iter + 1;
            BEGIN
                EXECUTE format('LOCK TABLE ONLY %I.%I IN ACCESS EXCLUSIVE MODE NOWAIT', v_parent_schema, v_parent_tablename);
                v_lock_obtained := TRUE;
            EXCEPTION
                WHEN lock_not_available THEN
                    PERFORM sys_sleep( p_lock_wait / 5.0 );
                    CONTINUE;
            END;
            EXIT WHEN v_lock_obtained;
        END LOOP;
        IF NOT v_lock_obtained THEN
            RAISE NOTICE 'Unable to obtain lock on parent table to remove trigger';
            RETURN -1;
        END IF;
    END IF; -- END p_lock_wait IF
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trig_name, v_parent_schema, v_parent_tablename);
END IF; -- END trigger IF
v_lock_obtained := FALSE; -- reset for reuse later

EXECUTE format('DROP FUNCTION IF EXISTS %I.%I()', v_parent_schema, v_function_name);

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM update_step(v_step_id, 'OK', 'Stopped partition creation process. Removed trigger & trigger function');
END IF;

<<outer_child_loop>>
WHILE v_batch_loop_count < p_batch_count LOOP 
    -- Get ordered list of child table in set. Store in variable one at a time per loop until none are left.
    SELECT partition_tablename INTO v_child_table FROM @extschema@.show_partitions(p_parent_table, 'ASC');

    EXIT WHEN v_child_table IS NULL;

    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, format('Removing child partition: %s.%s', v_parent_schema, v_child_table));
    END IF;

    IF v_epoch = false THEN
        EXECUTE format('SELECT min(%I) FROM %I.%I', v_control, v_parent_schema, v_child_table) INTO v_child_min;
    ELSE 
        EXECUTE format('SELECT to_timestamp(min(%I)) FROM %I.%I', v_control, v_parent_schema, v_child_table) INTO v_child_min;
    END IF;
    IF v_child_min IS NULL THEN
        -- No rows left in this child table. Remove from partition set.

        -- lockwait timeout for table drop
        IF p_lock_wait > 0  THEN
            v_lock_iter := 0;
            WHILE v_lock_iter <= 5 LOOP
                v_lock_iter := v_lock_iter + 1;
                BEGIN
                    EXECUTE format('LOCK TABLE ONLY %I.%I IN ACCESS EXCLUSIVE MODE NOWAIT', v_parent_schema, v_child_table);
                    v_lock_obtained := TRUE;
                EXCEPTION
                    WHEN lock_not_available THEN
                        PERFORM sys_sleep( p_lock_wait / 5.0 );
                        CONTINUE;
                END;
                EXIT WHEN v_lock_obtained;
            END LOOP;
            IF NOT v_lock_obtained THEN
                RAISE NOTICE 'Unable to obtain lock on child table for removal from partition set';
                RETURN -1;
            END IF;
        END IF; -- END p_lock_wait IF
        v_lock_obtained := FALSE; -- reset for reuse later

        EXECUTE format('ALTER TABLE %I.%I NO INHERIT %I.%I'
                        , v_parent_schema
                        , v_child_table
                        , v_parent_schema
                        , v_parent_tablename);
        IF p_keep_table = false THEN
            EXECUTE format('DROP TABLE %I.%I', v_parent_schema, v_child_table);
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Child table DROPPED. Moved %s rows to parent', v_child_loop_total));
            END IF;
        ELSE
            IF v_jobmon_schema IS NOT NULL THEN
                PERFORM update_step(v_step_id, 'OK', format('Child table UNINHERITED, not DROPPED. Moved %s rows to parent', v_child_loop_total));
            END IF;
        END IF;
        IF v_type = 'time-custom' THEN
            DELETE FROM @extschema@.custom_time_partitions WHERE parent_table = p_parent_table AND child_table = v_parent_schema||'.'||v_child_table;
        END IF;
        v_undo_count := v_undo_count + 1;
        CONTINUE outer_child_loop;
    END IF;
    v_inner_loop_count := 1;
    v_child_loop_total := 0;
    <<inner_child_loop>>
    LOOP
        -- do some locking with timeout, if required
        IF p_lock_wait > 0  THEN
            v_lock_iter := 0;
            WHILE v_lock_iter <= 5 LOOP
                v_lock_iter := v_lock_iter + 1;
                BEGIN
                    EXECUTE format('SELECT * FROM %I.%I WHERE %I <= %L FOR UPDATE NOWAIT'
                        , v_parent_schema
                        , v_child_table
                        , v_control
                        , v_child_min + (p_batch_interval * v_inner_loop_count));
                   v_lock_obtained := TRUE;
                EXCEPTION
                    WHEN lock_not_available THEN
                        PERFORM sys_sleep( p_lock_wait / 5.0 );
                        CONTINUE;
                END;
                EXIT WHEN v_lock_obtained;
            END LOOP;
            IF NOT v_lock_obtained THEN
               RAISE NOTICE 'Unable to obtain lock on batch of rows to move';
               RETURN -1;
            END IF;
        END IF;

        -- Get everything from the current child minimum up to the multiples of the given interval
        IF v_epoch = false THEN
            v_move_sql := format('WITH move_data AS (
                                    DELETE FROM %I.%I WHERE %I <= %L RETURNING *)
                                  INSERT INTO %I.%I SELECT * FROM move_data'
                                    , v_parent_schema
                                    , v_child_table
                                    , v_control
                                    , v_child_min + (p_batch_interval * v_inner_loop_count)
                                    , v_parent_schema
                                    , v_parent_tablename);
        ELSE
            v_move_sql := format('WITH move_data AS (
                                    DELETE FROM %I.%I WHERE to_timestamp(%I) <= %L RETURNING *)
                                  INSERT INTO %I.%I SELECT * FROM move_data'
                                    , v_parent_schema
                                    , v_child_table
                                    , v_control
                                    , v_child_min + (p_batch_interval * v_inner_loop_count)
                                    , v_parent_schema
                                    , v_parent_tablename);
        END IF;
        EXECUTE v_move_sql;
        GET DIAGNOSTICS v_rowcount = ROW_COUNT;
        v_total := v_total + v_rowcount;
        v_child_loop_total := v_child_loop_total + v_rowcount;
        IF v_jobmon_schema IS NOT NULL THEN
            PERFORM update_step(v_step_id, 'OK', format('Moved %s rows to parent.', v_child_loop_total));
        END IF;
        EXIT inner_child_loop WHEN v_rowcount = 0; -- exit before loop incr if table is empty
        v_inner_loop_count := v_inner_loop_count + 1;
        v_batch_loop_count := v_batch_loop_count + 1;
        EXIT outer_child_loop WHEN v_batch_loop_count >= p_batch_count; -- Exit outer FOR loop if p_batch_count is reached
    END LOOP inner_child_loop;
END LOOP outer_child_loop;

IF v_batch_loop_count < p_batch_count THEN
    -- FOR loop never ran, so there's no child tables left.
    DELETE FROM @extschema@.part_config WHERE parent_table = p_parent_table;
    IF v_jobmon_schema IS NOT NULL THEN
        v_step_id := add_step(v_job_id, 'Removing config from sys_partman');
        PERFORM update_step(v_step_id, 'OK', 'Done');
    END IF;
END IF;

RAISE NOTICE 'Copied % row(s) to the parent. Removed % partitions.', v_total, v_undo_count;
IF v_jobmon_schema IS NOT NULL THEN
    v_step_id := add_step(v_job_id, 'Final stats');
    PERFORM update_step(v_step_id, 'OK', format('Copied %s row(s) to the parent. Removed %s partitions.', v_total, v_undo_count));
END IF;

IF v_jobmon_schema IS NOT NULL THEN
    PERFORM close_job(v_job_id);
    EXECUTE format('SELECT set_config(%L, %L, %L)', 'search_path', v_old_search_path, 'false');
END IF;

RETURN v_total;

EXCEPTION
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS ex_message = MESSAGE_TEXT,
                                ex_context = SYS_EXCEPTION_CONTEXT,
                                ex_detail = SYS_EXCEPTION_DETAIL,
                                ex_hint = SYS_EXCEPTION_HINT;
        IF v_jobmon_schema IS NOT NULL THEN
            IF v_job_id IS NULL THEN
                EXECUTE format('SELECT %I.add_job(''PARTMAN UNDO PARTITIONING: %s'')', v_jobmon_schema, p_parent_table) INTO v_job_id;
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before job logging started'')', v_jobmon_schema, v_job_id, p_parent_table) INTO v_step_id;
            ELSIF v_step_id IS NULL THEN
                EXECUTE format('SELECT %I.add_step(%s, ''EXCEPTION before first step logged'')', v_jobmon_schema, v_job_id) INTO v_step_id;
            END IF;
            EXECUTE format('SELECT %I.update_step(%s, ''CRITICAL'', %L)', v_jobmon_schema, v_step_id, 'ERROR: '||coalesce(SQLERRM,'unknown'));
            EXECUTE format('SELECT %I.fail_job(%s)', v_jobmon_schema, v_job_id);
        END IF;
        RAISE EXCEPTION '%
CONTEXT: %
DETAIL: %
HINT: %', ex_message, ex_context, ex_detail, ex_hint;
END
$$;


/*
 * Function to list all child partitions in a set.
 */
CREATE OR REPLACE FUNCTION show_partitions (p_parent_table text, p_order text DEFAULT 'ASC') RETURNS TABLE (partition_schemaname text, partition_tablename text)
    LANGUAGE plsql STABLE SECURITY DEFINER 
    AS $$
DECLARE

v_datetime_string       text;
v_parent_schema         text;
v_parent_tablename      text;
v_partition_interval    text;
v_quarter               text;
v_type                  text;
v_year                  text;

BEGIN

IF upper(p_order) NOT IN ('ASC', 'DESC') THEN
    RAISE EXCEPTION 'p_order paramter must be one of the following values: ASC, DESC';
END IF;

SELECT partition_type
    , partition_interval
    , datetime_string
INTO v_type
    , v_partition_interval
    , v_datetime_string
FROM @extschema@.part_config
WHERE parent_table = p_parent_table;

SELECT schemaname, tablename INTO v_parent_schema, v_parent_tablename FROM sys_catalog.sys_tables WHERE schemaname||'.'||tablename = p_parent_table;

IF v_type IN ('time', 'time-custom') THEN

    IF v_partition_interval::interval <> '3 months' OR (v_partition_interval::interval = '3 months' AND v_type = 'time-custom') THEN
        RETURN QUERY EXECUTE 
        format('SELECT n.nspname::text AS partition_schemaname, c.relname::text AS partition_name FROM
        sys_catalog.sys_inherits h
        JOIN sys_catalog.sys_class c ON c.oid = h.inhrelid
        JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
        WHERE h.inhparent = ''%I.%I''::regclass
        ORDER BY to_timestamp(substring(c.relname from ((length(c.relname) - position(''p_'' in reverse(c.relname))) + 2) ), %L) %s'
            , v_parent_schema
            , v_parent_tablename
            , v_datetime_string
            , p_order);
    ELSE
        -- For quarterly, to_timestamp() doesn't recognize "Q" in datetime string. 
        -- First order by just the year, then order by the quarter number (should be last character in table name)
        RETURN QUERY EXECUTE 
        format('SELECT n.nspname::text AS partition_schemaname, c.relname::text AS partition_name FROM
        sys_catalog.sys_inherits h
        JOIN sys_catalog.sys_class c ON c.oid = h.inhrelid
        JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
        WHERE h.inhparent = ''%I.%I''::regclass
        ORDER BY to_timestamp(substring(c.relname from ((length(c.relname) - position(''p_'' in reverse(c.relname))) + 2) for 4), ''YYYY'') %s
            , substring(reverse(c.relname) from 1 for 1) %s'
            , v_parent_schema
            , v_parent_tablename
            , p_order
            , p_order);
    END IF;

ELSIF v_type = 'id' THEN
    RETURN QUERY EXECUTE 
    format('SELECT n.nspname::text AS partition_schemaname, c.relname::text AS partition_name FROM
    sys_catalog.sys_inherits h
    JOIN sys_catalog.sys_class c ON c.oid = h.inhrelid
    JOIN sys_catalog.sys_namespace n ON c.relnamespace = n.oid
    WHERE h.inhparent = ''%I.%I''::regclass
    ORDER BY substring(c.relname from ((length(c.relname) - position(''p_'' in reverse(c.relname))) + 2) )::bigint %s'
        , v_parent_schema
        , v_parent_tablename
        , p_order);

END IF;

END
$$;



-- Restore dropped object privileges
DO $$
DECLARE
v_row   record;
BEGIN
    FOR v_row IN SELECT statement FROM partman_preserve_privs_temp LOOP
        IF v_row.statement IS NOT NULL THEN
            EXECUTE v_row.statement;
        END IF;
    END LOOP;
END
$$;

DROP TABLE IF EXISTS partman_preserve_privs_temp;
