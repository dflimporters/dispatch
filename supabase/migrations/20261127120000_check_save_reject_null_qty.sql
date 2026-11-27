-- A line with no final_qty used to slip past validation (null < 0 is null) and then
-- fail the not-null constraint on check_lines with an unhelpful error.
do $$
declare def text;
begin
  select pg_get_functiondef('public.dispatch_check_save(bigint,jsonb)'::regprocedure) into def;
  def := replace(def, 'where ls.shipment_nbr is null or sl.line_nbr is null or x.q < 0',
                      'where ls.shipment_nbr is null or sl.line_nbr is null or x.q is null or x.q < 0');
  execute def;
end $$;
