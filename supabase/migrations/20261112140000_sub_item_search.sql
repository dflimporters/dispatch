-- 2026-11-12. Substitute-item search from the local item list (Joel).
--
-- The Invoicing page's substitute search called Acumatica through dispatch-sub: slow (sign in, call, sign out, each
-- paced) and it matched the whole typed phrase as one string, so "Covebay Fold Back" missed
-- "Covebay 8oz Hot Cup Fold Back Flat Lid". This searches stock_items_raw (synced from Acumatica every few minutes)
-- instead: every word typed must appear in the name or item number, in any order. Active items only, 20 at most.
-- dispatch-sub's run step still checks the chosen item against Acumatica before it creates anything.
-- Rollback: drop function public.sub_item_search(text);

create function public.sub_item_search(p_q text) returns table (inventory_id text, description text)
language sql stable security definer set search_path = public as $$
  select s.inventory_id, s.description
    from stock_items_raw s
   where dispatch_has_role()
     and s.item_status = 'Active'
     and length(btrim(coalesce(p_q, ''))) >= 2
     and not exists (
       select 1
         from unnest(regexp_split_to_array(btrim(left(p_q, 60)), '\s+')) as w(word),
              lateral (select '%' || replace(replace(replace(w.word, chr(92), chr(92) || chr(92)), '%', chr(92) || '%'), '_', chr(92) || '_') || '%' as pat) p
        where w.word <> '' and not (s.description ilike p.pat or s.inventory_id ilike p.pat))
   order by (s.inventory_id ilike btrim(p_q) || '%') desc, s.description
   limit 20;
$$;
revoke all on function public.sub_item_search(text) from public, anon;
grant execute on function public.sub_item_search(text) to authenticated;
