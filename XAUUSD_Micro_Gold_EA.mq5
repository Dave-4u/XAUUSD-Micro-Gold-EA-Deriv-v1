//+------------------------------------------------------------------+
//|                                      XAUUSD_Micro_Gold_EA.mq5    |
//|   Fixed $ Risk + H4 EMA bias + EMA pullback entry                |
//|   Breakeven + ATR trailing + Partial TP + Session filter         |
//|   Designed for Deriv MT5 gold (XAUUSD / micro gold)              |
//+------------------------------------------------------------------+
#property copyright   "Dave-4u / Gold Micro EA"
#property link        "https://github.com/Dave-4u/XAUUSD-Micro-Gold-EA-Deriv-v1"
#property version     "1.10"
#property description "Fixed-dollar-risk gold EA: H4 EMA trend bias, EMA pullback entry,"
#property description "breakeven, ATR trailing, optional partial TP and session filter."
#property description "Test on a demo account first. No profit is guaranteed."

#include <Trade\Trade.mqh>
CTrade trade;

//--- INPUTS
input group "=== Risk Management ==="
input double   RiskAmount          = 1.50;      // Dollars to risk per trade ($1 - $2)
input double   MaxRiskOverrun      = 2.0;       // Skip trade if min lot would risk more than RiskAmount x this
input int      MagicNumber         = 20261119;  // Magic Number
input int      SlippagePoints      = 20;        // Max slippage (points)

input group "=== Symbol & Timeframe ==="
input string          SymbolOverride = "";      // Empty = chart symbol (or type the exact name, e.g. XAUUSD)
input ENUM_TIMEFRAMES EntryTF        = PERIOD_CURRENT; // Entry timeframe (chart TF by default)

input group "=== Stop & Trailing ==="
input int      ATR_Period          = 14;        // ATR Period
input double   ATR_Multiplier      = 1.8;       // Initial Stop = ATR * this
input bool     UseBreakeven        = true;      // Move stop to breakeven
input double   Breakeven_RR        = 1.0;       // Move to Breakeven at this R multiple
input int      BE_Buffer_Points    = 5;         // Breakeven buffer beyond entry (points)
input bool     UseTrailing         = true;      // Use ATR trailing stop
input double   Trail_ATR_Mult      = 1.5;       // Trailing Stop = ATR * this
input double   Trail_Start_RR      = 1.0;       // Start trailing after this R
input int      Trail_Step_Points   = 10;        // Only move trailing SL if it improves by at least this (points)

input group "=== Partial Take Profit ==="
input bool     UsePartialTP        = true;      // Close part of the position at PartialTP_RR
input double   PartialTP_RR        = 1.0;       // R multiple for the partial close
input double   PartialClosePct     = 50.0;      // Percent of the position to close
input bool     BE_AfterPartial     = true;      // Move SL to breakeven right after the partial close

input group "=== Final Take Profit (optional) ==="
input bool     UseFinalTP          = false;     // Put a fixed TP on the trade (off = trailing only, as v1.00)
input double   FinalTP_RR          = 3.0;       // Fixed TP at this R multiple

input group "=== Trend Bias (higher timeframe) ==="
input ENUM_TIMEFRAMES TrendTF       = PERIOD_H4; // Trend timeframe
input int      EMA_Fast            = 21;        // Fast EMA
input int      EMA_Slow            = 50;        // Slow EMA
input bool     RequireTrendSlope   = true;      // Fast EMA must be rising (buys) / falling (sells)
input bool     RequirePriceVsSlow  = true;      // Last closed trend bar must be above slow EMA (buys) / below (sells)

input group "=== Entry (pullback + momentum) ==="
input int      Entry_EMA_Period    = 21;        // Entry-timeframe EMA
input bool     RequirePullback     = true;      // Signal bar must pull back to the entry EMA
input double   Pullback_ATR        = 0.3;       // ...within this x ATR of the EMA
input bool     RequireMomentumClose= true;      // Signal bar must close in trade direction
input double   MaxEMADist_ATR      = 1.0;       // Anti-chase: price no further than this x ATR from EMA (0 = off)

input group "=== Entry Filters ==="
input int      Max_Spread_Points   = 50;        // Max allowed spread (points)
input bool     UseADXFilter        = true;      // Require trend strength
input int      ADX_Period          = 14;        // ADX Period
input double   MinADX              = 20.0;      // Minimum ADX on the entry timeframe
input bool     UseATRFilter        = true;      // Skip dead or wild volatility
input int      ATR_AvgBars         = 50;        // Bars for the average ATR
input double   MinATRRatio         = 0.6;       // Skip if ATR < average x this (too quiet)
input double   MaxATRRatio         = 2.0;       // Skip if ATR > average x this (too wild)
input bool     UseBigCandleFilter  = true;      // Skip after an oversized signal candle
input double   MaxCandleATR        = 2.0;       // Oversized = high-low > ATR x this

input group "=== Session Filter (broker SERVER time) ==="
input bool     UseSessionFilter    = true;      // Only open new trades in the sessions below
input bool     TradeLondon         = true;      // London session
input int      LondonStartHour     = 7;         // London start hour (server)
input int      LondonEndHour       = 16;        // London end hour (server)
input bool     TradeNewYork        = true;      // New York session
input int      NYStartHour         = 12;        // New York start hour (server)
input int      NYEndHour           = 20;        // New York end hour (server)
input bool     BlockFridayLate     = true;      // No new trades late on Friday
input int      FridayStopHour      = 18;        // ...from this server hour
input bool     BlockMondayEarly    = true;      // No new trades early on Monday
input int      MondayStartHour     = 2;         // ...until this server hour

input group "=== Logging ==="
input bool     VerboseLog          = true;      // Print why no trade was opened (when the reason changes, max hourly repeat)

//--- Globals
string   TradeSymbol;
double   PointValue;
int      DigitsValue;
ENUM_TIMEFRAMES TF;

int      hTrendFast = INVALID_HANDLE;
int      hTrendSlow = INVALID_HANDLE;
int      hEntryEMA  = INVALID_HANDLE;
int      hATR       = INVALID_HANDLE;
int      hADX       = INVALID_HANDLE;

datetime lastEntryBar   = 0;     // bar on which we last opened (or a position closed)
datetime lastFailTime   = 0;     // cooldown after a failed order
datetime lastCleanupBar = 0;
bool     hadPosition    = false;
string   GVPrefix;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   TradeSymbol = (SymbolOverride == "") ? _Symbol : SymbolOverride;
   TF          = (EntryTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : EntryTF;

   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("ERROR: Symbol ", TradeSymbol, " not found. Check Market Watch / the exact symbol name.");
      return(INIT_FAILED);
   }

   //--- input sanity checks
   if(RiskAmount <= 0 || ATR_Period < 1 || ATR_Multiplier <= 0 || EMA_Fast < 1 || EMA_Slow < 1 ||
      Entry_EMA_Period < 1 || ADX_Period < 1 || ATR_AvgBars < 1)
   {
      Print("ERROR: invalid input values (periods/multipliers/risk must be positive).");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(EMA_Fast >= EMA_Slow)
   {
      Print("ERROR: EMA_Fast must be smaller than EMA_Slow.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UsePartialTP && (PartialClosePct <= 0 || PartialClosePct >= 100))
   {
      Print("ERROR: PartialClosePct must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   PointValue  = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   DigitsValue = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   //--- indicator handles: created ONCE here (v1.00 created new ones every tick)
   hTrendFast = iMA(TradeSymbol, TrendTF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hTrendSlow = iMA(TradeSymbol, TrendTF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hEntryEMA  = iMA(TradeSymbol, TF, Entry_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hATR       = iATR(TradeSymbol, TF, ATR_Period);
   hADX       = iADX(TradeSymbol, TF, ADX_Period);
   if(hTrendFast == INVALID_HANDLE || hTrendSlow == INVALID_HANDLE || hEntryEMA == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || hADX == INVALID_HANDLE)
   {
      Print("ERROR: could not create indicator handles. Error ", GetLastError());
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetMarginMode();
   if(!trade.SetTypeFillingBySymbol(TradeSymbol))   // use what the broker allows (v1.00 forced IOC)
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   GVPrefix = "XMG_" + IntegerToString(MagicNumber) + "_";

   Print("XAUUSD Micro Gold EA v1.10 initialized on ", TradeSymbol, " ", EnumToString(TF),
         " | Risk: $", DoubleToString(RiskAmount, 2),
         " | MinLot ", DoubleToString(SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN), 3),
         " | Step ", DoubleToString(SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP), 3),
         " | StopsLevel ", SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL), " pts");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hTrendFast != INVALID_HANDLE) IndicatorRelease(hTrendFast);
   if(hTrendSlow != INVALID_HANDLE) IndicatorRelease(hTrendSlow);
   if(hEntryEMA  != INVALID_HANDLE) IndicatorRelease(hEntryEMA);
   if(hATR       != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX       != INVALID_HANDLE) IndicatorRelease(hADX);
   Print("EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Manage existing position(s) first (partial TP, BE, trailing)
   ManageOpenPositions();

   datetime bar0 = iTime(TradeSymbol, TF, 0);
   if(bar0 == 0) return;

   if(bar0 != lastCleanupBar)
   {
      CleanupGlobals();
      lastCleanupBar = bar0;
   }

   //--- Only one position at a time
   bool hasPos = (CountMyPositions() > 0);
   if(hasPos) { hadPosition = true; return; }
   if(hadPosition)                   // a position just closed: wait for a new bar
   {
      hadPosition  = false;
      lastEntryBar = bar0;
   }

   if(bar0 == lastEntryBar) return;                    // max one entry per bar
   if(TimeCurrent() - lastFailTime < 10) return;       // cooldown after a rejected order

   if(!TradingAllowed()) return;

   if(!SessionOK())                { LogSkip(bar0, "outside trading session"); return; }

   int spreadPts = CurrentSpreadPoints();
   if(spreadPts > Max_Spread_Points) { LogSkip(bar0, "spread " + IntegerToString(spreadPts) + " > " + IntegerToString(Max_Spread_Points)); return; }

   //--- Trend bias from higher timeframe (closed bars only)
   int trend = GetTrend();
   if(trend == 0) { LogSkip(bar0, "no clear " + EnumToString(TrendTF) + " trend"); return; }

   //--- Entry signal on entry timeframe (closed bar + live price)
   string why = "";
   if(!EntrySignal(trend, why)) { LogSkip(bar0, (trend == 1 ? "BUY " : "SELL ") + why); return; }

   if(OpenTrade(trend))
      lastEntryBar = bar0;
   else
      lastFailTime = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Higher-timeframe trend filter (EMA fast vs slow, closed bars)    |
//+------------------------------------------------------------------+
int GetTrend()
{
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   // start at shift 1 = last CLOSED bar (v1.00 used the forming bar, which repaints)
   if(CopyBuffer(hTrendFast, 0, 1, 3, f) < 3) return 0;
   if(CopyBuffer(hTrendSlow, 0, 1, 3, s) < 3) return 0;
   double c1 = iClose(TradeSymbol, TrendTF, 1);
   if(c1 <= 0) return 0;

   bool up = (f[0] > s[0] && f[1] > s[1]);
   bool dn = (f[0] < s[0] && f[1] < s[1]);

   if(RequireTrendSlope)
   {
      if(up && !(f[0] > f[1])) up = false;
      if(dn && !(f[0] < f[1])) dn = false;
   }
   if(RequirePriceVsSlow)
   {
      if(up && !(c1 > s[0])) up = false;
      if(dn && !(c1 < s[0])) dn = false;
   }
   if(up) return 1;
   if(dn) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Entry signal: pullback to EMA + momentum close + filters         |
//+------------------------------------------------------------------+
bool EntrySignal(const int dir, string &why)
{
   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hEntryEMA, 0, 1, 1, ema) < 1) { why = "EMA not ready"; return false; }
   int need = MathMax(ATR_AvgBars, 1);
   if(CopyBuffer(hATR, 0, 1, need, atr) < need) { why = "ATR not ready"; return false; }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(TradeSymbol, TF, 1, 1, r) < 1) { why = "no bar data"; return false; }

   double e = ema[0];
   double a = atr[0];
   if(a <= 0) { why = "ATR zero"; return false; }
   double o = r[0].open, h = r[0].high, l = r[0].low, c = r[0].close;

   //--- oversized candle filter
   if(UseBigCandleFilter && (h - l) > MaxCandleATR * a)
   { why = StringFormat("big candle %.1fx ATR", (h - l) / a); return false; }

   //--- volatility (ATR vs its average)
   if(UseATRFilter)
   {
      double sum = 0;
      for(int i = 0; i < need; i++) sum += atr[i];
      double avg = sum / need;
      if(avg > 0)
      {
         double ratio = a / avg;
         if(ratio < MinATRRatio) { why = StringFormat("ATR too quiet (%.2fx avg)", ratio); return false; }
         if(ratio > MaxATRRatio) { why = StringFormat("ATR too wild (%.2fx avg)", ratio); return false; }
      }
   }

   //--- trend strength
   if(UseADXFilter)
   {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(hADX, 0, 1, 1, adx) < 1) { why = "ADX not ready"; return false; }
      if(adx[0] < MinADX) { why = StringFormat("ADX %.1f < %.1f", adx[0], MinADX); return false; }
   }

   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);

   if(dir == 1)
   {
      if(c <= e)                                   { why = "close not above EMA"; return false; }
      if(RequirePullback && l > e + Pullback_ATR * a) { why = "no pullback to EMA"; return false; }
      if(RequireMomentumClose && c <= o)           { why = "no bullish close"; return false; }
      if(ask <= e)                                 { why = "price back below EMA"; return false; }
      if(MaxEMADist_ATR > 0 && (ask - e) > MaxEMADist_ATR * a) { why = "chasing (too far above EMA)"; return false; }
      return true;
   }
   else
   {
      if(c >= e)                                   { why = "close not below EMA"; return false; }
      if(RequirePullback && h < e - Pullback_ATR * a) { why = "no pullback to EMA"; return false; }
      if(RequireMomentumClose && c >= o)           { why = "no bearish close"; return false; }
      if(bid >= e)                                 { why = "price back above EMA"; return false; }
      if(MaxEMADist_ATR > 0 && (e - bid) > MaxEMADist_ATR * a) { why = "chasing (too far below EMA)"; return false; }
      return true;
   }
}

//+------------------------------------------------------------------+
//| Open the trade with fixed-dollar risk                            |
//+------------------------------------------------------------------+
bool OpenTrade(const int dir)
{
   long tmode = SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_MODE);
   if(dir == 1  && tmode == SYMBOL_TRADE_MODE_SHORTONLY) return false;
   if(dir == -1 && tmode == SYMBOL_TRADE_MODE_LONGONLY)  return false;

   double atr = GetATR();
   if(atr <= 0) return false;

   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   double price  = (dir == 1) ? ask : bid;
   double spread = ask - bid;

   double slDist = atr * ATR_Multiplier;

   //--- respect broker stop level (buy SL is checked against Bid, sell SL against Ask)
   double stopsLvl = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL) * PointValue;
   if(slDist - spread < stopsLvl + 2 * PointValue)
      slDist = stopsLvl + spread + 2 * PointValue;

   double sl = NormalizePrice((dir == 1) ? price - slDist : price + slDist);
   slDist = MathAbs(price - sl);
   if(slDist <= 0) return false;

   double riskAtLots = 0;
   double lots = CalculateLotSize(dir, price, sl, riskAtLots);
   if(lots <= 0) return false;

   double tp = 0;   // default: no fixed TP, trailing manages the exit
   if(UseFinalTP && FinalTP_RR > 0)
      tp = NormalizePrice((dir == 1) ? price + FinalTP_RR * slDist : price - FinalTP_RR * slDist);

   //--- margin check
   double margin = 0;
   ENUM_ORDER_TYPE otype = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(otype, TradeSymbol, lots, price, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("Skip: not enough free margin for ", DoubleToString(lots, 3), " lots (need ",
            DoubleToString(margin, 2), ")");
      return false;
   }

   bool sent = (dir == 1) ? trade.Buy(lots, TradeSymbol, price, sl, tp, "Gold Micro Buy")
                          : trade.Sell(lots, TradeSymbol, price, sl, tp, "Gold Micro Sell");
   if(!sent || !TradeOK())
   {
      Print((dir == 1 ? "BUY" : "SELL"), " failed | retcode ", trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription(), " | err ", GetLastError());
      return false;
   }
   Print((dir == 1 ? "BUY" : "SELL"), " opened | Lots: ", DoubleToString(lots, 3),
         " | Entry: ", DoubleToString(trade.ResultPrice(), DigitsValue),
         " | SL: ", DoubleToString(sl, DigitsValue),
         (tp > 0 ? " | TP: " + DoubleToString(tp, DigitsValue) : ""),
         " | Est. risk: $", DoubleToString(riskAtLots, 2));
   return true;
}

//+------------------------------------------------------------------+
//| Lot size for fixed dollar risk (respects min/max/step)           |
//+------------------------------------------------------------------+
double CalculateLotSize(const int dir, const double entry, const double sl, double &riskOut)
{
   riskOut = 0;
   double minLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0) return 0.0;

   //--- money lost per 1.0 lot if SL is hit (OrderCalcProfit handles currency conversion)
   double lossPerLot = 0, pnl = 0;
   ENUM_ORDER_TYPE otype = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(otype, TradeSymbol, 1.0, entry, sl, pnl))
      lossPerLot = MathAbs(pnl);
   if(lossPerLot <= 0)
   {
      double tickValue = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue <= 0) tickValue = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0) return 0.0;
      lossPerLot = (MathAbs(entry - sl) / tickSize) * tickValue;
   }
   if(lossPerLot <= 0) return 0.0;

   double lots = MathFloor(RiskAmount / lossPerLot / lotStep + 1e-9) * lotStep;

   if(lots < minLot)
   {
      //--- v1.00 silently forced min lot, which could risk far more than RiskAmount
      double riskAtMin = minLot * lossPerLot;
      if(riskAtMin > RiskAmount * MaxRiskOverrun)
      {
         Print("Skip: min lot ", DoubleToString(minLot, 3), " would risk $", DoubleToString(riskAtMin, 2),
               " (> $", DoubleToString(RiskAmount * MaxRiskOverrun, 2), " allowed). Raise RiskAmount/MaxRiskOverrun or use a smaller symbol.");
         return 0.0;
      }
      lots = minLot;
   }
   if(lots > maxLot) lots = maxLot;

   lots    = NormalizeVolume(lots);
   riskOut = lots * lossPerLot;
   return lots;
}

//+------------------------------------------------------------------+
//| Manage open positions: partial TP, breakeven, trailing           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   bool hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);           // also selects the position
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      bool   isBuy     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      double atr = GetATR();
      if(atr <= 0) continue;

      //--- initial risk (1R) stored once per position, so it stays correct after SL moves
      //    (v1.00 recalculated R from the current SL, so after breakeven R became ~5 points)
      string gvR = GVPrefix + IntegerToString((long)ticket) + "_R";
      double R = 0;
      if(GlobalVariableCheck(gvR)) R = GlobalVariableGet(gvR);
      if(R <= 0)
      {
         bool slIsInitial = (curSL > 0) && ((isBuy && curSL < openPrice) || (!isBuy && curSL > openPrice));
         R = slIsInitial ? MathAbs(openPrice - curSL) : atr * ATR_Multiplier;
         GlobalVariableSet(gvR, R);
      }
      if(R <= 0) continue;

      double price = isBuy ? SymbolInfoDouble(TradeSymbol, SYMBOL_BID) : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
      double rr    = isBuy ? (price - openPrice) / R : (openPrice - price) / R;

      //--- 1. Partial take profit
      string gvP = GVPrefix + IntegerToString((long)ticket) + "_P";
      if(UsePartialTP && !GlobalVariableCheck(gvP) && rr >= PartialTP_RR)
      {
         double closeVol = NormalizeVolume(volume * PartialClosePct / 100.0);
         double remain   = volume - closeVol;
         if(closeVol >= minLot - 1e-9 && remain >= minLot - 1e-9)
         {
            bool ok;
            if(hedging)
               ok = trade.PositionClosePartial(ticket, closeVol, SlippagePoints);
            else   // netting: an opposite deal reduces the position
               ok = isBuy ? trade.Sell(closeVol, TradeSymbol, 0, 0, 0, "Gold Micro partial")
                          : trade.Buy(closeVol, TradeSymbol, 0, 0, 0, "Gold Micro partial");
            if(ok && TradeOK())
            {
               GlobalVariableSet(gvP, 1);
               Print("PARTIAL TP | closed ", DoubleToString(closeVol, 3), " lots at ",
                     DoubleToString(rr, 2), "R | remaining ", DoubleToString(remain, 3));
            }
            else
               Print("Partial close failed | retcode ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
         else
         {
            GlobalVariableSet(gvP, -1);   // cannot split this lot size: skip partial, keep managing
            Print("Partial TP skipped: ", DoubleToString(volume, 3), " lots cannot be split (min lot ",
                  DoubleToString(minLot, 3), ")");
         }
         if(!PositionSelectByTicket(ticket)) continue;    // refresh after the close
         curSL  = PositionGetDouble(POSITION_SL);
         curTP  = PositionGetDouble(POSITION_TP);
         volume = PositionGetDouble(POSITION_VOLUME);
      }
      bool partialDone = GlobalVariableCheck(gvP) && GlobalVariableGet(gvP) > 0;

      //--- 2. Breakeven
      if((UseBreakeven && rr >= Breakeven_RR) || (BE_AfterPartial && partialDone))
      {
         double beSL = isBuy ? openPrice + BE_Buffer_Points * PointValue
                             : openPrice - BE_Buffer_Points * PointValue;
         beSL = NormalizePrice(beSL);
         if(Improves(isBuy, curSL, beSL, 0.5 * PointValue))
         {
            if(ModifySL(ticket, isBuy, curSL, beSL, curTP))
            {
               Print("Moved to BREAKEVEN | New SL: ", DoubleToString(beSL, DigitsValue));
               curSL = beSL;   // v1.00 kept the old value, so trailing could pull SL back below BE
            }
         }
      }

      //--- 3. ATR trailing stop (only once in profit beyond entry)
      if(UseTrailing && rr >= Trail_Start_RR)
      {
         double trailSL = NormalizePrice(isBuy ? price - atr * Trail_ATR_Mult : price + atr * Trail_ATR_Mult);
         bool beyondEntry = isBuy ? (trailSL > openPrice) : (trailSL < openPrice);
         if(beyondEntry && Improves(isBuy, curSL, trailSL, Trail_Step_Points * PointValue))
         {
            if(ModifySL(ticket, isBuy, curSL, trailSL, curTP))
            {
               Print("Trailing ", (isBuy ? "BUY" : "SELL"), " SL -> ", DoubleToString(trailSL, DigitsValue));
               curSL = trailSL;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify SL with stop-level / freeze-level checks, keep TP         |
//+------------------------------------------------------------------+
bool ModifySL(const ulong ticket, const bool isBuy, const double curSL, const double newSL, const double tp)
{
   double bid    = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double stops  = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL)  * PointValue;
   double freeze = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_FREEZE_LEVEL) * PointValue;

   if(isBuy)
   {
      if(bid - newSL <= stops) return false;                    // too close to price
      if(curSL > 0 && freeze > 0 && bid - curSL <= freeze) return false;
      if(tp > 0 && freeze > 0 && tp - bid <= freeze) return false;
   }
   else
   {
      if(newSL - ask <= stops) return false;
      if(curSL > 0 && freeze > 0 && curSL - ask <= freeze) return false;
      if(tp > 0 && freeze > 0 && ask - tp <= freeze) return false;
   }

   if(!trade.PositionModify(ticket, newSL, tp) || !TradeOK())   // keep existing TP (v1.00 wiped it)
   {
      Print("Modify SL failed | retcode ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return 0;   // last closed bar (no repaint)
   return atr[0];
}

int CountMyPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         n++;
   }
   return n;
}

bool Improves(const bool isBuy, const double curSL, const double newSL, const double minStep)
{
   if(curSL <= 0) return true;
   return isBuy ? (newSL > curSL + minStep) : (newSL < curSL - minStep);
}

double NormalizePrice(const double p)
{
   double ts = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) ts = PointValue;
   return NormalizeDouble(MathRound(p / ts) * ts, DigitsValue);
}

double NormalizeVolume(const double v)
{
   double step = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return 0;
   int vd = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(MathFloor(v / step + 1e-9) * step, vd);
}

int CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(PointValue <= 0 || ask <= 0 || bid <= 0) return (int)SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD);
   return (int)MathRound((ask - bid) / PointValue);
}

bool TradeOK()
{
   uint rc = trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
}

bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   long mode = SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   return true;
}

bool InHours(const int h, const int startH, const int endH)
{
   if(startH == endH) return true;                    // same start/end = whole day
   if(startH < endH)  return (h >= startH && h < endH);
   return (h >= startH || h < endH);                  // window crosses midnight
}

bool SessionOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);

   if(BlockFridayLate  && dt.day_of_week == 5 && dt.hour >= FridayStopHour)  return false;
   if(BlockMondayEarly && dt.day_of_week == 1 && dt.hour <  MondayStartHour) return false;

   if(!UseSessionFilter) return true;
   bool ok = false;
   if(TradeLondon  && InHours(dt.hour, LondonStartHour, LondonEndHour)) ok = true;
   if(TradeNewYork && InHours(dt.hour, NYStartHour, NYEndHour))         ok = true;
   return ok;
}

void LogSkip(const datetime bar, const string reason)
{
   static datetime lastPrint  = 0;
   static datetime lastBar    = 0;
   static string   lastReason = "";
   if(!VerboseLog) return;
   // max one line per bar; same reason repeated at most once an hour
   if(bar == lastBar) return;
   if(reason == lastReason && TimeCurrent() - lastPrint < 3600) return;
   lastBar    = bar;
   lastPrint  = TimeCurrent();
   lastReason = reason;
   Print("Skip [", TimeToString(bar, TIME_DATE | TIME_MINUTES), "]: ", reason);
}

//--- delete stored R / partial flags for positions that are closed
void CleanupGlobals()
{
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, GVPrefix) != 0) continue;
      string parts[];
      if(StringSplit(name, '_', parts) < 4) continue;
      ulong ticket = (ulong)StringToInteger(parts[2]);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket))
         GlobalVariableDel(name);
   }
}
//+------------------------------------------------------------------+
