-- Fixed bug in reapply_indexes.py script that could cause all new indexes to be added to the parent instead of the children. This was happening if the parent table's schema was in the search_path of the role that the script uses to connect to the database.
-- Removed any unneeded library imports in all python scripts.
-- Moved python scripts from "extras" folder to "bin" folder. Now that they're actually getting installed as part of "make install" they're not really extras anymore.
-- No code changes to core extension, however this file is required to update to sys_partman 1.4.5 and higher.
