# XAUUSD Micro Gold EA (Deriv MT5)

**Version:** 1.0  
**Symbol (default):** `XAUUSDmicro`  
**Platform:** MetaTrader 5 on Deriv  
**Designed for:** Small accounts ($10+) with fixed dollar risk

---

## Features

- Fixed dollar risk per trade (**$1 – $2** configurable)
- Automatic position sizing based on stop distance
- **Breakeven** move at +1R
- **Trailing stop** after breakeven (ATR-based)
- Works on `XAUUSDmicro` by default
- Easy switch to regular `XAUUSD` when your account grows (just change the input)
- Only one position at a time
- Clean, well-commented code

---

## How to Install on Deriv MT5

1. Download the `.mq5` file
2. Open MetaTrader 5 (Deriv)
3. File → Open Data Folder → `MQL5` → `Experts`
4. Paste the file inside the Experts folder
5. Restart MT5 or right-click Navigator → Refresh
6. Drag the EA onto the **XAUUSDmicro** chart
7. Enable **Algo Trading**
8. Adjust inputs if needed and click OK

---

## Recommended Inputs (for $10 account)

| Input              | Recommended Value | Description                          |
|--------------------|-------------------|--------------------------------------|
| RiskAmount         | 1.50              | Dollars to risk per trade ($1–$2)    |
| SymbolOverride     | XAUUSDmicro       | Leave as is for micro                |
| ATR_Period         | 14                | For stop & trailing                  |
| ATR_Multiplier     | 1.8               | Initial stop distance                |
| Breakeven_RR       | 1.0               | Move to BE at 1R                     |
| Trail_ATR_Mult     | 1.5               | Trailing distance after BE           |
| MagicNumber        | 20261119          | Unique ID for this EA                |

---

## Strategy Logic (Simple & Robust)

1. Higher timeframe bias (H4 EMA trend)
2. Pullback entry on lower timeframe
3. Limit / market entry with calculated stop
4. Move stop to Breakeven at +1R
5. Trail the stop using ATR once in profit

---

## Important Notes

- This EA is designed for **XAUUSDmicro** on Deriv so small accounts can still open positions.
- When your equity is larger, simply change `SymbolOverride` to `XAUUSD`.
- Always test on a demo account first.
- Risk $1–$2 on a $10 account is aggressive (10–20%). Use at your own risk.
- No daily loss limit is implemented (as requested).

---

**Author:** Built for Dave-4u  
**Date:** November 2026
