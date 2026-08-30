//+------------------------------------------------------------------+
//| VWAP_EMA_EA_V6.mq5   (build 6.01 - corrected)                    |
//| VWAP + EMA Pullback EA - educational/testing build               |
//|                                                                  |
//| FIXES APPLIED TO THE ORIGINAL 6.00 (details in the header of     |
//| each site, and in docs/VWAP_EMA_V6_fixes.md):                    |
//|                                                                  |
//|  F1 CRITICAL  ArraySetAsSeries() was called on STATIC arrays.    |
//|               The AS_SERIES flag cannot be set on a fixed-size    |
//|               array. Depending on the build this is either a     |
//|               compile error or a silent no-op that leaves the    |
//|               array in chronological order - in which case r[2]  |
//|               became the FORMING bar and the reclaim test        |
//|               repainted. All such arrays are now dynamic.        |
//|  F2 CRITICAL  NormalizeVolume() clamped the size UP to the       |
//|               broker minimum, silently breaking RiskPercent.     |
//|  F3 HIGH      Market orders were sent with an explicit stale     |
//|               price; now sent at market (price 0.0).             |
//|  F4 HIGH      The reclaim lookback rebuilt the whole day's VWAP  |
//|               up to 5x per bar. Now built once per bar and       |
//|               cached (O(n) instead of O(n^2) per day).           |
//|  F5 MED       SYMBOL_TRADE_TICK_VALUE_LOSS with fallback.        |
//|  F6 MED       Freeze level included in the stop-distance check.  |
//|  F7 MED       MaxTradesPerDay <= 0 no longer blocks all trading. |
//|  F8 LOW       #property strict removed (MQL4 leftover).          |
//|                                                                  |
//| Strategy semantics are otherwise UNCHANGED. Two optional filters |
//| are added, both default OFF so behaviour is preserved.           |
//+------------------------------------------------------------------+
#property version   "6.01"
#property description "VWAP + EMA Pullback EA V6.01 - corrected educational/testing build"

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================
// Inputs
//==================================================
input group "=== General ==="
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;
input long   MagicNumber = 26082906;
input bool   OnePositionOnly = true;
input int    MaxTradesPerDay = 3;
input bool   AllowLongs = true;
input bool   AllowShorts = true;

input group "=== EMA Trend ==="
input int    FastEMAPeriod = 20;
input int    SlowEMAPeriod = 50;
input ENUM_APPLIED_PRICE EMAPrice = PRICE_CLOSE;
input bool   RequireEMASlope = false;        // NEW, default OFF: fast EMA must be rising/falling
input bool   RequireCloseVsFastEMA = false;  // NEW, default OFF: close must be beyond the fast EMA

input group "=== VWAP ==="
input bool   UseDailyVWAP = true;
input int    MinVWAPBars = 12;
input bool   RequireVWAPReclaim = true;
input int    ReclaimLookbackBars = 3;
input double MinBodyATR = 0.05;

input group "=== Risk / Exits ==="
input double RiskPercent = 0.25;
input double RewardRisk = 1.50;
input int    ATRPeriod = 14;
input double ATRMultiplier = 1.50;
input bool   UseStructureStop = true;
input int    StructureLookback = 5;
input double StructureBufferATR = 0.15;
input double MaxStructureATR = 2.00;
input bool   StructureWidenOnly = true;      // NEW: true = V6 behaviour (stop can only widen)

input group "=== Execution Filters ==="
input int    MaxSpreadPoints = 80;
input double MaxSpreadPctOfStop = 12.0;
input int    SlippagePoints = 20;

input group "=== Session Filter (server time) ==="
input bool   UseSessionFilter = true;
input int    SessionStartHour = 7;
input int    SessionEndHour = 20;

input group "=== Diagnostics ==="
input bool   PrintDiagnostics = false;       // per-bar lines (was true; summary always prints)

//==================================================
// Indicator handles / state
//==================================================
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;

datetime lastBarTime = 0;
int tradesToday = 0;
int dayKey = -1;

//--- F4: daily VWAP cache, rebuilt once per closed bar
datetime g_vwapTimes[];
double   g_vwapValues[];
int      g_vwapBarsAt[];
int      g_vwapN = 0;

//--- diagnostics (never read by a trading decision)
long cBars=0, cDaily=0, cSession=0, cHasPos=0, cData=0, cIndic=0, cVwap=0;
long cTrendFlat=0, cNoSignal=0;
long cLong=0, cShort=0, cPrepFail=0, cSendFail=0, cOpened=0;
long cRejSpread=0, cRejSpreadPct=0, cRejStops=0, cRejSize=0;
long cSignalHour[24];

//==================================================
// Helpers
//==================================================
bool IsNewBar()
{
   datetime t = iTime(_Symbol, EntryTF, 0);
   if(t == 0) return false;
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

int CurrentDayKey()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

void ResetDailyCounterIfNeeded()
{
   int k = CurrentDayKey();
   if(k != dayKey)
   {
      dayKey = k;
      tradesToday = 0;
   }
}

bool InTradingSession()
{
   if(!UseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   if(SessionStartHour == SessionEndHour)
      return true;

   if(SessionStartHour < SessionEndHour)
      return (h >= SessionStartHour && h < SessionEndHour);

   return (h >= SessionStartHour || h < SessionEndHour);
}

bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//--- F2: never round the size UP to the broker minimum.
// Returns 0.0 when the risk-correct size is below the minimum, so the
// caller skips the trade instead of silently exceeding RiskPercent.
double NormalizeVolume(double volume)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0 || vmin <= 0.0 || vmax <= 0.0) return 0.0;

   if(volume > vmax) volume = vmax;                 // capping can only reduce risk
   volume = MathFloor(volume / vstep + 1e-9) * vstep;

   int digits = 0;
   double step = vstep;
   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }

   volume = NormalizeDouble(volume, digits);

   if(volume < vmin)
      return 0.0;

   return volume;
}

double CalculateLots(double entryPrice, double stopPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return 0.0;

   double riskMoney = balance * RiskPercent / 100.0;
   if(riskMoney <= 0.0) return 0.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   //--- F5: the loss-side tick value is the correct one for stop sizing
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double distance = MathAbs(entryPrice - stopPrice);
   if(distance <= 0.0) return 0.0;

   double lossPerLot = (distance / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double lots = NormalizeVolume(riskMoney / lossPerLot);

   if(lots <= 0.0 && PrintDiagnostics)
   {
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      Print("SKIP size | risk-correct lots below broker minimum ",
            DoubleToString(vmin, 2), "; minimum lot would risk ",
            DoubleToString(vmin * lossPerLot / balance * 100.0, 2),
            "% vs configured ", DoubleToString(RiskPercent, 2), "%");
   }

   return lots;
}

//--- F6: honour the freeze level as well as the stops level
bool StopsAreValid(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
{
   long stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long required    = (stopsLevel > freezeLevel ? stopsLevel : freezeLevel);

   double minDist = (double)required * _Point;

   if(type == ORDER_TYPE_BUY)
      return (sl < entry - minDist && tp > entry + minDist);

   return (sl > entry + minDist && tp < entry - minDist);
}

bool SpreadOK(double stopDistance)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   double spread = ask - bid;
   int spreadPoints = (int)MathRound(spread / _Point);

   if(MaxSpreadPoints > 0 && spreadPoints > MaxSpreadPoints)
   {
      cRejSpread++;
      return false;
   }

   if(MaxSpreadPctOfStop > 0.0 && stopDistance > 0.0)
   {
      double pct = (spread / stopDistance) * 100.0;
      if(pct > MaxSpreadPctOfStop)
      {
         cRejSpreadPct++;
         return false;
      }
   }

   return true;
}

//==================================================
// F4: daily VWAP, built ONCE per closed bar
//
// Cumulative typical-price * tick-volume from the first bar of the
// server day up to the last CLOSED bar. Bar 0 is never included, so the
// values cannot repaint. g_vwapValues[i] is the VWAP as it stood at the
// close of g_vwapTimes[i], which is exactly what a lookback needs.
//==================================================
bool BuildVWAPCache()
{
   g_vwapN = 0;

   datetime lastClosed = iTime(_Symbol, EntryTF, 1);
   if(lastClosed == 0) return false;

   MqlDateTime dt;
   TimeToStruct(lastClosed, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);            // chronological
   int copied = CopyRates(_Symbol, EntryTF, dayStart, lastClosed, rates);
   if(copied <= 0) return false;

   if(ArrayResize(g_vwapTimes,  copied) != copied) return false;
   if(ArrayResize(g_vwapValues, copied) != copied) return false;
   if(ArrayResize(g_vwapBarsAt, copied) != copied) return false;

   double pv = 0.0;
   double vv = 0.0;

   for(int i = 0; i < copied; i++)
   {
      double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double volume  = (double)rates[i].tick_volume;
      if(volume <= 0.0) volume = 1.0;

      pv += typical * volume;
      vv += volume;

      g_vwapTimes[i]  = rates[i].time;
      g_vwapValues[i] = (vv > 0.0 ? pv / vv : 0.0);
      g_vwapBarsAt[i] = i + 1;
   }

   g_vwapN = copied;
   return true;
}

// Look up the cached VWAP as it stood at the close of the given shift.
// Returns false when the sample is too small to be a meaningful level.
bool VWAPForShift(int shift, double &vwap, int &barsCount)
{
   vwap = 0.0;
   barsCount = 0;

   if(g_vwapN <= 0) return false;

   datetime t = iTime(_Symbol, EntryTF, shift);
   if(t == 0) return false;

   for(int i = g_vwapN - 1; i >= 0; i--)
   {
      if(g_vwapTimes[i] == t)
      {
         vwap = g_vwapValues[i];
         barsCount = g_vwapBarsAt[i];
         return (barsCount >= MinVWAPBars && vwap > 0.0);
      }
   }
   return false;
}

//==================================================
// Indicators
//==================================================
bool GetIndicators(double &fast1, double &fast2,
                   double &slow1, double &atr1)
{
   //--- F1: dynamic arrays, so AS_SERIES actually applies
   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr,  true);

   if(CopyBuffer(hFastEMA, 0, 0, 3, fast) < 3) return false;
   if(CopyBuffer(hSlowEMA, 0, 0, 3, slow) < 3) return false;
   if(CopyBuffer(hATR,     0, 0, 3, atr)  < 3) return false;

   fast1 = fast[1];
   fast2 = fast[2];
   slow1 = slow[1];
   atr1  = atr[1];

   return (atr1 > 0.0);
}

bool CandleBullishConfirmation(const MqlRates &r, double atr)
{
   if(r.close <= r.open) return false;
   if((r.close - r.open) < atr * MinBodyATR) return false;
   return true;
}

bool CandleBearishConfirmation(const MqlRates &r, double atr)
{
   if(r.close >= r.open) return false;
   if((r.open - r.close) < atr * MinBodyATR) return false;
   return true;
}

//==================================================
// Signals - semantics unchanged, but the lookback now reads the cache
// instead of rebuilding the day's VWAP on every iteration.
//==================================================
bool LongSignal(const MqlRates &r1, const MqlRates &r2,
                double vwap1, double vwap2,
                double fast1, double fast2, double slow1, double atr)
{
   if(fast1 <= slow1) return false;
   if(RequireEMASlope && fast1 <= fast2) return false;
   if(RequireCloseVsFastEMA && r1.close <= fast1) return false;

   if(!CandleBullishConfirmation(r1, atr))
      return false;

   if(RequireVWAPReclaim)
   {
      // The closed candle reclaims VWAP after the previous closed candle
      // was at or below it.
      if(r1.close > vwap1 && r2.close <= vwap2)
         return true;

      // Short lookback: one of the recent CLOSED candles traded down to
      // its own VWAP while the latest closed candle sits back above.
      if(r1.close > vwap1)
      {
         for(int s = 2; s <= ReclaimLookbackBars + 1; s++)
         {
            double vw; int bc;
            if(!VWAPForShift(s, vw, bc)) continue;

            MqlRates rr[];
            ArraySetAsSeries(rr, true);
            if(CopyRates(_Symbol, EntryTF, s, 1, rr) != 1) continue;

            if(rr[0].low <= vw)
               return true;
         }
      }

      return false;
   }

   return (r1.close > vwap1);
}

bool ShortSignal(const MqlRates &r1, const MqlRates &r2,
                 double vwap1, double vwap2,
                 double fast1, double fast2, double slow1, double atr)
{
   if(fast1 >= slow1) return false;
   if(RequireEMASlope && fast1 >= fast2) return false;
   if(RequireCloseVsFastEMA && r1.close >= fast1) return false;

   if(!CandleBearishConfirmation(r1, atr))
      return false;

   if(RequireVWAPReclaim)
   {
      if(r1.close < vwap1 && r2.close >= vwap2)
         return true;

      if(r1.close < vwap1)
      {
         for(int s = 2; s <= ReclaimLookbackBars + 1; s++)
         {
            double vw; int bc;
            if(!VWAPForShift(s, vw, bc)) continue;

            MqlRates rr[];
            ArraySetAsSeries(rr, true);
            if(CopyRates(_Symbol, EntryTF, s, 1, rr) != 1) continue;

            if(rr[0].high >= vw)
               return true;
         }
      }

      return false;
   }

   return (r1.close < vwap1);
}

//==================================================
// Structure levels (already used dynamic arrays - unchanged)
//==================================================
double RecentLowestLow(int bars)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, EntryTF, 1, bars, r);
   if(copied <= 0) return 0.0;

   double low = r[0].low;
   for(int i = 1; i < copied; i++)
      if(r[i].low < low) low = r[i].low;

   return low;
}

double RecentHighestHigh(int bars)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, EntryTF, 1, bars, r);
   if(copied <= 0) return 0.0;

   double high = r[0].high;
   for(int i = 1; i < copied; i++)
      if(r[i].high > high) high = r[i].high;

   return high;
}

//==================================================
// Order preparation
//==================================================
bool PrepareTrade(ENUM_ORDER_TYPE type, double atr,
                  double &entry, double &sl, double &tp, double &lots)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   entry = (type == ORDER_TYPE_BUY) ? ask : bid;

   double atrStop = atr * ATRMultiplier;
   if(atrStop <= 0.0) return false;

   double stopDistance = atrStop;

   if(UseStructureStop)
   {
      double structureDistance = 0.0;

      if(type == ORDER_TYPE_BUY)
      {
         double swingLow = RecentLowestLow(StructureLookback);
         if(swingLow > 0.0)
            structureDistance = entry - (swingLow - atr * StructureBufferATR);
      }
      else
      {
         double swingHigh = RecentHighestHigh(StructureLookback);
         if(swingHigh > 0.0)
            structureDistance = (swingHigh + atr * StructureBufferATR) - entry;
      }

      if(structureDistance > 0.0)
      {
         double maxStructureDistance = atr * MaxStructureATR;
         if(structureDistance > maxStructureDistance)
            structureDistance = maxStructureDistance;

         // StructureWidenOnly = true reproduces V6: the structure stop can
         // only ever make the stop WIDER than the ATR stop, never tighter.
         if(StructureWidenOnly)
         {
            if(structureDistance > stopDistance)
               stopDistance = structureDistance;
         }
         else
         {
            double floorDist = atr * 0.25;
            if(structureDistance < floorDist) structureDistance = floorDist;
            stopDistance = structureDistance;
         }
      }
   }

   if(!SpreadOK(stopDistance))
      return false;

   if(type == ORDER_TYPE_BUY)
   {
      sl = entry - stopDistance;
      tp = entry + stopDistance * RewardRisk;
   }
   else
   {
      sl = entry + stopDistance;
      tp = entry - stopDistance * RewardRisk;
   }

   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);
   entry = NormalizeDouble(entry, _Digits);

   if(!StopsAreValid(type, entry, sl, tp))
   {
      cRejStops++;
      return false;
   }

   lots = CalculateLots(entry, sl);
   if(lots <= 0.0)
   {
      cRejSize++;
      return false;
   }

   return true;
}

//==================================================
// Expert lifecycle
//==================================================
int OnInit()
{
   if(FastEMAPeriod <= 0 || SlowEMAPeriod <= 0 ||
      FastEMAPeriod >= SlowEMAPeriod ||
      ATRPeriod <= 0 || RiskPercent <= 0.0 ||
      RewardRisk <= 0.0)
   {
      Print("Invalid inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFastEMA = iMA(_Symbol, EntryTF, FastEMAPeriod, 0, MODE_EMA, EMAPrice);
   hSlowEMA = iMA(_Symbol, EntryTF, SlowEMAPeriod, 0, MODE_EMA, EMAPrice);
   hATR     = iATR(_Symbol, EntryTF, ATRPeriod);

   if(hFastEMA == INVALID_HANDLE ||
      hSlowEMA == INVALID_HANDLE ||
      hATR == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   dayKey = CurrentDayKey();
   ArrayInitialize(cSignalHour, 0);

   Print("VWAP_EMA_V6.01 initialized on ", _Symbol,
         " | TF=", EnumToString(EntryTF),
         " | Risk=", DoubleToString(RiskPercent, 2), "%",
         " | RR=", DoubleToString(RewardRisk, 2),
         " | MinVWAPBars=", MinVWAPBars,
         " | StructureWidenOnly=", StructureWidenOnly);

   if(MaxTradesPerDay <= 0)
      Print("NOTE: MaxTradesPerDay <= 0 is treated as UNLIMITED.");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);

   PrintSummary();
}

void PrintSummary()
{
   Print("============ VWAP_EMA_V6.01 FUNNEL SUMMARY ============");
   Print("Closed bars evaluated        : ", cBars);
   Print("  daily trade limit          : ", cDaily);
   Print("  outside session            : ", cSession);
   Print("  existing position          : ", cHasPos);
   Print("  price data unavailable     : ", cData);
   Print("  indicators unavailable     : ", cIndic);
   Print("  VWAP immature/unavailable  : ", cVwap);
   Print("  EMAs flat (fast == slow)   : ", cTrendFlat);
   Print("  no signal                  : ", cNoSignal);
   Print("---- signals ----");
   Print("  LONG signals               : ", cLong);
   Print("  SHORT signals              : ", cShort);
   Print("  rejected: spread (abs)     : ", cRejSpread);
   Print("  rejected: spread% of stop  : ", cRejSpreadPct);
   Print("  rejected: stop distance    : ", cRejStops);
   Print("  rejected: position size    : ", cRejSize);
   Print("  order send failures        : ", cSendFail);
   Print("  POSITIONS OPENED           : ", cOpened);
   string line = "";
   for(int h = 0; h < 24; h++)
      if(cSignalHour[h] > 0)
         line += StringFormat("%02d:%d  ", h, (int)cSignalHour[h]);
   Print("  signals by server hour     : ", (line == "" ? "none" : line));
   Print("======================================================");
}

//==================================================
// Main
//==================================================
void OnTick()
{
   ResetDailyCounterIfNeeded();

   if(!IsNewBar())
      return;

   cBars++;

   //--- F7: 0 or negative means unlimited, not "block everything"
   if(MaxTradesPerDay > 0 && tradesToday >= MaxTradesPerDay)
   {
      cDaily++;
      if(PrintDiagnostics) Print("NO TRADE | daily trade limit reached");
      return;
   }

   if(!InTradingSession())
   {
      cSession++;
      if(PrintDiagnostics) Print("NO TRADE | outside session");
      return;
   }

   if(OnePositionOnly && HasOurPosition())
   {
      cHasPos++;
      if(PrintDiagnostics) Print("NO TRADE | existing EA position");
      return;
   }

   //--- F1: dynamic array so the AS_SERIES flag is honoured and r[2] is
   //--- genuinely the bar before last, not the still-forming bar.
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, EntryTF, 0, 3, r) < 3)
   {
      cData++;
      return;
   }

   double fast1, fast2, slow1, atr1;
   if(!GetIndicators(fast1, fast2, slow1, atr1))
   {
      cIndic++;
      return;
   }

   double vwap1 = 0.0, vwap2 = 0.0;

   if(UseDailyVWAP)
   {
      int bars1 = 0, bars2 = 0;

      if(!BuildVWAPCache() ||
         !VWAPForShift(1, vwap1, bars1) ||
         !VWAPForShift(2, vwap2, bars2))
      {
         cVwap++;
         if(PrintDiagnostics) Print("NO TRADE | insufficient VWAP history");
         return;
      }
   }

   if(fast1 == slow1)
      cTrendFlat++;

   bool longSignal  = false;
   bool shortSignal = false;

   if(UseDailyVWAP)
   {
      if(AllowLongs)
         longSignal = LongSignal(r[1], r[2], vwap1, vwap2,
                                 fast1, fast2, slow1, atr1);

      if(AllowShorts)
         shortSignal = ShortSignal(r[1], r[2], vwap1, vwap2,
                                   fast1, fast2, slow1, atr1);
   }

   if(PrintDiagnostics)
      Print("V6 | trend=", (fast1 > slow1 ? "BULL" : fast1 < slow1 ? "BEAR" : "FLAT"),
            " | close1=", DoubleToString(r[1].close, _Digits),
            " | VWAP=", DoubleToString(vwap1, _Digits),
            " | ATR=", DoubleToString(atr1, _Digits),
            " | long=", longSignal,
            " | short=", shortSignal);

   if(!longSignal && !shortSignal)
   {
      cNoSignal++;
      return;
   }

   MqlDateTime sh;
   TimeToStruct(TimeCurrent(), sh);
   if(sh.hour >= 0 && sh.hour < 24)
      cSignalHour[sh.hour]++;

   if(longSignal && !shortSignal)
   {
      cLong++;
      double entry, sl, tp, lots;
      if(PrepareTrade(ORDER_TYPE_BUY, atr1, entry, sl, tp, lots))
      {
         //--- F3: market order. Passing a captured price to a market
         //--- request risks an "invalid price" rejection on some servers.
         if(trade.Buy(lots, _Symbol, 0.0, sl, tp, "V6 VWAP EMA LONG"))
         {
            tradesToday++;
            cOpened++;
            Print("BUY OPENED | lots=", DoubleToString(lots, 2),
                  " ref=", DoubleToString(entry, _Digits),
                  " fill=", DoubleToString(trade.ResultPrice(), _Digits),
                  " SL=", DoubleToString(sl, _Digits),
                  " TP=", DoubleToString(tp, _Digits));
         }
         else
         {
            cSendFail++;
            Print("BUY FAILED | retcode=", trade.ResultRetcode(),
                  " ", trade.ResultRetcodeDescription());
         }
      }
      else
      {
         cPrepFail++;
         if(PrintDiagnostics)
            Print("LONG SIGNAL REJECTED | execution/risk filter");
      }
      return;
   }

   if(shortSignal && !longSignal)
   {
      cShort++;
      double entry, sl, tp, lots;
      if(PrepareTrade(ORDER_TYPE_SELL, atr1, entry, sl, tp, lots))
      {
         if(trade.Sell(lots, _Symbol, 0.0, sl, tp, "V6 VWAP EMA SHORT"))
         {
            tradesToday++;
            cOpened++;
            Print("SELL OPENED | lots=", DoubleToString(lots, 2),
                  " ref=", DoubleToString(entry, _Digits),
                  " fill=", DoubleToString(trade.ResultPrice(), _Digits),
                  " SL=", DoubleToString(sl, _Digits),
                  " TP=", DoubleToString(tp, _Digits));
         }
         else
         {
            cSendFail++;
            Print("SELL FAILED | retcode=", trade.ResultRetcode(),
                  " ", trade.ResultRetcodeDescription());
         }
      }
      else
      {
         cPrepFail++;
         if(PrintDiagnostics)
            Print("SHORT SIGNAL REJECTED | execution/risk filter");
      }
   }
}
//+------------------------------------------------------------------+
