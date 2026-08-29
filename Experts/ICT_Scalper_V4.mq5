//+------------------------------------------------------------------+
//| ICT Scalper V4 - XAUUSD M5/M15                                  |
//| Sweep (M5) -> MSS (next M5 candle) -> FVG/OB/Breaker -> Entry   |
//| DEMO/BACKTEST ONLY. No martingale/grid/averaging.               |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "XAUUSD M5 scalper: liquidity sweep, next-candle MSS, FVG/OB/Breaker."

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- Inputs ----------------------------------
input ENUM_TIMEFRAMES EntryTF       = PERIOD_M5;
input ENUM_TIMEFRAMES BiasTF        = PERIOD_M15;

input bool   EnableTrading          = true;
input double RiskPercent            = 0.25;
input double RewardRisk             = 1.5;
input int    MaxTradesPerDay        = 3;
input int    MaxSpreadPoints        = 80;

input int    LiquidityLookback      = 12;
input int    SwingLookback          = 5;
input int    StopBufferPoints       = 30;
input int    MinDisplacementPoints  = 40;
input int    BiasEMAPeriod          = 50;

input bool   RequireFVG             = false;
input bool   RequireOB              = false;
input bool   AllowBreaker           = true;

input bool   UseLondonSession        = true;
input bool   UseNewYorkSession       = true;
input int    LondonStartHour         = 8;
input int    LondonEndHour           = 12;
input int    NewYorkStartHour        = 13;
input int    NewYorkEndHour          = 17;

input ulong  MagicNumber             = 26082904;

//------------------------- Globals ---------------------------------
datetime g_lastBar = 0;
int      g_emaHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   g_emaHandle = iMA(_Symbol, BiasTF, BiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE)
      return INIT_FAILED;

   Print("V4 initialized. EntryTF=", EnumToString(EntryTF),
         " BiasTF=", EnumToString(BiasTF));

   // Make the active session filter explicit in the journal so a
   // 24/7 configuration is never mistaken for a broken filter.
   if(!UseLondonSession && !UseNewYorkSession)
      Print("Session filter: DISABLED (both sessions off) - trading allowed 24/7.");
   else
      Print("Session filter: London=", UseLondonSession,
            " (", LondonStartHour, "-", LondonEndHour, ")",
            "  NewYork=", UseNewYorkSession,
            " (", NewYorkStartHour, "-", NewYorkEndHour, ")",
            "  [server time, current server hour=", ServerHour(), "]");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;

   if(!EnableTrading)
   {
      Print("Blocked: EnableTrading=false");
      return;
   }

   if(!IsTradingSession())
   {
      Print("Blocked: outside trading session. Server hour=", ServerHour());
      return;
   }

   int spread = GetSpreadPoints();
   if(spread > MaxSpreadPoints)
   {
      Print("Blocked: spread=", spread, " > max=", MaxSpreadPoints);
      return;
   }

   if(CountOpenPositions() > 0)
      return;

   if(TradesToday() >= MaxTradesPerDay)
   {
      Print("Blocked: MaxTradesPerDay reached.");
      return;
   }

   MqlRates r[];
   ArraySetAsSeries(r, true);

   int need = MathMax(50, LiquidityLookback + SwingLookback + 10);
   if(CopyRates(_Symbol, EntryTF, 0, need, r) < need)
   {
      Print("Blocked: not enough price data.");
      return;
   }

   int bias = GetBias();
   if(bias == 0)
   {
      Print("No bias.");
      return;
   }

   // IMPORTANT: use two separate closed candles.
   // r[2] = sweep candle, r[1] = confirmation/MSS candle.
   bool sweptLow  = BullishLiquiditySweep(r);
   bool sweptHigh = BearishLiquiditySweep(r);

   if(bias > 0 && sweptLow)
   {
      bool mss = BullishMSS(r);
      bool fvg = BullishFVG(r);
      bool ob  = BullishOB(r);
      bool brk = AllowBreaker && BullishBreaker(r);

      Print("BUY setup: sweep=", sweptLow,
            " MSS=", mss, " FVG=", fvg,
            " OB=", ob, " Breaker=", brk);

      bool confirmations =
         ((!RequireFVG || fvg) &&
          (!RequireOB || ob) &&
          (fvg || ob || brk));

      if(mss && confirmations)
         OpenBuy(r);
   }

   if(bias < 0 && sweptHigh)
   {
      bool mss = BearishMSS(r);
      bool fvg = BearishFVG(r);
      bool ob  = BearishOB(r);
      bool brk = AllowBreaker && BearishBreaker(r);

      Print("SELL setup: sweep=", sweptHigh,
            " MSS=", mss, " FVG=", fvg,
            " OB=", ob, " Breaker=", brk);

      bool confirmations =
         ((!RequireFVG || fvg) &&
          (!RequireOB || ob) &&
          (fvg || ob || brk));

      if(mss && confirmations)
         OpenSell(r);
   }
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, EntryTF, 0);
   if(t == 0) return false;

   if(t != g_lastBar)
   {
      g_lastBar = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int GetBias()
{
   MqlRates b[];
   ArraySetAsSeries(b, true);

   if(CopyRates(_Symbol, BiasTF, 0, 3, b) < 3)
      return 0;

   double ema[];
   ArraySetAsSeries(ema, true);

   if(CopyBuffer(g_emaHandle, 0, 0, 3, ema) < 3)
      return 0;

   if(b[1].close > ema[1] && b[1].close > b[2].close)
      return 1;

   if(b[1].close < ema[1] && b[1].close < b[2].close)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
// Sweep is on r[2], not the same candle as MSS.
//+------------------------------------------------------------------+
bool BullishLiquiditySweep(MqlRates &r[])
{
   double priorLow = DBL_MAX;

   for(int i=3; i<=LiquidityLookback+2; i++)
      priorLow = MathMin(priorLow, r[i].low);

   return (r[2].low < priorLow &&
           r[2].close > priorLow);
}

//+------------------------------------------------------------------+
bool BearishLiquiditySweep(MqlRates &r[])
{
   double priorHigh = -DBL_MAX;

   for(int i=3; i<=LiquidityLookback+2; i++)
      priorHigh = MathMax(priorHigh, r[i].high);

   return (r[2].high > priorHigh &&
           r[2].close < priorHigh);
}

//+------------------------------------------------------------------+
// MSS happens on r[1], after the sweep candle r[2].
//+------------------------------------------------------------------+
bool BullishMSS(MqlRates &r[])
{
   double recentHigh = -DBL_MAX;

   for(int i=3; i<=SwingLookback+2; i++)
      recentHigh = MathMax(recentHigh, r[i].high);

   double bodyPoints = MathAbs(r[1].close-r[1].open)/_Point;

   return (r[1].close > recentHigh &&
           r[1].close > r[1].open &&
           bodyPoints >= MinDisplacementPoints);
}

//+------------------------------------------------------------------+
bool BearishMSS(MqlRates &r[])
{
   double recentLow = DBL_MAX;

   for(int i=3; i<=SwingLookback+2; i++)
      recentLow = MathMin(recentLow, r[i].low);

   double bodyPoints = MathAbs(r[1].close-r[1].open)/_Point;

   return (r[1].close < recentLow &&
           r[1].close < r[1].open &&
           bodyPoints >= MinDisplacementPoints);
}

//+------------------------------------------------------------------+
// FVG uses the confirmation candle r[1] and candle r[3].
//+------------------------------------------------------------------+
bool BullishFVG(MqlRates &r[])
{
   return (r[1].low > r[3].high);
}

//+------------------------------------------------------------------+
bool BearishFVG(MqlRates &r[])
{
   return (r[1].high < r[3].low);
}

//+------------------------------------------------------------------+
// Simple OB: sweep candle r[2] is opposite color, confirmation r[1]
// breaks its high/low.
//+------------------------------------------------------------------+
bool BullishOB(MqlRates &r[])
{
   return (r[2].close < r[2].open &&
           r[1].close > r[1].open &&
           r[1].close > r[2].high);
}

//+------------------------------------------------------------------+
bool BearishOB(MqlRates &r[])
{
   return (r[2].close > r[2].open &&
           r[1].close < r[1].open &&
           r[1].close < r[2].low);
}

//+------------------------------------------------------------------+
bool BullishBreaker(MqlRates &r[])
{
   return (r[2].close < r[2].open &&
           r[1].close > r[2].high);
}

//+------------------------------------------------------------------+
bool BearishBreaker(MqlRates &r[])
{
   return (r[2].close > r[2].open &&
           r[1].close < r[2].low);
}

//+------------------------------------------------------------------+
void OpenBuy(MqlRates &r[])
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;

   double sweepLow = r[2].low;
   double sl = sweepLow - StopBufferPoints*_Point;
   double riskDistance = ask - sl;

   if(riskDistance <= 0) return;

   double tp = ask + riskDistance*RewardRisk;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // FIX #2: verify SL/TP against the broker's minimum stop distance
   if(!StopsAreValid(true, ask, sl, tp)) return;

   double lots = CalculateLots(riskDistance);
   if(lots <= 0) return;

   if(!trade.Buy(lots, _Symbol, 0.0, sl, tp,
                 "V4 BUY Sweep+MSS+FVG/OB"))
      Print("BUY failed. Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   else
      Print("BUY opened. Lots=", lots, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
void OpenSell(MqlRates &r[])
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   double sweepHigh = r[2].high;
   double sl = sweepHigh + StopBufferPoints*_Point;
   double riskDistance = sl - bid;

   if(riskDistance <= 0) return;

   double tp = bid - riskDistance*RewardRisk;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // FIX #2: verify SL/TP against the broker's minimum stop distance
   if(!StopsAreValid(false, bid, sl, tp)) return;

   double lots = CalculateLots(riskDistance);
   if(lots <= 0) return;

   if(!trade.Sell(lots, _Symbol, 0.0, sl, tp,
                  "V4 SELL Sweep+MSS+FVG/OB"))
      Print("SELL failed. Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   else
      Print("SELL opened. Lots=", lots, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
// FIX #2: broker minimum stop-distance validation.
//
// SYMBOL_TRADE_STOPS_LEVEL is the minimum distance, in points, that the
// broker allows between the current price and a stop order. Sending SL/TP
// inside it makes the order fail with retcode 10016 (Invalid stops).
// Brokers that report 0 impose no such limit, and this check then passes
// unchanged, so nothing is altered on those servers.
//
// Returns true only when BOTH the SL and the TP clear the minimum.
//+------------------------------------------------------------------+
bool StopsAreValid(bool isBuy, double price, double sl, double tp)
{
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = (double)stopsLevel*_Point;

   double slDist = isBuy ? (price - sl) : (sl - price);
   double tpDist = isBuy ? (tp - price) : (price - tp);

   if(slDist < minDist)
   {
      Print("Skipped: SL violates broker minimum stop distance. SL is ",
            DoubleToString(slDist/_Point, 0), " pts from price, broker requires ",
            stopsLevel, " pts. Price=", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits));
      return false;
   }

   if(tpDist < minDist)
   {
      Print("Skipped: TP violates broker minimum stop distance. TP is ",
            DoubleToString(tpDist/_Point, 0), " pts from price, broker requires ",
            stopsLevel, " pts. Price=", DoubleToString(price, _Digits),
            " TP=", DoubleToString(tp, _Digits));
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
double CalculateLots(double stopDistance)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(balance <= 0 || riskMoney <= 0 || tickSize <= 0 || tickValue <= 0)
      return 0;

   double moneyPerLot = (stopDistance/tickSize) * tickValue;
   if(moneyPerLot <= 0) return 0;

   double lots = riskMoney/moneyPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0) step = minLot;

   lots = MathFloor(lots/step)*step;
   lots = MathMin(maxLot, lots);   // cap only - capping can never RAISE risk

   int volDigits = 2;
   if(step < 0.01)  volDigits = 3;
   if(step < 0.001) volDigits = 4;

   lots = NormalizeDouble(lots, volDigits);

   // FIX #1: never round UP to the broker minimum.
   // The old code did lots = MathMax(minLot, ...), so whenever the
   // risk-based size came out below minLot the EA still traded minLot and
   // silently risked more than RiskPercent. Skipping the trade is the only
   // way to keep the configured maximum risk honest.
   if(lots < minLot)
   {
      double minLotRiskPct = minLot*moneyPerLot/balance*100.0;
      Print("Skipped: risk-based lot ", DoubleToString(lots, volDigits),
            " is below broker minimum ", DoubleToString(minLot, volDigits),
            ". Trading minLot would risk ", DoubleToString(minLotRiskPct, 2),
            "% instead of the configured ", DoubleToString(RiskPercent, 2),
            "% (stop distance ", DoubleToString(stopDistance/_Point, 0),
            " pts). No trade.");
      return 0;
   }

   return lots;
}

//+------------------------------------------------------------------+
int GetSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0 || bid <= 0) return 999999;

   return (int)MathRound((ask-bid)/_Point);
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
int TradesToday()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   now.hour = 0;
   now.min  = 0;
   now.sec  = 0;

   datetime dayStart = StructToTime(now);
   datetime dayEnd   = dayStart + 86400;

   if(!HistorySelect(dayStart, dayEnd))
      return 0;

   int count = 0;

   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;

      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
// FIXED: when BOTH session switches are off the filter is disabled
// and trading is allowed around the clock.
//
// The previous version fell straight through to "return (london || ny)".
// With UseLondonSession=false and UseNewYorkSession=false the two
// short-circuit AND expressions below are false at EVERY hour, so the
// OR returned false forever and every bar was blocked. Turning both
// filters OFF made the EA trade LESS, not more - the opposite of what
// the switches imply.
//
// Behaviour preserved for every other combination:
//   London ON  only -> London hours only
//   New York ON only -> New York hours only
//   Both ON         -> either session
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   // No session filter configured -> trade 24/7.
   if(!UseLondonSession && !UseNewYorkSession)
      return true;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   int h = t.hour;

   bool london = UseLondonSession &&
                 HourInWindow(h, LondonStartHour, LondonEndHour);

   bool ny = UseNewYorkSession &&
             HourInWindow(h, NewYorkStartHour, NewYorkEndHour);

   return (london || ny);
}

//+------------------------------------------------------------------+
int ServerHour()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.hour;
}

//+------------------------------------------------------------------+
bool HourInWindow(int hour, int startHour, int endHour)
{
   if(startHour == endHour) return true;

   if(startHour < endHour)
      return (hour >= startHour && hour < endHour);

   return (hour >= startHour || hour < endHour);
}
//+------------------------------------------------------------------+
