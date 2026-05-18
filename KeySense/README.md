# KeySense

**KeySense** is a World of Warcraft Retail addon that helps Mythic+ group leaders quickly evaluate LFG applicants.

It provides a fast-read **Applicant Impact** and **Applicant Fit** estimate for Mythic+ applicants based on available in-game data such as:

- Mythic+ score
- Item level
- Role
- Dungeon-specific history, when available
- Current group role needs
- Current group utility needs
- Basic class utility contribution
- Optional local notes
- Optional manually imported external profile modifiers

KeySense is designed as a **decision-support tool**, not an automatic invite/decline system.

---

## Current Status

KeySense is currently an early MVP.

It focuses on:

- Scanning active LFG applicants
- Showing a standalone applicant scoring panel
- Ranking applicants by estimated impact
- Providing mouseover explanations
- Displaying useful “Good” and “Watch” signals

It does **not** currently calculate a true statistical chance of timing a key.

---

## What KeySense Does

When you list or manage a Mythic+ group, KeySense can scan current applicants and show:

```text
Impact     Fit          Role    Ilvl     IO      Applicant
+17        Strong       DPS     724      2310    Player-Realm
+6         Playable     Healer  718      2050    Player-Realm
-4         Risky        DPS     701      980     Player-Realm
