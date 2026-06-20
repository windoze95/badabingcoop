# Bada Bing Coop — Hardware Bill of Materials & Build Guide

Everything you need to build **The Bada Bing**: a solar-powered, off-grid
Raspberry Pi chicken-cam that pushes a stream out over WireGuard to a public
viewer. This page is the parts list plus the physical-build notes. For the
power-design reasoning (panel/battery/MPPT sizing and *why*) see
[`SOLAR.md`](SOLAR.md); for the verified sizing math see
[`solar-power-budget.md`](solar-power-budget.md).

> Prices are rough 2025-era USD ballparks for planning only — they wander with
> supply, region, and vendor. Treat the **spec** column as the requirement and
> the price as a sanity check.

---

## 1. Compute, camera & connectivity

| Item | Suggested spec | ~USD | Notes |
|------|----------------|------|-------|
| **Raspberry Pi Zero 2 W** | Quad-core BCM2710A1, on-board 2.4 GHz Wi-Fi | $18 | The primary build. Sips power (~2.5 W avg with camera) and has a **hardware H.264 encoder**, which is the whole reason the stream pipeline can be a cheap copy/no-transcode path. See the Pi-model note below. |
| **microSD card** | 32 GB, **A2**, **high-endurance** (e.g. SanDisk Max Endurance / WD Purple SC) | $12 | Endurance class matters far more than size — a coop cam runs 24/7 for years. High-endurance cards survive the write churn; cheap cards corrupt. Logs/now-playing live on tmpfs to spare it. |
| **Camera Module 3** | Official Raspberry Pi Camera Module 3 (Sony IMX708, autofocus) | $25 | Use the **Wide** variant for coop-filling field of view. For 24/7 including night, the **NoIR** variant (no IR-cut filter) paired with an IR illuminator sees in the dark; a standard module goes black at night. You can only get NoIR *or* Wide *or* Wide-NoIR — **Wide-NoIR ($35)** is the best single pick for a day+night coop cam. |
| **CSI ribbon cable** | 22-pin **0.5 mm** (mini/Zero) on the Pi end → 15-pin 1.0 mm on the camera end | $6 | The Pi Zero 2 W has the **small** CSI connector, not the full-size one on a Pi 4/5. The Camera Module 3 ships with a *standard* 15-pin cable that will NOT fit the Zero — you must buy the Zero-specific adapter cable. Buy a length that reaches your mounting spot (15–30 cm typical). |
| **USB Bluetooth dongle** | CSR8510 / RTL8761B class, BT 4.0+, Linux-friendly | $10 | **Strongly recommended** over the Zero 2 W's on-board Bluetooth — see the coexistence note below. Only needed if you run the optional music/jukebox feature. |
| **Micro-USB OTG adapter** | Micro-USB (male) → USB-A (female) OTG | $5 | The Zero 2 W has only micro-USB data ports; the BT dongle is USB-A. This adapter bridges them. Skip if you have no dongle. |
| **Bluetooth speaker** | **Separately powered**, weatherproof (IPX5+), A2DP | $30–60 | For the optional "classical-over-Bluetooth" feature. **Do not** try to power it from the Pi/solar rail — give it its own battery/charging so its amplifier draw never touches the cam's power budget. Pair it via [`pi/badabing-music.env`](../pi/badabing-music.env). |

### Pi model note — read before substituting

- **Pi Zero 2 W (recommended):** has a hardware H.264 encoder, so MediaMTX/the
  push pipeline can *copy* the camera's already-encoded H.264 with no CPU
  transcode. Lowest power, smallest enclosure.
- **Pi 5 — DO NOT USE for this build:** the Pi 5 **removed the hardware H.264
  encoder**. Streaming would require software encoding, which burns CPU and
  power and breaks the cheap copy pipeline this project is built around.
- **Pi 4 — works, but costs you power:** it keeps a hardware encoder, but its
  average draw is roughly **double** the Zero 2 W (~5.5 W vs ~2.5 W). If you use
  one, **re-size the whole power system** with the Pi 4 column in
  [`solar-power-budget.md`](solar-power-budget.md) (≈150–200 W panel,
  50–100 Ah battery, 15–20 A MPPT).

### The Zero 2 W Wi-Fi/Bluetooth coexistence problem (why a USB dongle)

The Pi Zero 2 W has a **single combo radio chip** that shares **one 2.4 GHz
antenna** between Wi-Fi and Bluetooth. This cam is already pushing H.264 over
that Wi-Fi link **24/7**. If you also stream A2DP audio over the *on-board*
Bluetooth, the two protocols fight for the same radio and the same time slots —
the result is badly stuttering music and/or a hitching video stream.

The fix is a **USB Bluetooth dongle on its own controller**: Bluetooth audio
then rides a completely separate radio and never competes with the camera's
Wi-Fi. The power-tune script's `dtoverlay=disable-bt` turns the on-board radio
off so the dongle becomes the sole controller (`hci0`); see
[`pi/badabing-music.env`](../pi/badabing-music.env) for the `BT_CONTROLLER`
selection logic. If you do **not** run the music feature, omit the dongle and
the OTG adapter entirely.

---

## 2. Power system (off-grid solar)

These quantities come straight from the verified sizing worksheet for the
**Zero 2 W**; see [`solar-power-budget.md`](solar-power-budget.md) for the
derivation and [`SOLAR.md`](SOLAR.md) for the design narrative. The picks below
are deliberately **oversized for winter** so the cam survives short, cloudy,
cold days.

| Item | Suggested spec | ~USD | Notes |
|------|----------------|------|-------|
| **Solar panel** | **100 W** 12 V mono (rigid framed) | $70–110 | Calc says ~41 W is enough at worst-case winter sun; 100 W gives margin for snow dusting, soiling, low sun angle, and short days. A rigid framed panel is easiest to aim and mount. |
| **LiFePO4 battery** | **12.8 V, 30–50 Ah** (4S, with built-in BMS) | $90–170 | Calc needs ~20 Ah usable at 3 days autonomy; 30–50 Ah covers cold-capacity loss and gives a comfortable buffer. **LiFePO4, not lead-acid** — better cold/cycle life and 80% usable depth of discharge. Mind the cold-charging caveat (below and in `SOLAR.md`). |
| **MPPT charge controller** | **10–15 A** MPPT, 12 V auto, with **LiFePO4 charge profile** | $30–60 | ~7.8 A at 100 W / 12.8 V → a 10–15 A controller. Must support a LiFePO4 (not lead-acid) charge curve. MPPT (not PWM) for better cold/low-light harvest. Many include a low-voltage load disconnect. |
| **5 V buck converter** | **5.1 V out, 3–5 A**, 12 V→5 V synchronous DC-DC | $8–15 | The Pi only needs ~0.5 A, but **use a 3–5 A buck at ~5.1 V** for big headroom and to fight the Pi's notorious undervoltage/SD-corruption gremlins. 5.1 V (not a sagging 4.9 V) keeps you clear of the brown-out threshold. Feed the Pi via the **PWR/5V pins or a quality micro-USB pigtail**, kept short and thick. |
| **INA219 current/voltage monitor** *(optional)* | Breakout with on-board **0.1 Ω shunt** + I2C pull-ups (Adafruit or clone) | $6 | Optional battery telemetry → `status.json`. Wire it on the **pack side** (between battery + and the buck input +). Full wiring in [`pi/INA219-WIRING.md`](../pi/INA219-WIRING.md). |

> **Wiring direction reminder:** the chain is
> `panel → MPPT → battery (+ INA219 if fitted) → buck → Pi 5 V`. The MPPT charges
> *from* the panel and *to* the battery; the load (buck) hangs off the
> battery/load terminals, never directly off the panel.

---

## 3. Enclosure, weatherproofing & mounting

| Item | Suggested spec | ~USD | Notes |
|------|----------------|------|-------|
| **Outdoor enclosure** | **IP65+** ABS/polycarbonate junction box, sized to fit Pi + buck + wiring with airflow | $15–30 | Houses the Pi and buck (and INA219 if used). Light color reflects sun → runs cooler. Size up: cramped boxes trap heat. Mount lid-down or with a drip edge so rain runs off the seams. |
| **Cable glands** | **IP68** glands sized to your cable OD (e.g. PG7/PG9), one per cable entry | $1–2 ea | One gland per cable passing through the wall (camera ribbon route, panel/battery DC, speaker if applicable). **Always enter from the bottom/side**, never the top. Unused holes get a blanking plug. |
| **Camera window** | **Anti-fog / anti-reflective acrylic** or optical-grade window, sized to the lens | $5–12 | The lens needs a clear, sealed port. Use **anti-reflective** acrylic to avoid glare and an **IR-friendly** material if running the NoIR variant + IR illuminator. See condensation notes below. |
| **IR illuminator** *(if NoIR)* | 850 nm IR LED board, 5 V or separately powered | $8–15 | Needed for night vision with the NoIR camera. **Mount it OUTSIDE the camera window** (or separated by a baffle) so its light doesn't bounce off the acrylic straight back into the lens (washout). Watch its draw if powered from the cam rail. |
| **Desiccant** | Reusable silica-gel pack(s) | $5 | Tossed inside the sealed enclosure to soak up trapped humidity and fight internal condensation/fogging. Recharge (bake) periodically. |
| **Mounting hardware** | Stainless screws/bolts, pole or wall bracket, panel tilt bracket, UV-resistant zip ties / cable clips | $10–20 | Stainless = no rust in a wet, ammonia-rich coop environment. A tilt bracket lets you aim the panel at the winter sun (see `SOLAR.md`). |
| **Inline DC fuse(s)** | **Blade fuse holder + fuses** sized just above each leg's max current (e.g. ~15 A battery leg, ~10 A panel leg) | $5 | **Fuse the battery output and the panel input.** LiFePO4 packs deliver enormous fault current; an unfused short is a fire risk. Put the fuse as close to the battery + terminal as practical. |

---

## 4. Physical build notes

### Camera window, condensation & IR

- **Seal the lens to the window, not just the box.** Mount the camera so its lens
  sits right behind (or lightly gasketed against) the acrylic window. A gap
  between lens and window is where dust and internal reflections live.
- **Condensation is the #1 enemy.** Outdoor day/night temperature swings drive
  moisture out of the air and onto the coldest surface — usually the inside of
  your camera window at dawn, fogging the picture. Mitigate by (1) sealing the
  enclosure well, (2) adding **silica-gel desiccant** inside, and (3) using an
  **anti-fog** coated window. The tiny waste heat of the Pi nearby also helps
  keep the window above dew point.
- **Anti-reflective acrylic** avoids ghost reflections of the LEDs/lens. If you
  run **NoIR + an IR illuminator**, make sure the window passes IR (most clear
  acrylic does) and keep the IR source **outside** the window or behind a baffle
  — IR bouncing off the inside of the glass back into the lens produces a hazy,
  washed-out night image. This is the classic "foggy night cam" failure.

### Mounting & aim for a coop

- **Camera:** mount high in a corner looking down across the run/roost so you
  catch the whole cast (Tony, Adriana, Pussi, Rorschach). Avoid pointing at a
  bright window/sky behind the birds — backlight silhouettes them. Keep the lens
  out of direct splatter range of the roost bar.
- **Solar panel:** mount **outside** with a clear south-facing sky view (northern
  hemisphere), tilted up for the **winter** sun (a steep tilt ≈ latitude + 15°
  sheds snow and catches the low sun). Keep it clear of coop shadows, trees, and
  the chickens' favorite perch. Run the panel leads down to the MPPT inside the
  enclosure through a bottom cable gland.
- **Battery + MPPT:** keep them **out of the weather and out of the cold** — see
  the cold-charging note below. The **coop interior** (above the litter, away
  from droppings/dust) is warmer and more stable than an exterior box.

### Weatherproofing

- Cable glands **enter from the bottom or side only**; water finds top entries.
- Leave a **drip loop** in each external cable so water runs off the loop instead
  of tracking into the gland.
- Coops are **corrosive** (ammonia + humidity + dust). Use stainless fasteners,
  keep electronics sealed, and route cables away from where birds peck/roost.
- Add desiccant and re-seal after any time you open the box.

### Where to mount the INA219 (if fitted)

Put the INA219 on the **pack side** of the power chain — in series between the
**battery +** and the **buck converter input +** — so `status.json` reports true
battery voltage and rough state-of-charge, not the regulated 5 V. Full pin-out,
I2C address, and the high-side wiring diagram are in
[`pi/INA219-WIRING.md`](../pi/INA219-WIRING.md). Keep its logic side on the Pi's
**3.3 V** pin (never 5 V).

### Thermal & cold considerations

- **Heat:** the Pi runs fine sealed, but a dark box in direct summer sun cooks.
  Use a **light-colored** enclosure, give it a little internal air space, and
  shade it if possible. The power-tune script already trims idle heat by
  disabling HDMI, on-board audio, and the LEDs.
- **Cold:** the Pi itself tolerates cold well, but the **LiFePO4 battery does
  not like to charge below 0 °C** — most BMS block charging when cold, so a
  freezing battery stops accepting solar even on a sunny winter day. Mount the
  battery **inside the coop** (warmer), insulate it, and **oversize** so it
  coasts through cold spells without needing to charge. See the cold-weather
  section of [`SOLAR.md`](SOLAR.md).

---

## 5. Quick shopping summary (Zero 2 W primary build)

Core cam + power, *excluding* the optional music dongle/speaker and optional
INA219:

| Group | Items |
|-------|-------|
| Compute/camera | Pi Zero 2 W, 32 GB A2 high-endurance microSD, Camera Module 3 (Wide-NoIR), Zero-specific CSI cable |
| Power | 100 W panel, 30–50 Ah LiFePO4, 10–15 A MPPT (LiFePO4 profile), 5.1 V 3–5 A buck, fuses |
| Enclosure | IP65+ box, IP68 cable glands, anti-fog/AR camera window, desiccant, stainless mounting + tilt brackets |
| Optional | INA219 (telemetry), USB BT dongle + micro-USB OTG adapter + separately-powered weatherproof speaker (music) |

Total for the core build typically lands around **$280–450** depending on
battery size and vendor — most of it in the panel + battery. The optional music
and telemetry bits add roughly **$50–90**.
