/* sys_bulkload/sys_bulkload--unpackaged--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION SYS_BULKLOAD" to load this file. \quit

ALTER EXTENSION SYS_BULKLOAD ADD FUNCTION SYS_BULKLOAD(TEXT[]);
