-- Load numbers are found with or without dashes and spaces (Joel, 2026-10-30): "L-1030-PM-05",
-- "l 1030 pm 05" and "1030pm05" all find the same load. The browser pages do this in common.js
-- (nbrMatches); this does it for the two server-side searches, admin_load_find and admin_audit,
-- by adding one OR to each existing load_nbr ilike. Needs 3+ letters/digits after stripping.
--
-- Rollback: replace each added "or (length(regexp_replace(q ..." clause with nothing.

do $$
declare
  d text; old text; new text;
begin
  d := pg_get_functiondef('public.admin_load_find(text)'::regprocedure);
  old := 'l.load_nbr ilike ''%'' || q || ''%''';
  new := old || ' or (length(regexp_replace(q, ''[^A-Za-z0-9]'', '''', ''g'')) >= 3 and regexp_replace(l.load_nbr, ''[^A-Za-z0-9]'', '''', ''g'') ilike ''%'' || regexp_replace(q, ''[^A-Za-z0-9]'', '''', ''g'') || ''%'')';
  if position(old in d) = 0 then raise exception 'admin_load_find: clause not found'; end if;
  execute replace(d, old, new);

  d := pg_get_functiondef('public.admin_audit(text, text, timestamptz, timestamptz, int, bigint)'::regprocedure);
  old := 'or load_nbr ilike ''%'' || q || ''%''';
  new := old || ' or (length(regexp_replace(q, ''[^A-Za-z0-9]'', '''', ''g'')) >= 3 and regexp_replace(load_nbr, ''[^A-Za-z0-9]'', '''', ''g'') ilike ''%'' || regexp_replace(q, ''[^A-Za-z0-9]'', '''', ''g'') || ''%'')';
  if position(old in d) = 0 then raise exception 'admin_audit: clause not found'; end if;
  execute replace(d, old, new);
end $$;
