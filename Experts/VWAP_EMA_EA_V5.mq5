//+------------------------------------------------------------------+
//| VWAP_EMA_EA_V5.mq5                                               |
//| VWAP + dual EMA pullback/reclaim Expert Advisor for MT5          |
//| Educational/backtesting build. Test on demo before any use.      |
//|                                                                  |
//| V5 = V4 plus FOUR controlled changes, each behind its own input. |
//| Setting RunAsV4 = true forces every one of them off, so this     |
//| single binary runs both arms of an A/B test on identical data.   |
//|                                                                  |
//|   CHANGE 1  MinVWAPBars        - refuse to trade until the       |
//|                                  session VWAP has enough samples |
//|   CHANGE 2  UseSessionFilter   - skip the rollover / dead hours  |
//|   CHANGE 3  MaxSpreadPctOfStop - refuse trades whose cost drag   |
//|                                  is fatal relative to the stop   |
//|   CHANGE 4  UseStructureStop   - stop beyond the signal candle   |
//|                                  instead of a fixed ATR distance |
//|                                                                  |
//| Risk management is UNCHANGED from V4: same RiskPercent, same     |
//| RewardRisk, same CalculateLots(), same StopsAreValid().          |
//+------------------------------------------------------------------+
#property version   "5.00"
#property description "VWAP + dual EMA pullback/reclaim EA - V5 controlled-change build"

#include <Trade/Trade.mqh>
CTrade trade;

//============================== Inputs ==============================//
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;

input group "=== A/B control ==="
input bool RunAsV4 = false;               // true = disable every V5 change (V4 baseline)

// Trend
input group "=== Trend (unchanged from V4) ==="
input int FastEMAPeriod = 20;
input int SlowEMAPeriod = 50;
input ENUM_APPLIED_PRICE EMAPrice = PRICE_CLOSE;

// VWAP
input group "=== VWAP ==="
input bool UseDailyVWAP = true;
input double VWAPPullbackATR = 0.35;      // NOTE: inert while RequireVWAPReclaim = true
input bool RequireVWAPReclaim = true;
input int  MinVWAPBars = 12;              // V5 CHANGE 1 (V4 = 0)

// Entry confirmation
input group "=== Entry confirmation (unchanged from V4) ==="
input bool RequireCandleConfirmation = true;
input double MinBodyATR = 0.05;

// Risk / exits
input group "=== Risk / exits (RiskPercent + RewardRisk unchanged) ==="
input double RiskPercent = 0.25;
input double RewardRisk = 1.50;
input int ATRPeriod = 14;
input double ATRMultiplier = 1.50;
input bool   UseStructureStop = true;     // V5 CHANGE 4 (V4 = false)
input double StructureStopBufferATR = 0.15; // buffer beyond the signal candle

// Execution
input group "=== Execution ==="
input int MaxSpreadPoints = 80;
input double MaxSpreadPctOfStop = 12.0;   // V5 CHANGE 3 (V4 = 0 = disabled)
input int MaxTradesPerDay = 3;
input bool OnePositionOnly = true;
input ulong MagicNumber = 26082905;

input group "=== Session filter (server time) ==="
input bool UseSessionFilter = true;       // V5 CHANGE 2 (V4 = false)
input int  SessionStartHour = 7;
input int  SessionEndHour   = 20;

// Diagnostics
input group "=== Diagnostics ==="
input bool VerboseLogs = false;           // per-bar lines; summary always prints

//============================== Globals =============================//
int fastEmaHandle = INVALID_HANDLE;
int slowEmaHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;

datetime lastBarTime = 0;
int tradesToday = 0;
int lastDayKey = -1;

//--- resolved settings (RunAsV4 collapses these to the V4 values)
int    cfgMinVWAPBars   = 0;
bool   cfgSessionFilter = false;
double cfgSpreadPctCap  = 0.0;
bool   cfgStructureStop = false;

//--- FUNNEL COUNTERS (diagnostics only - never read by a decision)
long cBars=0, cDailyLimit=0, cHasPos=0, cSpread=0, cSession=0, cData=0, cIndic=0;
long cVwapImmature=0;
long cTrendNone=0, cTrendBull=0, cTrendBear=0;
long cPullbackFail=0, cReclaimFail=0, cConfirmFail=0;
long cLongSignal=0, cShortSignal=0;
long cRejSpreadPct=0, cRejStops=0, cRejSize=0, cRejSend=0, cOpened=0;
long cSignalByHour[24];

//============================== Logging =============================//
void Log(string message)
{
   if(VerboseLogs)
      Print("[VWAP_EMA_V5] ", message);
}

//============================== Date / daily counter =================//
int GetDayKey(datetime when)
{
   MqlDateTime t;
   TimeToStruct(when, t);
   return t.year * 10000 + t.mon * 100 + t.day;
}

void ResetDailyCounter()
{
   int key = GetDayKey(TimeCurrent());

   if(key != lastDayKey)
   {
      lastDayKey = key;
      tradesToday = 0;
      Log("New trading day. Counter reset.");
   }
}

//============================== Symbol ==============================//
bool IsSupportedSymbol()
{
   string s = _Symbol;
   StringToUpper(s);

   if(StringFind(s,"XAU") >= 0)    return true;
   if(StringFind(s,"GOLD") >= 0)   return true;
   if(StringFind(s,"BTC") >= 0)    return true;
   if(StringFind(s,"NAS") >= 0)    return true;
   if(StringFind(s,"USTEC") >= 0)  return true;

   return false;
}

//============================== Bars ================================//
bool IsNewBar()
{
   datetime t = iTime(_Symbol,EntryTF,0);
   if(t == 0)
      return false;

   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }

   return false;
}

//============================== Session =============================//
// V5 CHANGE 2. Server time, wrap-around supported. start == end = 24h.
bool InSession()
{
   if(!cfgSessionFilter)
      return true;
   if(SessionStartHour == SessionEndHour)
      return true;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   if(SessionStartHour < SessionEndHour)
      return (t.hour >= SessionStartHour && t.hour < SessionEndHour);

   return (t.hour >= SessionStartHour || t.hour < SessionEndHour);
}

//============================== Indicators ==========================//
double GetBufferValue(int handle,int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer,true);

   if(CopyBuffer(handle,0,shift,1,buffer) != 1)
      return EMPTY_VALUE;

   return buffer[0];
}

double GetFastEMA(int shift) { return GetBufferValue(fastEmaHandle,shift); }
double GetSlowEMA(int shift) { return GetBufferValue(slowEmaHandle,shift); }
double GetATR(int shift)     { return GetBufferValue(atrHandle,shift);     }

// Daily VWAP from typical price * tick volume, same-server-day only.
// V5: also reports how many bars went into it, because a VWAP built from
// one or two bars is not a meaningful level (see MinVWAPBars).
double GetDailyVWAP(int shift,int &barsUsed)
{
   barsUsed = 0;

   datetime barTime = iTime(_Symbol,EntryTF,shift);
   if(barTime == 0)
      return EMPTY_VALUE;

   MqlDateTime d;
   TimeToStruct(barTime,d);
   d.hour = 0;
   d.min  = 0;
   d.sec  = 0;

   datetime dayStart = StructToTime(d);

   MqlRates rates[];
   int copied = CopyRates(_Symbol,EntryTF,dayStart,barTime,rates);

   if(copied <= 0)
      return EMPTY_VALUE;

   double pv = 0.0;
   double volume = 0.0;

   for(int i=0; i<copied; i++)
   {
      double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double v = (double)rates[i].tick_volume;

      pv += typical * v;
      volume += v;
   }

   if(volume <= 0.0)
      return EMPTY_VALUE;

   barsUsed = copied;
   return pv / volume;
}

//============================== Filters =============================//
double CurrentSpreadPrice()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return -1.0;
   return (tick.ask - tick.bid);
}

bool SpreadOK()
{
   double sp = CurrentSpreadPrice();
   if(sp < 0.0)
   {
      Log("REJECT spread: no current tick");
      return false;
   }

   double spreadPts = sp / _Point;

   if(MaxSpreadPoints > 0 && spreadPts > MaxSpreadPoints)
   {
      Log("REJECT spread: " + DoubleToString(spreadPts,1) +
          " pts > max " + IntegerToString(MaxSpreadPoints));
      return false;
   }

   return true;
}

bool HasOurPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }

   return false;
}

// UNCHANGED from V4.
bool StopsAreValid(bool isBuy,double price,double sl,double tp)
{
   long stopsLevel  = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);

   double minDistance = (double)MathMax(stopsLevel,freezeLevel) * _Point;

   double slDistance = isBuy ? price-sl : sl-price;
   double tpDistance = isBuy ? tp-price : price-tp;

   if(slDistance <= 0.0 || tpDistance <= 0.0)
   {
      Log("REJECT stops: invalid direction");
      return false;
   }

   if(minDistance > 0.0 &&
      (slDistance < minDistance || tpDistance < minDistance))
   {
      Log("REJECT stops: broker minimum distance " +
          DoubleToString(minDistance/_Point,1) + " pts");
      return false;
   }

   return true;
}

//============================== Volume ===============================//
// UNCHANGED from V4.
int VolumeDigits(double step)
{
   if(step >= 1.0)   return 0;
   if(step >= 0.1)   return 1;
   if(step >= 0.01)  return 2;
   if(step >= 0.001) return 3;
   return 4;
}

double CalculateLots(double entry,double stop)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return 0.0;

   double riskMoney = balance * RiskPercent / 100.0;
   double distance = MathAbs(entry-stop);

   if(distance <= 0.0)
      return 0.0;

   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);

   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(tickSize <= 0.0 || tickValue <= 0.0 ||
      minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
   {
      Log("REJECT size: invalid broker symbol specification");
      return 0.0;
   }

   double moneyPerLot = (distance/tickSize) * tickValue;
   if(moneyPerLot <= 0.0)
      return 0.0;

   double rawLots = riskMoney / moneyPerLot;

   double lots = MathFloor(rawLots/step + 1e-9) * step;
   lots = MathMin(maxLot,lots);
   lots = NormalizeDouble(lots,VolumeDigits(step));

   if(lots < minLot)
   {
      double minLotRiskPct = (minLot*moneyPerLot/balance) * 100.0;

      Log("SKIP size: calculated " + DoubleToString(rawLots,4) +
          " lots < broker minimum " + DoubleToString(minLot,VolumeDigits(step)) +
          ". Minimum lot would risk about " +
          DoubleToString(minLotRiskPct,2) + "%.");
      return 0.0;
   }

   return lots;
}

//============================== Trading =============================//
// stopDistance is supplied by the caller so V5 CHANGE 4 can substitute a
// structure-based distance for the fixed ATR one. Everything downstream -
// sizing, R:R, stop validation - is identical to V4.
bool OpenTrade(bool isBuy,double stopDistance)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   double entry = isBuy ? tick.ask : tick.bid;

   if(stopDistance <= 0.0)
      return false;

   // V5 CHANGE 3: refuse trades where the spread is a large fraction of the
   // stop. At RewardRisk 1.5 a zero-edge entry needs 40% wins to break even;
   // every 1% of spread-to-stop costs roughly 0.4 points of win rate, so a
   // 25%-of-stop spread is unrecoverable no matter how good the signal is.
   if(cfgSpreadPctCap > 0.0)
   {
      double sp = CurrentSpreadPrice();
      if(sp >= 0.0)
      {
         double pct = sp / stopDistance * 100.0;
         if(pct > cfgSpreadPctCap)
         {
            cRejSpreadPct++;
            Log("REJECT spread/stop: spread is " + DoubleToString(pct,1) +
                "% of the stop distance, cap " +
                DoubleToString(cfgSpreadPctCap,1) + "%");
            return false;
         }
      }
   }

   double sl = isBuy ? entry-stopDistance : entry+stopDistance;
   double tp = isBuy ? entry+stopDistance*RewardRisk
                     : entry-stopDistance*RewardRisk;

   sl = NormalizeDouble(sl,_Digits);
   tp = NormalizeDouble(tp,_Digits);

   if(!StopsAreValid(isBuy,entry,sl,tp))
   {
      cRejStops++;
      return false;
   }

   double lots = CalculateLots(entry,sl);
   if(lots <= 0.0)
   {
      cRejSize++;
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   bool sent = false;

   if(isBuy)
      sent = trade.Buy(lots,_Symbol,0.0,sl,tp,"VWAP EMA V5 BUY");
   else
      sent = trade.Sell(lots,_Symbol,0.0,sl,tp,"VWAP EMA V5 SELL");

   if(!sent)
   {
      cRejSend++;
      Print("[VWAP_EMA_V5] ORDER FAILED | retcode=" +
            IntegerToString((int)trade.ResultRetcode()) +
            " | " + trade.ResultRetcodeDescription());
      return false;
   }

   tradesToday++;
   cOpened++;

   Log((isBuy ? "BUY" : "SELL") +
       " OPENED | lots=" + DoubleToString(lots,4) +
       " entry=" + DoubleToString(entry,_Digits) +
       " SL=" + DoubleToString(sl,_Digits) +
       " TP=" + DoubleToString(tp,_Digits) +
       " stopDist=" + DoubleToString(stopDistance,_Digits));

   return true;
}

//============================== Init ================================//
int OnInit()
{
   if(!IsSupportedSymbol())
      Print("[VWAP_EMA_V5] WARNING: " + _Symbol +
            " is not recognized as Gold/NAS100/BTC. EA will still run.");

   // Resolve the A/B configuration once.
   if(RunAsV4)
   {
      cfgMinVWAPBars   = 0;
      cfgSessionFilter = false;
      cfgSpreadPctCap  = 0.0;
      cfgStructureStop = false;
   }
   else
   {
      cfgMinVWAPBars   = (MinVWAPBars < 0 ? 0 : MinVWAPBars);
      cfgSessionFilter = UseSessionFilter;
      cfgSpreadPctCap  = (MaxSpreadPctOfStop < 0.0 ? 0.0 : MaxSpreadPctOfStop);
      cfgStructureStop = UseStructureStop;
   }

   ArrayInitialize(cSignalByHour,0);

   fastEmaHandle = iMA(_Symbol,EntryTF,FastEMAPeriod,0,MODE_EMA,EMAPrice);
   slowEmaHandle = iMA(_Symbol,EntryTF,SlowEMAPeriod,0,MODE_EMA,EMAPrice);
   atrHandle = iATR(_Symbol,EntryTF,ATRPeriod);

   if(fastEmaHandle == INVALID_HANDLE || slowEmaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handles.");
      return INIT_FAILED;
   }

   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);

   Print("VWAP+EMA V5 initialized | Symbol=",_Symbol,
         " | TF=",EnumToString(EntryTF),
         " | FastEMA=",FastEMAPeriod,
         " | SlowEMA=",SlowEMAPeriod,
         " | Risk=",DoubleToString(RiskPercent,2),"%",
         " | RR=",DoubleToString(RewardRisk,2));

   Print("[VWAP_EMA_V5] MODE = ", (RunAsV4 ? "V4 BASELINE (all V5 changes OFF)" : "V5"),
         " | MinVWAPBars=", cfgMinVWAPBars,
         " | SessionFilter=", cfgSessionFilter,
         " (", SessionStartHour, "-", SessionEndHour, " server)",
         " | MaxSpreadPctOfStop=", DoubleToString(cfgSpreadPctCap,1), "%",
         " | StructureStop=", cfgStructureStop);

   if(RequireVWAPReclaim)
      Print("[VWAP_EMA_V5] NOTE: RequireVWAPReclaim=true makes VWAPPullbackATR ",
            "inert - the reclaim test (low<=VWAP<close) already implies the ",
            "pullback test.");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastEmaHandle != INVALID_HANDLE) IndicatorRelease(fastEmaHandle);
   if(slowEmaHandle != INVALID_HANDLE) IndicatorRelease(slowEmaHandle);
   if(atrHandle != INVALID_HANDLE)     IndicatorRelease(atrHandle);

   PrintFunnel();
}

//============================== Funnel report ========================//
void PrintFunnel()
{
   Print("========== VWAP+EMA FUNNEL SUMMARY (",
         (RunAsV4 ? "V4 BASELINE" : "V5"), ") ==========");
   Print("New bars evaluated             : ", cBars);
   Print("  rejected daily trade limit   : ", cDailyLimit);
   Print("  rejected position open       : ", cHasPos);
   Print("  rejected outside session     : ", cSession);
   Print("  rejected spread (abs)        : ", cSpread);
   Print("  rejected insufficient bars   : ", cData);
   Print("  rejected indicator NA        : ", cIndic);
   Print("  rejected VWAP immature       : ", cVwapImmature);
   Print("---- trend classification ----");
   Print("  bullish trend                : ", cTrendBull);
   Print("  bearish trend                : ", cTrendBear);
   Print("  no trend                     : ", cTrendNone);
   Print("---- of trending bars, first failing filter ----");
   Print("  pullback failed              : ", cPullbackFail);
   Print("  reclaim failed               : ", cReclaimFail);
   Print("  candle confirmation failed   : ", cConfirmFail);
   Print("---- signals ----");
   Print("  LONG signals                 : ", cLongSignal);
   Print("  SHORT signals                : ", cShortSignal);
   Print("  rejected spread%/stop        : ", cRejSpreadPct);
   Print("  rejected stop validation     : ", cRejStops);
   Print("  rejected position sizing     : ", cRejSize);
   Print("  order send failures          : ", cRejSend);
   Print("  POSITIONS OPENED             : ", cOpened);
   Print("---- signals by server hour ----");
   string line = "";
   for(int h=0; h<24; h++)
      if(cSignalByHour[h] > 0)
         line += StringFormat("%02d:%d  ", h, (int)cSignalByHour[h]);
   Print("  ", (line=="" ? "none" : line));
   Print("=====================================================");
}

//============================== Main =================================//
void OnTick()
{
   ResetDailyCounter();

   if(!IsNewBar())
      return;

   cBars++;

   if(MaxTradesPerDay > 0 && tradesToday >= MaxTradesPerDay)
   {
      cDailyLimit++;
      Log("REJECT daily limit");
      return;
   }

   if(OnePositionOnly && HasOurPosition())
   {
      cHasPos++;
      Log("REJECT existing position");
      return;
   }

   // V5 CHANGE 2
   if(!InSession())
   {
      cSession++;
      Log("REJECT outside session");
      return;
   }

   if(!SpreadOK())
   {
      cSpread++;
      return;
   }

   MqlRates r[];
   ArraySetAsSeries(r,true);

   if(CopyRates(_Symbol,EntryTF,0,4,r) < 4)
   {
      cData++;
      Log("REJECT data: insufficient bars");
      return;
   }

   // r[1] = last fully closed candle, r[2] = the one before it
   double fastEma1 = GetFastEMA(1);
   double fastEma2 = GetFastEMA(2);
   double slowEma1 = GetSlowEMA(1);
   double atr1     = GetATR(1);

   int vwapBars = 0;
   double vwap1 = GetDailyVWAP(1,vwapBars);

   if(fastEma1 == EMPTY_VALUE || fastEma2 == EMPTY_VALUE ||
      slowEma1 == EMPTY_VALUE || atr1 == EMPTY_VALUE ||
      vwap1 == EMPTY_VALUE || atr1 <= 0.0)
   {
      cIndic++;
      Log("REJECT data: EMA/ATR/VWAP unavailable");
      return;
   }

   // V5 CHANGE 1: a VWAP built from one or two bars is not a level.
   // With one bar, "low <= VWAP" is ALWAYS true and "close > VWAP" reduces
   // to "closed above its own midpoint" - the reclaim filter does nothing.
   if(cfgMinVWAPBars > 0 && vwapBars < cfgMinVWAPBars)
   {
      cVwapImmature++;
      Log("REJECT VWAP immature: " + IntegerToString(vwapBars) +
          " bars < " + IntegerToString(cfgMinVWAPBars));
      return;
   }

   //==================== Trend (unchanged) ====================//
   bool bullishTrend =
      r[1].close > fastEma1 &&
      fastEma1 > slowEma1 &&
      fastEma1 > fastEma2 &&
      r[1].close > vwap1;

   bool bearishTrend =
      r[1].close < fastEma1 &&
      fastEma1 < slowEma1 &&
      fastEma1 < fastEma2 &&
      r[1].close < vwap1;

   if(bullishTrend)      cTrendBull++;
   else if(bearishTrend) cTrendBear++;
   else                  cTrendNone++;

   //==================== Pullback (unchanged) =================//
   double pullbackDistance = atr1 * VWAPPullbackATR;

   bool bullishPullback =
      r[1].low <= vwap1 + pullbackDistance &&
      r[1].close > vwap1;

   bool bearishPullback =
      r[1].high >= vwap1 - pullbackDistance &&
      r[1].close < vwap1;

   bool bullishReclaim = r[1].low  <= vwap1 && r[1].close > vwap1;
   bool bearishReclaim = r[1].high >= vwap1 && r[1].close < vwap1;

   //==================== Confirmation (unchanged) =============//
   double body = MathAbs(r[1].close-r[1].open);
   bool bullishCandle = r[1].close > r[1].open;
   bool bearishCandle = r[1].close < r[1].open;

   bool bullishConfirmation =
      !RequireCandleConfirmation ||
      (bullishCandle && body >= atr1*MinBodyATR);

   bool bearishConfirmation =
      !RequireCandleConfirmation ||
      (bearishCandle && body >= atr1*MinBodyATR);

   //---- funnel attribution: which filter kills a trending bar first ----
   if(bullishTrend || bearishTrend)
   {
      bool pb  = bullishTrend ? bullishPullback     : bearishPullback;
      bool rc  = bullishTrend ? bullishReclaim      : bearishReclaim;
      bool cf  = bullishTrend ? bullishConfirmation : bearishConfirmation;

      if(!pb)                                    cPullbackFail++;
      else if(RequireVWAPReclaim && !rc)         cReclaimFail++;
      else if(!cf)                               cConfirmFail++;
   }

   //==================== Final signals (unchanged) =============//
   bool longSignal =
      bullishTrend &&
      bullishPullback &&
      (!RequireVWAPReclaim || bullishReclaim) &&
      bullishConfirmation;

   bool shortSignal =
      bearishTrend &&
      bearishPullback &&
      (!RequireVWAPReclaim || bearishReclaim) &&
      bearishConfirmation;

   if(!longSignal && !shortSignal)
   {
      Log("NO SIGNAL | trend=" +
          (bullishTrend ? "BULL" : bearishTrend ? "BEAR" : "NONE") +
          " | vwapBars=" + IntegerToString(vwapBars));
      return;
   }

   // V5 CHANGE 4: stop beyond the signal candle rather than a flat 1.5*ATR.
   // The ATR distance is kept as a CAP so the stop can never be wider than
   // V4's, and a floor of 0.25*ATR stops a doji producing an absurd stop.
   double atrStop = atr1 * ATRMultiplier;
   double stopDistance = atrStop;

   if(cfgStructureStop)
   {
      double buf = atr1 * StructureStopBufferATR;
      MqlTick tk;
      double ref = 0.0;
      if(SymbolInfoTick(_Symbol,tk))
         ref = longSignal ? tk.ask : tk.bid;
      else
         ref = r[1].close;

      double structDist = longSignal ? (ref - (r[1].low - buf))
                                     : ((r[1].high + buf) - ref);

      double floorDist = atr1 * 0.25;
      if(structDist < floorDist) structDist = floorDist;
      if(structDist > atrStop)   structDist = atrStop;

      stopDistance = structDist;
   }

   MqlDateTime st;
   TimeToStruct(TimeCurrent(),st);
   if(st.hour >= 0 && st.hour < 24)
      cSignalByHour[st.hour]++;

   if(longSignal)
   {
      cLongSignal++;
      Log("LONG SIGNAL | close=" + DoubleToString(r[1].close,_Digits) +
          " VWAP=" + DoubleToString(vwap1,_Digits) +
          " (" + IntegerToString(vwapBars) + " bars)" +
          " ATR=" + DoubleToString(atr1,_Digits));
      OpenTrade(true,stopDistance);
      return;
   }

   cShortSignal++;
   Log("SHORT SIGNAL | close=" + DoubleToString(r[1].close,_Digits) +
       " VWAP=" + DoubleToString(vwap1,_Digits) +
       " (" + IntegerToString(vwapBars) + " bars)" +
       " ATR=" + DoubleToString(atr1,_Digits));
   OpenTrade(false,stopDistance);
}
//+------------------------------------------------------------------+
