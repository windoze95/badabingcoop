# Bada Bing Coop — Chicken-Cam Solar Power Budget Calculator

A reusable worksheet for sizing an off-grid 12 V solar system that runs a
Raspberry Pi camera 24/7 outdoors, year-round. Plug in your own numbers in the
"Inputs" section; the formulas below show exactly how every figure is derived.
Worked numbers for a **Raspberry Pi Zero 2 W** (primary build) and a
**Raspberry Pi 4** (heavier alternative) are included.

---

## 1. Inputs (edit these)

| Symbol | Meaning                                   | Zero 2 W | Pi 4   |
|--------|-------------------------------------------|----------|--------|
| P_pi   | Avg Pi+camera DC power at 5 V (W)          | 2.5      | 5.5    |
| eta_buck | 12V->5V buck converter efficiency        | 0.90     | 0.90   |
| eta_sys | System derate (wiring, MPPT, temp, soiling, batt round-trip) | 0.65 | 0.65 |
| PSH    | Worst-case winter peak-sun-hours/day      | 2.5      | 2.5    |
| DoA    | Days of autonomy (cloudy days)            | 3        | 3      |
| DoD    | Usable depth of discharge (LiFePO4)       | 0.80     | 0.80   |
| V_batt | Battery nominal voltage (V)               | 12.8     | 12.8   |

---

## 2. Formulas

```
# Load side
P_dc12   = P_pi / eta_buck                 # 12V-rail power the load actually pulls
E_day    = P_dc12 * 24 / 1000              # daily energy at 12V rail, Wh -> kWh-ish (Wh)

# Solar array
P_array  = E_day / (PSH * eta_sys)         # required STC panel watts

# Battery
E_store  = E_day * DoA                      # energy to carry through DoA cloudy days
E_batt   = E_store / DoD                     # gross battery energy (size for usable = E_store)
Ah_batt  = E_batt / V_batt                   # battery capacity in Ah at 12.8V

# Charge controller
I_cc     = P_array / V_batt                  # ballpark controller current (use Isc-based for real spec)

# Buck converter
I_5v     = P_pi / 5.0                         # 5V output current the Pi needs
I_buck   = I_5v * 1.5                          # spec with >=50% headroom
```

---

## 3. Worked numbers — Raspberry Pi Zero 2 W

```
P_dc12  = 2.5 / 0.90              = 2.78 W
E_day   = 2.78 * 24              = 66.7 Wh/day
P_array = 66.7 / (2.5 * 0.65)    = 41.0 W   -> pick 100 W (margin for snow/short days)
E_store = 66.7 * 3              = 200 Wh
E_batt  = 200 / 0.80            = 250 Wh
Ah_batt = 250 / 12.8           = 19.6 Ah  -> pick 30-50 Ah LiFePO4 (cold + margin)
I_cc    = 100 / 12.8           = 7.8 A    -> 10-15 A MPPT
I_5v    = 2.5 / 5              = 0.5 A
I_buck  = 0.5 * 1.5            = 0.75 A   -> use a 3-5 A buck (cheap, big headroom)
```

## 4. Worked numbers — Raspberry Pi 4

```
P_dc12  = 5.5 / 0.90             = 6.11 W
E_day   = 6.11 * 24            = 146.7 Wh/day
P_array = 146.7 / (2.5 * 0.65) = 90.3 W   -> pick 150-200 W
E_store = 146.7 * 3           = 440 Wh
E_batt  = 440 / 0.80         = 550 Wh
Ah_batt = 550 / 12.8        = 43.0 Ah   -> pick 50-100 Ah LiFePO4
I_cc    = 150 / 12.8        = 11.7 A    -> 15-20 A MPPT
I_5v    = 5.5 / 5          = 1.1 A
I_buck  = 1.1 * 1.5       = 1.65 A    -> use a 3-5 A buck
```

---

## 5. Why the derate factors are what they are

- **eta_buck = 0.90**: typical synchronous DC-DC buck at these currents.
- **eta_sys = 0.65**: stacks MPPT (~0.97) x wiring (~0.98) x cold/soiling/aging
  (~0.85) x LiFePO4 round-trip (~0.95) x winter low-angle/short-day capture
  losses. 0.65 is a conservative all-in number; many guides use 0.70-0.75.
- **PSH = 2.5**: a defensible mid-latitude US winter worst case. Northern tier
  (NY/upper Midwest) ~2.0-2.5; Southwest ~4+. Drop to 2.0 and re-run if you are
  far north or shaded.
- **DoD = 0.80**: LiFePO4 tolerates deeper discharge than lead-acid; 80% is safe
  and preserves cycle life. Note cold cuts usable capacity ~10-20% near 0 C, and
  most BMS block CHARGING below 0 C — see safety notes in the main BOM.

---

## 6. Quick sensitivity table (Zero 2 W, change one input)

| Change                        | New P_array | New Ah |
|-------------------------------|-------------|--------|
| PSH 2.5 -> 2.0 (far north)     | 51 W        | 20 Ah  |
| DoA 3 -> 5 (very cloudy zone)  | 41 W        | 33 Ah  |
| P_pi 2.5 -> 1.5 (tuned/idle)   | 25 W        | 12 Ah  |

The recommended build (100 W panel, 30-50 Ah battery, 10-15 A MPPT) covers all
of these comfortably for the Zero 2 W and most of them for a Pi 4.
