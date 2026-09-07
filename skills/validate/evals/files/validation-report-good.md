# Validation Report: ShiftPost

## Core assumption

A bandleader who loses a player hours before a paid private event will pay a fee
to reach a vetted same-day replacement rather than cancel or scramble.

## Fatal flaws (ranked)

1. Distribution (P0). If bandleaders do not think of ShiftPost in the crisis
   moment, it is dead. Cheapest test: seed the operator's two hundred musicians
   and measure how many post a real slot in two weeks.
2. Pricing (P0). If the saved-gig fee is more than the bandleader will pay under
   pressure, no transaction closes. Cheapest test: quote three fee levels to ten
   past requesters and record which they accept.
3. Liquidity (P1). A posted slot with no available player is a broken promise.
   Cheapest test: check same-day response rate across ten seeded slots.

## Competition: current behavior

Today the bandleader texts a personal group chat, calls two or three known
players, and if that fails cancels or plays short. The competition is the group
chat and the phone, not another app.

## First ten customers

1. Marco, bandleader of a wedding quartet, reachable by the operator's text.
2. Dana, jazz-trio leader who asked for a fill-in last month.
3. The Halcyon Room's house-band manager.
4. Priya, function-band leader in the operator's roster.
5. Sam, drummer who often subs and asks for work.
6. The Ellis Hotel events coordinator who books bands.
7. Nina, string-quartet contractor.
8. Owen, brass-section leader.
9. The Vine Street venue booker.
10. Tomas, bandleader who cancelled a gig last quarter for a missing player.

## Two-week behavioral test

Seed the roster, then count real posted slots and closed replacements over two
weeks. Success threshold: at least five real slots posted and at least three
filled with a paid replacement.

## Verdict

Strong. The pain is acute and time-boxed, the operator can reach both sides of
the market today, and the behavioral test is cheap and fast. Distribution and
pricing are the two ways it dies, and both have a two-week test that resolves
them before any build.
