# Changelog – XAUUSD Micro Gold EA

## v1.10 (2026-11-19) – bug fixes + entry filters, partial TP, session filter
Same concept as v1.00: fixed-dollar risk, H4 EMA 21/50 trend bias, entry on the
21 EMA of the chart timeframe, breakeven at 1R, ATR trailing stop, one position at a time.

### Bug fixes
- Indicator handles (iEMA/iATR) were created on every tick and never released → created once in OnInit, released in OnDeinit.
- Signals used the still-forming bar (repaint) → trend, EMA and ATR now read closed bars only.
- Entry fired on any tick price was above/below the EMA (no real pullback, re-entered right after a stop-out) → one entry per bar, wait for a new bar after a position closes, real pullback + momentum-close check.
- Entry EMA period was hard-coded to 21 → new input Entry_EMA_Period (default 21).
- Fill mode forced to IOC (Deriv may reject) → taken from the symbol's allowed filling modes.
- Default SymbolOverride "XAUUSDmicro" failed init if that exact name doesn't exist → empty = chart symbol.
- Lot size silently bumped to minimum lot even when that risked far more than RiskAmount → skip the trade if min-lot risk > RiskAmount × MaxRiskOverrun (default 2.0) and log why.
- Lot rounding used NormalizeDouble(lots, 2) and floor without epsilon → rounded to the symbol's real volume step.
- Money-per-lot used TICK_VALUE only → OrderCalcProfit (falls back to tick value).
- SL/TP prices not normalized to tick size; stop level and freeze level never checked → normalized, SL widened to the broker minimum on entry, modifications skipped when inside stop/freeze level.
- Trade results never checked (ResultRetcode) → checked and logged; 10 s cooldown after a rejected order.
- R was recalculated from the CURRENT SL, so after breakeven 1R became ~5 points → initial R stored per position (terminal global variable, survives restarts, cleaned up after close).
- After the breakeven modify, trailing used the old SL and could move the SL back below breakeven → SL refreshed after each modify; SL only ever moves in the profit direction.
- PositionModify passed TP = 0, wiping any TP → existing TP kept.
- Trailing modified on every tiny tick move (broker request spam) → minimum step Trail_Step_Points.
- Trail_Start_RR was an int (could not set 1.5) → double.
- No margin / trade-permission / symbol trade-mode checks → added.
- Removed MQL4-only `#property strict`.

### Improvements (all toggleable inputs)
- Entry filters: H4 fast-EMA slope + close vs slow EMA, ADX ≥ 20, ATR 0.6–2.0× its 50-bar average, skip after candles > 2× ATR, anti-chase (≤ 1× ATR from EMA), max spread 50 pts (kept).
- Partial take profit: close 50% at 1R, then SL to breakeven; skipped automatically if the lot can't be split into two ≥ min-lot pieces. Works on hedging and netting accounts.
- Optional fixed final TP (off by default, 3R).
- Session filter (server time): London 07–16, New York 12–20, no new trades Friday ≥ 18:00 or Monday < 02:00. Open trades are still managed outside sessions.
- Skip-reason logging (max one line per bar) so the Experts log shows why no trade was taken.

### Not done
- Not compiled (no MetaEditor available on the build machine) and not backtested. Compile in MetaEditor and run in the Strategy Tester / demo before live use. No profitability is implied.
