//+------------------------------------------------------------------+
//|                                      XAUUSD_Micro_Gold_EA.mq5    |
//|                        Fixed $ Risk + Breakeven + Trailing       |
//|                        Designed for Deriv XAUUSDmicro            |
//+------------------------------------------------------------------+
#property copyright "Dave-4u / Gold Micro EA"
#property link      "https://github.com/Dave-4u/XAUUSD-Micro-Gold-EA-Deriv-v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- INPUTS
input group "=== Risk Management ==="
input double   RiskAmount          = 1.50;    // Dollars to risk per trade ($1 - $2)
input int      MagicNumber         = 20261119;// Magic Number

input group "=== Symbol ==="
input string   SymbolOverride      = "XAUUSDmicro"; // Leave as XAUUSDmicro or change to XAUUSD later

input group "=== Stop & Trailing ==="
input int      ATR_Period          = 14;      // ATR Period
input double   ATR_Multiplier      = 1.8;     // Initial Stop = ATR * this
input double   Breakeven_RR        = 1.0;     // Move to Breakeven at this R multiple
input double   Trail_ATR_Mult      = 1.5;     // Trailing Stop = ATR * this
input int      Trail_Start_RR      = 1;       // Start trailing after this R (usually same as BE)

input group "=== Strategy Filters ==="
input int      EMA_Fast            = 21;      // Fast EMA (H4 bias)
input int      EMA_Slow            = 50;      // Slow EMA (H4 bias)
input int      Max_Spread_Points   = 50;      // Max allowed spread (points)

//--- Global
string         TradeSymbol;
double         PointValue;
int            DigitsValue;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   TradeSymbol = (SymbolOverride == "") ? _Symbol : SymbolOverride;
   
   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("ERROR: Symbol ", TradeSymbol, " not found. Check market watch.");
      return(INIT_FAILED);
   }
   
   PointValue  = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   DigitsValue = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   Print("XAUUSD Micro Gold EA initialized on ", TradeSymbol, " | Risk: $", RiskAmount);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Manage existing position first (BE + Trailing)
   ManageOpenPosition();
   
   //--- Only one position at a time
   if(PositionSelectByMagic(TradeSymbol, MagicNumber))
      return;
   
   //--- Check spread
   double spread = SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD) * PointValue;
   if(spread > Max_Spread_Points * PointValue)
      return;
   
   //--- Get trend bias from H4
   int trend = GetH4Trend();
   if(trend == 0) return;   // No clear trend
   
   //--- Look for entry
   if(trend == 1)
      CheckBuyEntry();
   else if(trend == -1)
      CheckSellEntry();
}

//+------------------------------------------------------------------+
//| H4 Trend Filter (EMA Fast vs Slow)                               |
//+------------------------------------------------------------------+
int GetH4Trend()
{
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   
   int h4 = iEMA(TradeSymbol, PERIOD_H4, EMA_Fast, PRICE_CLOSE);
   int h4s = iEMA(TradeSymbol, PERIOD_H4, EMA_Slow, PRICE_CLOSE);
   
   if(CopyBuffer(h4, 0, 0, 3, emaFast) < 3) return 0;
   if(CopyBuffer(h4s, 0, 0, 3, emaSlow) < 3) return 0;
   
   if(emaFast[0] > emaSlow[0] && emaFast[1] > emaSlow[1])
      return 1;   // Bullish
   if(emaFast[0] < emaSlow[0] && emaFast[1] < emaSlow[1])
      return -1;  // Bearish
   
   return 0;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on fixed dollar risk                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopDistancePrice)
{
   if(stopDistancePrice <= 0) return 0.0;
   
   double tickValue = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   
   if(tickValue == 0 || tickSize == 0) return 0.0;
   
   // Money risked per 1.0 lot for this stop distance
   double moneyPerLot = (stopDistancePrice / tickSize) * tickValue;
   
   if(moneyPerLot <= 0) return 0.0;
   
   double lots = RiskAmount / moneyPerLot;
   
   // Normalize to lot step
   lots = MathFloor(lots / lotStep) * lotStep;
   
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Buy Entry Logic                                                  |
//+------------------------------------------------------------------+
void CheckBuyEntry()
{
   // Simple pullback + momentum filter on current timeframe
   double atr = GetATR();
   if(atr <= 0) return;
   
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double stopLoss = ask - (atr * ATR_Multiplier);
   double stopDistance = ask - stopLoss;
   
   double lots = CalculateLotSize(stopDistance);
   if(lots <= 0) return;
   
   // Basic confirmation: price above fast EMA on current TF
   double ema[];
   ArraySetAsSeries(ema, true);
   int handle = iEMA(TradeSymbol, PERIOD_CURRENT, 21, PRICE_CLOSE);
   if(CopyBuffer(handle, 0, 0, 2, ema) < 2) return;
   
   if(ask > ema[0])
   {
      double takeProfit = 0; // We manage with trailing, no fixed TP
      
      if(trade.Buy(lots, TradeSymbol, ask, stopLoss, takeProfit, "Gold Micro Buy"))
      {
         Print("BUY opened | Lots: ", lots, " | SL: ", stopLoss, " | Risk: $", RiskAmount);
      }
   }
}

//+------------------------------------------------------------------+
//| Sell Entry Logic                                                 |
//+------------------------------------------------------------------+
void CheckSellEntry()
{
   double atr = GetATR();
   if(atr <= 0) return;
   
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double stopLoss = bid + (atr * ATR_Multiplier);
   double stopDistance = stopLoss - bid;
   
   double lots = CalculateLotSize(stopDistance);
   if(lots <= 0) return;
   
   double ema[];
   ArraySetAsSeries(ema, true);
   int handle = iEMA(TradeSymbol, PERIOD_CURRENT, 21, PRICE_CLOSE);
   if(CopyBuffer(handle, 0, 0, 2, ema) < 2) return;
   
   if(bid < ema[0])
   {
      double takeProfit = 0;
      
      if(trade.Sell(lots, TradeSymbol, bid, stopLoss, takeProfit, "Gold Micro Sell"))
      {
         Print("SELL opened | Lots: ", lots, " | SL: ", stopLoss, " | Risk: $", RiskAmount);
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Open Position - Breakeven + Trailing                      |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!PositionSelectByMagic(TradeSymbol, MagicNumber))
      return;
   
   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   long   type       = PositionGetInteger(POSITION_TYPE);
   double profit     = PositionGetDouble(POSITION_PROFIT);
   
   double atr = GetATR();
   if(atr <= 0) return;
   
   double currentPrice = (type == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(TradeSymbol, SYMBOL_BID) : 
                         SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   
   // Calculate R (risk distance)
   double riskDistance = MathAbs(openPrice - currentSL);
   if(riskDistance <= 0) riskDistance = atr * ATR_Multiplier; // fallback
   
   double currentRR = 0;
   if(type == POSITION_TYPE_BUY)
      currentRR = (currentPrice - openPrice) / riskDistance;
   else
      currentRR = (openPrice - currentPrice) / riskDistance;
   
   //--- 1. Move to Breakeven
   if(currentRR >= Breakeven_RR)
   {
      double newSL = openPrice;
      
      // Small buffer to cover spread
      if(type == POSITION_TYPE_BUY)
         newSL = openPrice + (5 * PointValue);
      else
         newSL = openPrice - (5 * PointValue);
      
      // Only move if better than current SL
      bool improve = false;
      if(type == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0))
         improve = true;
      if(type == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))
         improve = true;
      
      if(improve)
      {
         if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, 0))
            Print("Moved to BREAKEVEN | New SL: ", newSL);
      }
   }
   
   //--- 2. Trailing Stop (after BE level)
   if(currentRR >= Trail_Start_RR)
   {
      double trailDistance = atr * Trail_ATR_Mult;
      double newTrailSL;
      
      if(type == POSITION_TYPE_BUY)
      {
         newTrailSL = currentPrice - trailDistance;
         if(newTrailSL > currentSL && newTrailSL > openPrice)
         {
            if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), newTrailSL, 0))
               Print("Trailing BUY SL → ", newTrailSL);
         }
      }
      else // SELL
      {
         newTrailSL = currentPrice + trailDistance;
         if((newTrailSL < currentSL || currentSL == 0) && newTrailSL < openPrice)
         {
            if(trade.PositionModify(PositionGetInteger(POSITION_TICKET), newTrailSL, 0))
               Print("Trailing SELL SL → ", newTrailSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Get current ATR                                          |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   int handle = iATR(TradeSymbol, PERIOD_CURRENT, ATR_Period);
   if(CopyBuffer(handle, 0, 0, 2, atr) < 2) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Helper: Check if we already have a position with our magic       |
//+------------------------------------------------------------------+
bool PositionSelectByMagic(string sym, int magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == sym && PositionGetInteger(POSITION_MAGIC) == magic)
      {
         return PositionSelectByTicket(PositionGetInteger(POSITION_TICKET));
      }
   }
   return false;
}
//+------------------------------------------------------------------+
