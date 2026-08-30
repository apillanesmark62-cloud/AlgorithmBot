//+------------------------------------------------------------------+
//| VWAP_EMA_EA_V4.mq5                                               |
//| VWAP + EMA pullback/reclaim Expert Advisor for MT5               |
//| Educational/backtesting build. Test on demo before any use.      |
//| Kept verbatim as the A/B baseline for V5. Do not edit.           |
//+------------------------------------------------------------------+
#property version   "4.00"
#property description "VWAP + dual EMA pullback/reclaim Expert Advisor"

#include <Trade/Trade.mqh>
CTrade trade;

//============================== Inputs ==============================//
input ENUM_TIMEFRAMES EntryTF = PERIOD_M5;

// Trend
input int FastEMAPeriod = 20;
input int SlowEMAPeriod = 50;
input ENUM_APPLIED_PRICE EMAPrice = PRICE_CLOSE;

// VWAP
input bool UseDailyVWAP = true;
input double VWAPPullbackATR = 0.35;     // How close price must get to VWAP
input bool RequireVWAPReclaim = true;

// Entry confirmation
input bool RequireCandleConfirmation = true;
input double MinBodyATR = 0.05;           // Avoid tiny/doji confirmations

// Risk / exits
input double RiskPercent = 0.25;
input double RewardRisk = 1.50;
input int ATRPeriod = 14;
input double ATRMultiplier = 1.50;

// Execution
input int MaxSpreadPoints = 80;
input int MaxTradesPerDay = 3;
input bool OnePositionOnly = true;
input ulong MagicNumber = 26082905;

// Diagnostics
input bool VerboseLogs = true;

//============================== Globals =============================//
int fastEmaHandle = INVALID_HANDLE;
int slowEmaHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;

datetime lastBarTime = 0;
int tradesToday = 0;
int lastDayKey = -1;

//============================== Logging =============================//
void Log(string message)
{
   if(VerboseLogs)
      Print("[VWAP_EMA_V4] ", message);
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

   if(StringFind(s,"XAU") >= 0)    return true; // Gold
   if(StringFind(s,"GOLD") >= 0)   return true;
   if(StringFind(s,"BTC") >= 0)    return true; // Bitcoin
   if(StringFind(s,"NAS") >= 0)    return true; // NAS100 variants
   if(StringFind(s,"USTEC") >= 0)  return true; // US100/USTEC

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

//============================== Indicators ==========================//
double GetBufferValue(int handle,int shift)
{
   double buffer[];
   ArraySetAsSeries(buffer,true);

   if(CopyBuffer(handle,0,shift,1,buffer) != 1)
      return EMPTY_VALUE;

   return buffer[0];
}

double GetFastEMA(int shift)
{
   return GetBufferValue(fastEmaHandle,shift);
}

double GetSlowEMA(int shift)
{
   return GetBufferValue(slowEmaHandle,shift);
}

double GetATR(int shift)
{
   return GetBufferValue(atrHandle,shift);
}

// Daily VWAP using typical price * tick volume.
// Only data from the same broker/server day as the requested closed bar
// is included.
double GetDailyVWAP(int shift)
{
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

   return pv / volume;
}

//============================== Filters =============================//
bool SpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
   {
      Log("REJECT spread: no current tick");
      return false;
   }

   double spreadPts = (tick.ask - tick.bid) / _Point;

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

   // Floor to the broker volume step. Never round upward.
   double lots = MathFloor(rawLots/step + 1e-9) * step;
   lots = MathMin(maxLot,lots);
   lots = NormalizeDouble(lots,VolumeDigits(step));

   // If broker minimum would exceed the configured risk, skip.
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
bool OpenTrade(bool isBuy,double atr)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   double entry = isBuy ? tick.ask : tick.bid;
   double stopDistance = atr * ATRMultiplier;

   if(stopDistance <= 0.0)
      return false;

   double sl = isBuy ? entry-stopDistance : entry+stopDistance;
   double tp = isBuy ? entry+stopDistance*RewardRisk
                     : entry-stopDistance*RewardRisk;

   sl = NormalizeDouble(sl,_Digits);
   tp = NormalizeDouble(tp,_Digits);

   if(!StopsAreValid(isBuy,entry,sl,tp))
      return false;

   double lots = CalculateLots(entry,sl);
   if(lots <= 0.0)
      return false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   bool sent = false;

   if(isBuy)
      sent = trade.Buy(lots,_Symbol,0.0,sl,tp,"VWAP EMA V4 BUY");
   else
      sent = trade.Sell(lots,_Symbol,0.0,sl,tp,"VWAP EMA V4 SELL");

   if(!sent)
   {
      Log("ORDER FAILED | retcode=" +
          IntegerToString((int)trade.ResultRetcode()) +
          " | " + trade.ResultRetcodeDescription());
      return false;
   }

   tradesToday++;

   Log((isBuy ? "BUY" : "SELL") +
       " OPENED | lots=" + DoubleToString(lots,4) +
       " entry=" + DoubleToString(entry,_Digits) +
       " SL=" + DoubleToString(sl,_Digits) +
       " TP=" + DoubleToString(tp,_Digits));

   return true;
}

//============================== Init ================================//
int OnInit()
{
   if(!IsSupportedSymbol())
      Log("WARNING: " + _Symbol +
          " is not recognized as Gold/NAS100/BTC. EA will still run.");

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

   Print("VWAP+EMA V4 initialized | Symbol=",_Symbol,
         " | TF=",EnumToString(EntryTF),
         " | FastEMA=",FastEMAPeriod,
         " | SlowEMA=",SlowEMAPeriod,
         " | Risk=",DoubleToString(RiskPercent,2),"%",
         " | RR=",DoubleToString(RewardRisk,2));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastEmaHandle != INVALID_HANDLE)
      IndicatorRelease(fastEmaHandle);
   if(slowEmaHandle != INVALID_HANDLE)
      IndicatorRelease(slowEmaHandle);

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//============================== Main =================================//
void OnTick()
{
   ResetDailyCounter();

   // Evaluate once when a new candle begins, using the previous closed candle.
   if(!IsNewBar())
      return;

   if(MaxTradesPerDay > 0 && tradesToday >= MaxTradesPerDay)
   {
      Log("REJECT daily limit");
      return;
   }

   if(OnePositionOnly && HasOurPosition())
   {
      Log("REJECT existing position");
      return;
   }

   if(!SpreadOK())
      return;

   MqlRates r[];
   ArraySetAsSeries(r,true);

   if(CopyRates(_Symbol,EntryTF,0,4,r) < 4)
   {
      Log("REJECT data: insufficient bars");
      return;
   }

   // r[1] = last fully closed candle
   // r[2] = candle immediately before it
   double fastEma1 = GetFastEMA(1);
   double fastEma2 = GetFastEMA(2);
   double slowEma1 = GetSlowEMA(1);
   double slowEma2 = GetSlowEMA(2);
   double atr1  = GetATR(1);
   double atr2  = GetATR(2);
   double vwap1 = GetDailyVWAP(1);
   double vwap2 = GetDailyVWAP(2);

   if(fastEma1 == EMPTY_VALUE || fastEma2 == EMPTY_VALUE ||
      slowEma1 == EMPTY_VALUE || slowEma2 == EMPTY_VALUE ||
      atr1 == EMPTY_VALUE || atr2 == EMPTY_VALUE ||
      vwap1 == EMPTY_VALUE || vwap2 == EMPTY_VALUE)
   {
      Log("REJECT data: EMA/ATR/VWAP unavailable");
      return;
   }

   //==================== Trend ====================//
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

   //==================== Pullback =================//
   double pullbackDistance = atr1 * VWAPPullbackATR;

   bool bullishPullback =
      r[1].low <= vwap1 + pullbackDistance &&
      r[1].close > vwap1;

   bool bearishPullback =
      r[1].high >= vwap1 - pullbackDistance &&
      r[1].close < vwap1;

   // Reclaim means the candle interacted with VWAP and closed back
   // on the trend side. This prevents entries far away from VWAP.
   bool bullishReclaim =
      r[1].low <= vwap1 &&
      r[1].close > vwap1;

   bool bearishReclaim =
      r[1].high >= vwap1 &&
      r[1].close < vwap1;

   //==================== Confirmation =============//
   double body = MathAbs(r[1].close-r[1].open);
   bool bullishCandle = r[1].close > r[1].open;
   bool bearishCandle = r[1].close < r[1].open;

   bool bullishConfirmation =
      !RequireCandleConfirmation ||
      (bullishCandle && body >= atr1*MinBodyATR);

   bool bearishConfirmation =
      !RequireCandleConfirmation ||
      (bearishCandle && body >= atr1*MinBodyATR);

   //==================== Final signals =============//
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

   if(longSignal)
   {
      Log("LONG SIGNAL | close=" + DoubleToString(r[1].close,_Digits) +
          " VWAP=" + DoubleToString(vwap1,_Digits) +
          " FastEMA=" + DoubleToString(fastEma1,_Digits) +
          " SlowEMA=" + DoubleToString(slowEma1,_Digits) +
          " ATR=" + DoubleToString(atr1,_Digits));

      OpenTrade(true,atr1);
      return;
   }

   if(shortSignal)
   {
      Log("SHORT SIGNAL | close=" + DoubleToString(r[1].close,_Digits) +
          " VWAP=" + DoubleToString(vwap1,_Digits) +
          " FastEMA=" + DoubleToString(fastEma1,_Digits) +
          " SlowEMA=" + DoubleToString(slowEma1,_Digits) +
          " ATR=" + DoubleToString(atr1,_Digits));

      OpenTrade(false,atr1);
      return;
   }

   Log("NO SIGNAL | trend=" +
       (bullishTrend ? "BULL" : bearishTrend ? "BEAR" : "NONE") +
       " | pullback=" +
       (bullishPullback || bearishPullback ? "YES" : "NO") +
       " | reclaim=" +
       (bullishReclaim || bearishReclaim ? "YES" : "NO"));
}
//+------------------------------------------------------------------+
