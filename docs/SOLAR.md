# Bada Bing Coop — Solar Power Design

How **The Bada Bing** stays alive 24/7, year-round, off-grid: a small solar
array charges a LiFePO4 battery through an MPPT controller, and a 5 V buck
converter feeds the Raspberry Pi Zero 2 W chicken-cam. This page explains the
design at a high level — *what* the system is and *why* every piece is
deliberately oversized for winter.

> **The math lives elsewhere.** This is the narrative. Every derivation, formula,
> and sensitivity table is in the verified sizing worksheet:
> **[`solar-power-budget.md`](solar-power-budget.md)**. The numbers below are
> copied from it — if the two ever disagree, the worksheet wins. For the parts
> list and physical build, see [`HARDWARE.md`](HARDWARE.md).

---

## 1. The load: a ~2.5 W cam that never sleeps

The whole design hangs off one number: the **Raspberry Pi Zero 2 W + Camera
Module 3 draws about 2.5 W on average** at 5 V. It's small *because* the Zero 2 W
has a hardware H.264 encoder, so the stream is a cheap copy with no power-hungry
software transcode. (A Pi 4 would draw ~5.5 W and double the whole system — see
the Pi 4 column in the worksheet. A Pi 5 won't work here at all; it has no
hardware encoder.)

That cam runs **24 hours a day**, so:

- It pulls ~2.5 W through a buck converter that's ~90% efficient, so the 12 V
  battery rail actually delivers about **2.78 W**.
- Over a full day that's roughly **67 Wh/day** the system must replace.

Everything else — panel, battery, controller — exists to reliably refill that
~67 Wh every day, **including** the worst short, cloudy, cold days of winter.

---

## 2. Sizing, and why each part is oversized for winter

The off-grid rule is: size for your **worst** day, not your average day. For a
year-round coop cam that means winter — few peak-sun-hours, frequent overcast,
and cold that steals battery capacity. The worksheet uses a conservative
worst-case **2.5 peak-sun-hours/day**, a **0.65** system derate (MPPT + wiring +
cold/soiling/aging + round-trip + low winter sun), **3 days of autonomy**, and
**80% usable depth of discharge** for LiFePO4.

| Part | Calc says | We pick | Why oversized |
|------|-----------|---------|---------------|
| **Solar panel** | ~41 W STC | **100 W** | Headroom for snow dusting, soiling, low winter sun angle, and short days. A panel that's "just enough" in a lab is not enough in January. |
| **LiFePO4 battery** | ~20 Ah usable (≈250 Wh gross) | **30–50 Ah** @ 12.8 V | Cold cuts usable capacity ~10–20% near freezing, and a bigger pack coasts through cold spells when the BMS won't let it charge (below). More autonomy = more grace before the cam blinks out. |
| **MPPT charge controller** | ~7.8 A | **10–15 A** MPPT (LiFePO4 profile) | Comfortably handles the 100 W panel's current with margin, and MPPT (not PWM) squeezes more out of weak, cold-angle winter light. |
| **5 V buck converter** | ~0.75 A | **3–5 A** @ ~5.1 V | Huge headroom is cheap and it's the cure for undervoltage/SD-corruption (below). |

The result: a system that's barely loaded on a good day and still keeps the cam
up through a multi-day winter overcast. See the worksheet's **sensitivity table**
if you live far north or in an especially cloudy zone — you may want to re-run at
**2.0 PSH** and stretch the battery.

---

## 3. Recommended spec (at a glance)

For the **Raspberry Pi Zero 2 W** primary build:

- **Panel:** 100 W, 12 V mono.
- **Battery:** 12.8 V LiFePO4, 30–50 Ah, with built-in BMS.
- **Charge controller:** 10–15 A MPPT set to a **LiFePO4** charge profile.
- **Buck converter:** 12 V → 5.1 V, 3–5 A.
- **Chain:** `panel → MPPT → battery → buck → Pi 5 V`, with **fuses** on the
  battery and panel legs.

Parts, prices, and enclosure/mounting details: [`HARDWARE.md`](HARDWARE.md).

---

## 4. The cold-weather LiFePO4 caveat (the one that bites people)

LiFePO4 is great for off-grid — long cycle life, deep usable discharge, no
lead-acid fragility — but it has **one serious cold-weather rule**:

> **Most LiFePO4 BMS block *charging* below 0 °C (32 °F).**

Lithium plating can permanently damage cells if you charge them while frozen, so
the BMS simply refuses charge current when cold. The nasty failure mode: a cold,
sunny winter morning where the panel is producing plenty, the battery is half
empty, and **the BMS won't accept a single watt** because the pack is below
freezing. The cam drains the pack and dies even though the sun is shining.

**Mitigations (do all that apply):**

1. **Mount the battery inside the coop**, not in an exterior box. A coop full of
   chickens is meaningfully warmer and more thermally stable than open air.
2. **Insulate the pack** so it holds the day's warmth overnight and stays above
   0 °C longer into a cold morning.
3. **Oversize the battery** (already baked into the 30–50 Ah pick) so it can
   coast through a cold stretch without *needing* to charge until things thaw.
4. *(Optional, advanced)* use a **self-heating LiFePO4** pack or one whose BMS
   has built-in low-temp cutoff *with* a heater. Note: discharging cold is fine;
   it's only **charging** cold that's the problem.

The worksheet's derate factors already assume cold capacity loss; this section is
about the *charging* block, which sizing alone can't fix — placement and
insulation do.

---

## 5. Undervoltage & SD-card corruption (the other thing that bites)

The Raspberry Pi is famously sensitive to a sagging 5 V rail. If voltage dips
under load — a long thin USB cable, a marginal buck, a tired battery — the Pi
**brown-outs**: random reboots, throttling, and the worst outcome on an off-grid
unit you can't easily reach, **SD-card corruption**. A coop cam writes to that
card for years; a corrupt card means a site visit.

**How this design avoids it:**

- **Use a 3–5 A buck set to ~5.1 V**, not 5.0 V. The cam only needs ~0.5 A, so
  the converter loafs and the rail stays rock-steady; the 5.1 V target keeps you
  well clear of the brown-out threshold even under transient draw.
- **Keep the 5 V wiring short and thick.** Most "undervoltage" is really cable
  voltage drop. Feed the Pi via the 5 V/PWR pins or a short, heavy micro-USB
  pigtail.
- **Use a high-endurance A2 microSD** (see [`HARDWARE.md`](HARDWARE.md)) and keep
  high-churn writes (logs, now-playing) on tmpfs so the card lasts.
- **Verify on the bench before sealing it up:**

  ```bash
  vcgencmd get_throttled
  # 0x0 = healthy.
  # Any non-zero value means under-voltage was detected (bit 0 = now,
  # bit 16 = since boot). If you see it, raise the buck to 5.1 V and/or
  # shorten/thicken the 5 V cable until it reads 0x0 under full load.
  ```

Leave the cam running under realistic load for a while and re-check
`get_throttled` — it should stay `0x0`.

---

## 6. The Bluetooth dongle's small extra draw

If you add the optional **classical-over-Bluetooth** music feature, it uses a
**USB Bluetooth dongle** (strongly preferred over the Zero 2 W's on-board
Bluetooth to dodge the Wi-Fi/BT radio-coexistence stutter — see
[`HARDWARE.md`](HARDWARE.md) and [`pi/badabing-music.env`](../pi/badabing-music.env)).

Power-wise the dongle is small but **not free**: it adds roughly a few tenths of
a watt to the Pi's draw (idle ~0.1 W, a bit more while streaming A2DP). That's
comfortably inside the system's winter margin — the worksheet sizes a ~67 Wh/day
load against a 100 W panel and a 30–50 Ah pack, both far larger than the bare
load needs — so the dongle doesn't change the recommended spec. Just be aware it
nudges the average load up, and don't *also* try to power the **speaker** off the
cam's solar rail: the speaker must be **separately powered** so its amplifier
never touches this power budget.

For a **camera-only** build with no music, leave the dongle out and the
power-tune script disables on-board Bluetooth entirely, trimming idle draw
further.

---

## 7. Want to change the assumptions?

Live somewhere far north, very cloudy, or want to run a Pi 4? Don't guess —
open **[`solar-power-budget.md`](solar-power-budget.md)**, edit the **Inputs**
section (PSH, days of autonomy, Pi power, etc.), and re-run the formulas. It
already includes a Pi 4 worked example and a sensitivity table for the common
"what if" cases.
