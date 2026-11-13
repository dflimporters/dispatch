# Transfer cycle (go-live Monday 2026-11-16)

Purpose: slow down slightly so orders go out **in full**. A "day between" gives time to
bring stock up from the off-site warehouse (Ashenheim) to 71 before orders are batched and
picked. Cutoffs are rigid; reps and merchandisers submit orders before 2pm.

## Cycle

**Day 1**
- **2:00pm** Sales order cutoff.
- **2:00pm** Someone presses the button to generate the transfer list (already built).
  The list looks at SOs with a ship date within **48 hours** (mostly hotels with future
  ship dates) so it isn't overstated.
- List is vetted and passed to the off-site warehouse (Ashenheim).
- 2pm to 5pm: Ashenheim picks, packs and delivers the transfer to 71. Possibly about 2
  containers, roughly 40 pallets (18 pallets per container).
- 5pm onwards: 71 DC warehouse is cleaned and packed up; transfer boxes are offloaded and
  racked as best as possible (late shift crew).
- **Late night (new):** batching for in-town and near-country orders, so pick lists are
  ready at 8am on Day 2. Done by whichever supervisor is on the late shift (Joel, Kyle,
  Luke, Tevin or Teondray). Batching can only start **after the transfer is up and
  released into Acumatica at 71**.

**Day 2**
- 8:00am picking begins from the loads created the night before.
- 8:30am to 11:30am in-town and near-country truckers arrive to collect loads.
- Picking and loading continue all day; final truck hopefully leaves about 6pm, so
  far-country delivery lands on Day 3 (the 48-hour cycle).
- Meanwhile the next transfer cycle starts (2pm cutoff).

## Requirement: cycle snapshot and batch view

Problem: the late-night batcher must not batch sales orders that arrived after the 2pm
cutoff, because that would use up transfer stock meant for the cutoff set.

1. **Snapshot at the button press.** When the transfer list is generated, the platform
   saves the set of SOs it was built from (order number, lines, ship date) against that
   list (TR-DDMM-NN) as "this cycle's batch set".
2. **Batch view.** The batcher (late supervisor) sees that set: each SO is marked
   **in this cycle**. SOs that arrived after the cutoff, or whose ship date is beyond 48
   hours, are clearly marked **next cycle** and are not offered for batching.
3. **Release gate.** The batch view only becomes actionable once the transfer is up and
   released into Acumatica at 71 (a status shown to the batcher; a manual "transfer
   received at 71" confirm is acceptable until the portal can read the completed
   Transfer Order).
4. Shows who is batching and when, for audit.

## Rules the list must follow

- SO cutoff is 2pm. Orders after it belong to the next cycle.
- Ship-date window: 48 hours.
- Only the cutoff set is batched against transfer stock.

## Built (2026-11-13)

- Transfers page builds from open SOs (window = since the previous list's cut-off, so Monday covers the weekend; fixed-hours selector, 48 h ship-date horizon with include toggle and flags),
  pallets and container estimate, manual add, Sent -> Received status.
- Cycle snapshot (`transfer_list_orders`) and the batcher banner / gate / "not in cycle" tags in `batcher.html`.
- Next: write the Acumatica Transfer Order (TR) from the sent list; read received from Acumatica.

## Open questions

- Who presses the 2pm button, and who vets the list? (not decided)
- Tevin, Teondray and Alecia need the coordinator (`batcher`) role (Admin page > Users).
- Picking currently requires the trucker to be locked in on the load; on Day 2 truckers
  arrive 8:30am to 11:30am but picking starts 8am. How do night-batched loads become
  pickable?
