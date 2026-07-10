# Board XADC Pin Mapping (XC7A15T-FTG256-1, custom board)

Source: board user guide + documentation PDFs (in project root).

## Analog input headers (differential pairs to XADC)

| Header    | VAUXP (ball) | VAUXN (ball) | XADC channel | Notes |
|-----------|--------------|--------------|--------------|-------|
| Analog 1  | A5           | A4           | **VAUX5**    | On-board potentiometer — short jumper **P1** to connect the pot |
| Analog 2  | A13          | A14          | (TBD)        | Free header |
| Analog 3  | C16          | B16          | (TBD)        | Free header |
| Analog 4  | A8           | A9           | (TBD)        | Free header |

Each header also has an XGND (analog ground) pin.
VAUX numbers for headers 2–4 not stated in docs — look up in schematic / FTG256
XADC pinout before using them.

## Bring-up plan (no external wiring needed)
- Short jumper P1 -> on-board pot drives Analog 1 = VAUX5 (A5/A4).
- Run the board's built-in "Potentiometer -> LEDs via XADC" example first
  (full Vivado walkthrough in artix_documentation PDF) to prove XADC + pins +
  front-end work BEFORE attaching the FFT.

## Vivado config
- XADC Wizard: enable channel VAUX5, unipolar mode, continuous sampling,
  DCLK = 100 MHz.
- Constraints:
  set_property PACKAGE_PIN A5 [get_ports vauxp5]
  set_property PACKAGE_PIN A4 [get_ports vauxn5]

## Voltage-range caution
- XADC unipolar input limit = 1.0 V. Board docs warn input must stay in range
  and *may* have a scaling/divider network. Pot on Analog 1 is factory-wired so
  likely scaled safely — VERIFY from schematic. Treat Analog 2/3/4 as unscaled
  until confirmed; add bias + anti-alias front-end for AC signals there.
