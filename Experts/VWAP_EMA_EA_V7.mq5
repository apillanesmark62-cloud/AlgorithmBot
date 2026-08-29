//+------------------------------------------------------------------+
//| VWAP_EMA_EA_V7.mq5                                               |
//| Multi-setup M5 EA with per-setup performance attribution         |
//| EDUCATIONAL / RESEARCH BUILD. No profitability is claimed.       |
//|                                                                  |
//| WHAT THIS IS                                                     |
//|  Three INDEPENDENT entry setups, each separately switchable and  |
//|  each separately measured. The point is not that all three make  |
//|  money - the point is that after one test run you will KNOW      |
//|  which ones do, and can disable the rest.                        |
//|                                                                  |
//|  A  VWAP reclaim            (the V6 setup, cleaned up)           |
//|  B  EMA pullback continuation                                    |
//|  C  Opening-range breakout                                       |
//|                                                                  |
//|  More trading days come from MORE SETUPS, never from a lower bar |
//|  on one setup. Adding marginal trades to a single setup lowers   |
//|  total return even though it raises the trade count.             |
//|                                                                  |
//| WHAT EXITS CAN AND CANNOT DO                                     |
//|  Under a driftless price process every stopping rule - fixed     |
//|  target, scale-out, breakeven, trailing - has EXACTLY zero       |
//|  expectancy (optional stopping theorem). Exits change win rate   |
//|  and average win; they do not create edge. They are provided     |
//|  here as VARIANCE management and because they capture more of a  |
//|  real edge when one exists. They are not a fix for a losing      |
//|  entry.                                                          |
//|                                                                  |
//|  The only reliably engineerable term is COST. That is why the    |
//|  spread and regime filters are strict by default.                |
//|                                                                  |
//| Retains every correctness fix from build 6.01.                   |
//+------------------------------------------------------------------+
#property version   "7.02"
#property description "Multi-setup M5 EA with per-setup attribution. Research build."

#include <Trade/Trade.mqh>

CTrade trade;

#define SETUP_COUNT 3
#define SETUP_VWAP  0
#define SETUP_PULL  1
#define SETUP_ORB   2

//==================================================
// Inputs
//==================================================
input group "=== General ==="
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M5;
input long   MagicNumber             = 26082907;
input int    MaxOpenPositions        = 1;
input int    MaxTradesPerDay         = 4;
input bool   AllowLongs              = true;
input bool   AllowShorts             = true;

input group "=== Setups (enable/disable independently) ==="
input bool   UseSetupVWAPReclaim     = true;   // A
input bool   UseSetupEMAPullback     = true;   // B
input bool   UseSetupORB             = true;   // C

input group "=== Trend ==="
input int    FastEMAPeriod           = 20;
input int    SlowEMAPeriod           = 50;
input ENUM_APPLIED_PRICE EMAPrice    = PRICE_CLOSE;
input bool   RequireEMASlope         = true;   // fast EMA must slope with the trade

input group "=== Setup A: VWAP reclaim ==="
input int    MinVWAPBars             = 12;
input int    ReclaimLookbackBars     = 3;

input group "=== Setup B: EMA pullback ==="
input double PullbackTouchATR        = 0.20;   // how close to the fast EMA counts as a touch

input group "=== Setup C: opening-range breakout ==="
input int    ORBRangeBars            = 12;     // bars from session start that build the range
input int    ORBValidBars            = 36;     // breakout must occur within this many bars

input group "=== Candle confirmation (all setups) ==="
input double MinBodyATR              = 0.15;   // body as a fraction of ATR
input double MinClosePct             = 55.0;   // close position within the bar range, %

input group "=== Regime filter (cost control) ==="
input double MinATRPoints            = 60;     // skip when ATR is too small to pay costs
input double MaxSpreadPoints         = 45;
input double MaxSpreadPctOfStop      = 10.0;

input group "=== Risk (fixed fractional - never scaled by results) ==="
input double RiskPercent             = 0.25;
input double MaxDailyLossPercent     = 1.5;
input int    MaxConsecutiveLosses    = 3;
input double MaxLotSize              = 1.0;

input group "=== Stops and targets ==="
input double ATRMultiplier           = 1.50;
input int    ATRPeriod               = 14;
input bool   UseStructureStop        = true;
input int    StructureLookback       = 5;
input double StructureBufferATR      = 0.15;
input double MaxStructureATR         = 2.00;
input double RewardRisk              = 2.50;

input group "=== Exit management (variance control, NOT edge) ==="
input bool   UseBreakeven            = true;
input double BreakevenAtR            = 1.00;
input double BreakevenBufferATR      = 0.05;
input bool   UsePartialClose         = true;
input double PartialAtR              = 1.00;
input double PartialPercent          = 50.0;
input bool   UseATRTrail             = true;
input double TrailATRMultiple        = 2.00;
input double TrailStartR             = 1.50;

input group "=== Session (server time) ==="
input bool   UseSessionFilter        = true;
input int    SessionStartHour        = 7;
input int    SessionEndHour          = 20;

input group "=== Execution ==="
input int    SlippagePoints          = 20;
input bool   AutoAdjustForDigits     = true;

input group "=== Diagnostics ==="
input bool   PrintDiagnostics        = false;

//==================================================
// Globals
//==================================================
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;

datetime lastBarTime = 0;
int  dayKey = -1;
int  tradesToday = 0;

double g_point = 0.0;
int    g_digits = 0;
double g_ptScale = 1.0;
double g_volMin = 0.0, g_volMax = 0.0, g_volStep = 0.0;
int    g_volDigits = 2;

//--- VWAP cache (rebuilt once per closed bar; bar 0 never included)
datetime g_vwapTimes[];
double   g_vwapValues[];
int      g_vwapBarsAt[];
int      g_vwapN = 0;

//--- open position state
ulong  g_ticket = 0;
int    g_posSetup = -1;
double g_posEntry = 0.0;
double g_posRisk  = 0.0;
double g_posRiskMoney = 0.0;   // FIX 7.01: $ actually risked at ENTRY
bool   g_posPartialDone = false;
bool   g_posBEDone = false;

//--- attribution
string sName[SETUP_COUNT];
long   sSignals[SETUP_COUNT];
long   sTrades[SETUP_COUNT];
long   sWins[SETUP_COUNT];
long   sLosses[SETUP_COUNT];
double sGrossWin[SETUP_COUNT];
double sGrossLoss[SETUP_COUNT];
double sSumR[SETUP_COUNT];

long   cBars=0, cSession=0, cDaily=0, cLossLimit=0, cStreak=0, cOpenPos=0;
long   cRegime=0, cSpread=0, cSpreadPct=0, cStops=0, cSize=0, cSendFail=0;
long   cDaysSeen=0, cDaysTraded=0;
int    lastCountedDay = -1;
bool   dayHadTrade = false;
int    g_lossStreak = 0;

//==================================================
// Small helpers
//==================================================
double Pts(const double points) { return points*g_ptScale*g_point; }

void Diag(const string s) { if(PrintDiagnostics) Print("[V7] ", s); }

int CurrentDayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.year*10000 + dt.mon*100 + dt.day;
}

datetime DayStartOf(const datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
}

int VolumeDigitsFromStep(const double step)
{
   if(step<=0.0) return 2;
   for(int d=0; d<=8; d++)
   {
      double sc = step*MathPow(10.0,(double)d);
      if(MathAbs(sc-MathRound(sc))<1e-8) return d;
   }
   return 2;
}

bool RefreshSymbol()
{
   g_point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_volDigits = VolumeDigitsFromStep(g_volStep);

   g_ptScale = 1.0;
   if(AutoAdjustForDigits && (g_digits==3 || g_digits==5)) g_ptScale = 10.0;

   return (g_point>0.0 && g_volStep>0.0 && g_volMin>0.0);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, EntryTF, 0);
   if(t==0 || t==lastBarTime) return false;
   lastBarTime = t;
   return true;
}

bool InSession()
{
   if(!UseSessionFilter) return true;
   if(SessionStartHour == SessionEndHour) return true;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(SessionStartHour < SessionEndHour)
      return (dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
   return (dt.hour >= SessionStartHour || dt.hour < SessionEndHour);
}

double SpreadPrice()
{
   double a = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double b = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(a<=0.0 || b<=0.0) return -1.0;
   return a-b;
}

int CountOurPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==MagicNumber) n++;
   }
   return n;
}

//==================================================
// VWAP cache
//==================================================
bool BuildVWAPCache()
{
   g_vwapN = 0;
   datetime lastClosed = iTime(_Symbol, EntryTF, 1);
   if(lastClosed==0) return false;

   datetime dayStart = DayStartOf(lastClosed);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, EntryTF, dayStart, lastClosed, rates);
   if(copied<=0) return false;

   if(ArrayResize(g_vwapTimes, copied)!=copied) return false;
   if(ArrayResize(g_vwapValues,copied)!=copied) return false;
   if(ArrayResize(g_vwapBarsAt,copied)!=copied) return false;

   double pv=0.0, vv=0.0;
   for(int i=0;i<copied;i++)
   {
      double tp=(rates[i].high+rates[i].low+rates[i].close)/3.0;
      double v=(double)rates[i].tick_volume;
      if(v<=0.0) v=1.0;
      pv+=tp*v; vv+=v;
      g_vwapTimes[i]=rates[i].time;
      g_vwapValues[i]=(vv>0.0 ? pv/vv : 0.0);
      g_vwapBarsAt[i]=i+1;
   }
   g_vwapN=copied;
   return true;
}

bool VWAPForShift(const int shift, double &vwap, int &bars)
{
   vwap=0.0; bars=0;
   if(g_vwapN<=0) return false;
   datetime t = iTime(_Symbol, EntryTF, shift);
   if(t==0) return false;
   for(int i=g_vwapN-1;i>=0;i--)
      if(g_vwapTimes[i]==t)
      {
         vwap=g_vwapValues[i];
         bars=g_vwapBarsAt[i];
         return (bars>=MinVWAPBars && vwap>0.0);
      }
   return false;
}

//--- FIX 7.01: the start of the CURRENT trading session, not midnight.
// The old BarsIntoSession() returned bars since midnight, so with
// SessionStartHour=10 the ORB window (36 bars) had already expired at
// 03:00 - seven hours before the session opened. Setup C fired once in
// 427 days and was never actually tested.
datetime SessionStartToday(const datetime barTime)
{
   datetime ds = DayStartOf(barTime);
   if(!UseSessionFilter) return ds;
   return ds + (datetime)(SessionStartHour*3600);
}

//==================================================
// Indicators
//==================================================
bool GetIndicators(double &fast1,double &fast2,double &slow1,double &atr1)
{
   double fast[], slow[], atr[];
   ArraySetAsSeries(fast,true);
   ArraySetAsSeries(slow,true);
   ArraySetAsSeries(atr,true);

   if(CopyBuffer(hFastEMA,0,0,3,fast)<3) return false;
   if(CopyBuffer(hSlowEMA,0,0,3,slow)<3) return false;
   if(CopyBuffer(hATR,    0,0,3,atr) <3) return false;

   fast1=fast[1]; fast2=fast[2]; slow1=slow[1]; atr1=atr[1];
   return (atr1>0.0);
}

//==================================================
// Candle quality - shared by every setup
//==================================================
bool BullCandle(const MqlRates &r,const double atr)
{
   double range = r.high-r.low;
   if(range<=0.0) return false;
   if(r.close<=r.open) return false;
   if((r.close-r.open) < atr*MinBodyATR) return false;
   if((r.close-r.low) < range*MinClosePct/100.0) return false;
   return true;
}

bool BearCandle(const MqlRates &r,const double atr)
{
   double range = r.high-r.low;
   if(range<=0.0) return false;
   if(r.close>=r.open) return false;
   if((r.open-r.close) < atr*MinBodyATR) return false;
   if((r.high-r.close) < range*MinClosePct/100.0) return false;
   return true;
}

//==================================================
// SETUP A - VWAP reclaim
//==================================================
int SetupVWAPReclaim(const MqlRates &r1,const MqlRates &r2,
                     const double vwap1,const double vwap2,
                     const double fast1,const double fast2,
                     const double slow1,const double atr1)
{
   if(!UseSetupVWAPReclaim) return 0;
   if(vwap1<=0.0 || vwap2<=0.0) return 0;

   bool up = (fast1>slow1) && (!RequireEMASlope || fast1>fast2);
   bool dn = (fast1<slow1) && (!RequireEMASlope || fast1<fast2);

   if(up && AllowLongs && BullCandle(r1,atr1) && r1.close>vwap1)
   {
      if(r2.close<=vwap2) return 1;
      for(int s=2;s<=ReclaimLookbackBars+1;s++)
      {
         double vw; int bc;
         if(!VWAPForShift(s,vw,bc)) continue;
         MqlRates rr[];
         ArraySetAsSeries(rr,true);
         if(CopyRates(_Symbol,EntryTF,s,1,rr)!=1) continue;
         if(rr[0].low<=vw) return 1;
      }
   }

   if(dn && AllowShorts && BearCandle(r1,atr1) && r1.close<vwap1)
   {
      if(r2.close>=vwap2) return -1;
      for(int s=2;s<=ReclaimLookbackBars+1;s++)
      {
         double vw; int bc;
         if(!VWAPForShift(s,vw,bc)) continue;
         MqlRates rr[];
         ArraySetAsSeries(rr,true);
         if(CopyRates(_Symbol,EntryTF,s,1,rr)!=1) continue;
         if(rr[0].high>=vw) return -1;
      }
   }

   return 0;
}

//==================================================
// SETUP B - pullback to the fast EMA in an established trend
//==================================================
int SetupEMAPullback(const MqlRates &r1,const double fast1,const double fast2,
                     const double slow1,const double atr1)
{
   if(!UseSetupEMAPullback) return 0;

   double touch = atr1*PullbackTouchATR;

   bool up = (fast1>slow1) && (!RequireEMASlope || fast1>fast2);
   bool dn = (fast1<slow1) && (!RequireEMASlope || fast1<fast2);

   // long: the bar dipped to/through the fast EMA and closed back above it
   if(up && AllowLongs && BullCandle(r1,atr1))
      if(r1.low <= fast1+touch && r1.close > fast1)
         return 1;

   if(dn && AllowShorts && BearCandle(r1,atr1))
      if(r1.high >= fast1-touch && r1.close < fast1)
         return -1;

   return 0;
}

//==================================================
// SETUP C - opening-range breakout
// The range is the high/low of the first ORBRangeBars closed bars of the
// server day. Only bars strictly AFTER that window can break it, and only
// within ORBValidBars of the session start.
//==================================================
int SetupORB(const MqlRates &r1,const double fast1,const double fast2,
             const double slow1,const double atr1)
{
   if(!UseSetupORB) return 0;

   datetime lastClosed = iTime(_Symbol, EntryTF, 1);
   if(lastClosed==0) return 0;

   // FIX 7.01: everything below is measured from the SESSION start.
   datetime ss = SessionStartToday(lastClosed);
   if(lastClosed < ss) return 0;

   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   int copied = CopyRates(_Symbol, EntryTF, ss, lastClosed, rates);
   if(copied <= ORBRangeBars) return 0;   // range still forming
   if(copied >  ORBValidBars) return 0;   // breakout window expired

   double rangeHigh = rates[0].high;
   double rangeLow  = rates[0].low;
   for(int i=1;i<ORBRangeBars && i<copied;i++)
   {
      if(rates[i].high>rangeHigh) rangeHigh=rates[i].high;
      if(rates[i].low <rangeLow ) rangeLow =rates[i].low;
   }
   if(rangeHigh<=rangeLow) return 0;

   bool up = (fast1>slow1) && (!RequireEMASlope || fast1>fast2);
   bool dn = (fast1<slow1) && (!RequireEMASlope || fast1<fast2);

   if(up && AllowLongs && BullCandle(r1,atr1) && r1.close>rangeHigh)
      return 1;

   if(dn && AllowShorts && BearCandle(r1,atr1) && r1.close<rangeLow)
      return -1;

   return 0;
}

//==================================================
// Risk / daily state, rebuilt from history (restart safe)
//==================================================
void RefreshDailyState(double &dailyPct,int &trades,int &lossStreak)
{
   dailyPct=0.0; trades=0; lossStreak=0;

   datetime now = TimeCurrent();
   datetime ds  = DayStartOf(now);
   double realized=0.0;

   if(HistorySelect(ds, now+1))
   {
      int total=HistoryDealsTotal();
      for(int i=0;i<total;i++)
      {
         ulong tk=HistoryDealGetTicket(i);
         if(tk==0) continue;
         if(HistoryDealGetString(tk,DEAL_SYMBOL)!=_Symbol) continue;
         if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=MagicNumber) continue;

         long type=HistoryDealGetInteger(tk,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;

         double pl = HistoryDealGetDouble(tk,DEAL_PROFIT)
                   + HistoryDealGetDouble(tk,DEAL_SWAP)
                   + HistoryDealGetDouble(tk,DEAL_COMMISSION);
         realized += pl;

         long entry = HistoryDealGetInteger(tk,DEAL_ENTRY);
         if(entry==DEAL_ENTRY_IN) trades++;
         if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
         {
            if(pl<0.0) lossStreak++;
            else       lossStreak=0;
         }
      }
   }

   double floating=0.0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      floating += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double start = bal-realized;
   if(start<=0.0) start = (bal>1.0?bal:1.0);
   dailyPct = (realized+floating)/start*100.0;
}

//==================================================
// Sizing - fixed fractional, never rounded up to the minimum
//==================================================
double NormalizeLots(double lots)
{
   if(g_volStep<=0.0) return 0.0;
   if(lots>g_volMax) lots=g_volMax;
   if(lots>MaxLotSize) lots=MaxLotSize;
   lots = MathFloor(lots/g_volStep+1e-9)*g_volStep;
   lots = NormalizeDouble(lots,g_volDigits);
   if(lots<g_volMin) return 0.0;
   return lots;
}

double CalculateLots(const double entry,const double sl)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0.0) return 0.0;

   double dist = MathAbs(entry-sl);
   if(dist<=0.0) return 0.0;

   double ts = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0.0) tv = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts<=0.0 || tv<=0.0) return 0.0;

   double lossPerLot = (dist/ts)*tv;
   if(lossPerLot<=0.0) return 0.0;

   double lots = NormalizeLots(bal*RiskPercent/100.0/lossPerLot);
   if(lots<=0.0)
      Diag(StringFormat("size skip: risk-correct lot below minimum %.2f; "
                        "minimum would risk %.2f%% vs %.2f%%",
                        g_volMin, g_volMin*lossPerLot/bal*100.0, RiskPercent));
   return lots;
}

double MinStopDistance()
{
   long sl_ = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long fz  = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   long req = (sl_>fz?sl_:fz);
   double d = (double)req*g_point;
   double sp = SpreadPrice();
   double m = (sp>0.0? sp+g_point : g_point);
   return (d>m?d:m);
}

//==================================================
// Entry
//==================================================
bool TryEnter(const int dir,const int setupId,const MqlRates &r1,const double atr1)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0||bid<=0.0) return false;

   bool isBuy = (dir>0);
   double entry = isBuy?ask:bid;

   double stopDist = atr1*ATRMultiplier;

   if(UseStructureStop)
   {
      MqlRates sr[];
      ArraySetAsSeries(sr,true);
      int n = CopyRates(_Symbol,EntryTF,1,StructureLookback,sr);
      if(n>0)
      {
         double lvl = isBuy?sr[0].low:sr[0].high;
         for(int i=1;i<n;i++)
         {
            if(isBuy  && sr[i].low <lvl) lvl=sr[i].low;
            if(!isBuy && sr[i].high>lvl) lvl=sr[i].high;
         }
         double buf = atr1*StructureBufferATR;
         double sd  = isBuy ? (entry-(lvl-buf)) : ((lvl+buf)-entry);
         double cap = atr1*MaxStructureATR;
         if(sd>cap) sd=cap;
         double flr = atr1*0.25;
         if(sd<flr) sd=flr;
         if(sd>0.0) stopDist = sd;
      }
   }

   if(stopDist<=0.0) return false;

   double sp = SpreadPrice();
   if(sp<0.0) return false;
   if(MaxSpreadPoints>0.0 && sp/g_point > MaxSpreadPoints*g_ptScale)
   { cSpread++; return false; }
   if(MaxSpreadPctOfStop>0.0 && sp/stopDist*100.0 > MaxSpreadPctOfStop)
   { cSpreadPct++; return false; }

   double sl = NormalizeDouble(isBuy?entry-stopDist:entry+stopDist, g_digits);
   double tp = NormalizeDouble(isBuy?entry+stopDist*RewardRisk
                                    :entry-stopDist*RewardRisk, g_digits);

   double minD = MinStopDistance();
   if(MathAbs(entry-sl)<minD || MathAbs(tp-entry)<minD) { cStops++; return false; }

   double lots = CalculateLots(entry,sl);
   if(lots<=0.0) { cSize++; return false; }

   double margin=0.0;
   if(!OrderCalcMargin(isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,_Symbol,lots,entry,margin)
      || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { cSize++; return false; }

   bool sent = isBuy ? trade.Buy (lots,_Symbol,0.0,sl,tp,"V7 "+sName[setupId])
                     : trade.Sell(lots,_Symbol,0.0,sl,tp,"V7 "+sName[setupId]);

   uint rc = trade.ResultRetcode();
   if(!sent || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_DONE_PARTIAL
                && rc!=TRADE_RETCODE_PLACED))
   {
      cSendFail++;
      Print("[V7] ORDER FAILED | ", sName[setupId], " | retcode=", (int)rc,
            " ", trade.ResultRetcodeDescription());
      return false;
   }

   double fill = trade.ResultPrice();
   if(fill<=0.0) fill=entry;

   g_ticket = 0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
      { g_ticket=t; break; }
   }

   g_posSetup = setupId;
   g_posEntry = fill;
   g_posRisk  = MathAbs(fill-sl);

   // FIX 7.01: capture the $ risk actually taken, so the R attribution is
   // not distorted as the account balance changes over the run.
   double ts_ = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv_ = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv_<=0.0) tv_ = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   g_posRiskMoney = (ts_>0.0 && tv_>0.0 && g_posRisk>0.0)
                    ? lots*(g_posRisk/ts_)*tv_ : 0.0;
   g_posPartialDone = false;
   g_posBEDone = false;

   tradesToday++;
   sTrades[setupId]++;
   dayHadTrade = true;

   Print("[V7] OPENED ", (isBuy?"BUY  ":"SELL "), sName[setupId],
         " | lots=", DoubleToString(lots,g_volDigits),
         " fill=", DoubleToString(fill,g_digits),
         " SL=",   DoubleToString(sl,g_digits),
         " TP=",   DoubleToString(tp,g_digits),
         " risk=", DoubleToString(g_posRisk/g_point,0), "pts");
   return true;
}

//==================================================
// Position management - variance control only
//==================================================
void ManagePosition()
{
   if(g_ticket==0) return;
   if(!PositionSelectByTicket(g_ticket)) return;

   long type = PositionGetInteger(POSITION_TYPE);
   bool isBuy = (type==POSITION_TYPE_BUY);
   double sl  = PositionGetDouble(POSITION_SL);
   double vol = PositionGetDouble(POSITION_VOLUME);

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double px = isBuy?bid:ask;
   if(px<=0.0 || g_posRisk<=0.0) return;

   double rNow = isBuy ? (px-g_posEntry)/g_posRisk : (g_posEntry-px)/g_posRisk;

   double atr[];
   ArraySetAsSeries(atr,true);
   double atr1 = 0.0;
   if(CopyBuffer(hATR,0,1,1,atr)==1) atr1 = atr[0];

   // 1) partial
   if(UsePartialClose && !g_posPartialDone && rNow>=PartialAtR)
   {
      double closeVol = NormalizeDouble(
         MathFloor(vol*PartialPercent/100.0/g_volStep+1e-9)*g_volStep, g_volDigits);
      if(closeVol>=g_volMin && (vol-closeVol)>=g_volMin)
      {
         if(trade.PositionClosePartial(g_ticket, closeVol))
         {
            g_posPartialDone = true;
            Print("[V7] PARTIAL ", DoubleToString(closeVol,g_volDigits),
                  " at ", DoubleToString(rNow,2), "R");
         }
      }
      else g_posPartialDone = true;   // too small to split; do not retry
   }

   // 2) breakeven
   if(UseBreakeven && !g_posBEDone && rNow>=BreakevenAtR && atr1>0.0)
   {
      double buf = atr1*BreakevenBufferATR;
      double be  = NormalizeDouble(isBuy?g_posEntry+buf:g_posEntry-buf, g_digits);
      bool better = isBuy ? (be>sl) : (be<sl || sl==0.0);
      if(better)
      {
         double tp = PositionGetDouble(POSITION_TP);
         if(trade.PositionModify(g_ticket, be, tp))
         {
            g_posBEDone = true;
            Print("[V7] BREAKEVEN at ", DoubleToString(rNow,2), "R");
         }
      }
   }

   // 3) ATR trail
   if(UseATRTrail && rNow>=TrailStartR && atr1>0.0)
   {
      double newSl = isBuy ? px-atr1*TrailATRMultiple : px+atr1*TrailATRMultiple;
      newSl = NormalizeDouble(newSl, g_digits);
      double minD = MinStopDistance();
      bool ok = isBuy ? (newSl>sl && px-newSl>=minD)
                      : ((newSl<sl||sl==0.0) && newSl-px>=minD);
      if(ok)
      {
         double tp = PositionGetDouble(POSITION_TP);
         trade.PositionModify(g_ticket, newSl, tp);
      }
   }
}

//--- attribute a closed position to its setup
void SettleClosedPosition()
{
   if(g_ticket==0) return;
   if(PositionSelectByTicket(g_ticket)) return;   // still open

   double pl=0.0;
   if(HistorySelectByPosition(g_ticket))
   {
      int n=HistoryDealsTotal();
      for(int i=0;i<n;i++)
      {
         ulong tk=HistoryDealGetTicket(i);
         if(tk==0) continue;
         pl += HistoryDealGetDouble(tk,DEAL_PROFIT)
             + HistoryDealGetDouble(tk,DEAL_SWAP)
             + HistoryDealGetDouble(tk,DEAL_COMMISSION);
      }
   }

   int s = g_posSetup;
   if(s>=0 && s<SETUP_COUNT)
   {
      if(pl>=0.0) { sWins[s]++;   sGrossWin[s]  += pl;  }
      else        { sLosses[s]++; sGrossLoss[s] += -pl; }

      // FIX 7.01: divide by the risk taken AT ENTRY. The old code used
      // balance*RiskPercent at CLOSE time, so as the account declined the
      // divisor shrank and later trades reported inflated R multiples.
      if(g_posRiskMoney>0.0) sSumR[s] += pl/g_posRiskMoney;

      Print("[V7] CLOSED ", sName[s], " | P/L=", DoubleToString(pl,2));
   }

   g_ticket=0; g_posSetup=-1; g_posEntry=0.0; g_posRisk=0.0;
   g_posRiskMoney=0.0;
   g_posPartialDone=false; g_posBEDone=false;
}

//==================================================
// Lifecycle
//==================================================
int OnInit()
{
   if(!RefreshSymbol())
   {
      Print("[V7] Invalid symbol specification.");
      return INIT_FAILED;
   }
   if(FastEMAPeriod<=0 || SlowEMAPeriod<=0 || FastEMAPeriod>=SlowEMAPeriod ||
      ATRPeriod<=0 || RiskPercent<=0.0 || RewardRisk<=0.0)
   {
      Print("[V7] Invalid inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFastEMA = iMA (_Symbol,EntryTF,FastEMAPeriod,0,MODE_EMA,EMAPrice);
   hSlowEMA = iMA (_Symbol,EntryTF,SlowEMAPeriod,0,MODE_EMA,EMAPrice);
   hATR     = iATR(_Symbol,EntryTF,ATRPeriod);
   if(hFastEMA==INVALID_HANDLE||hSlowEMA==INVALID_HANDLE||hATR==INVALID_HANDLE)
   {
      Print("[V7] Failed to create indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints<1?1:SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   sName[SETUP_VWAP]="VWAP_RECLAIM";
   sName[SETUP_PULL]="EMA_PULLBACK";
   sName[SETUP_ORB] ="ORB_BREAKOUT";
   ArrayInitialize(sSignals,0); ArrayInitialize(sTrades,0);
   ArrayInitialize(sWins,0);    ArrayInitialize(sLosses,0);
   ArrayInitialize(sGrossWin,0.0); ArrayInitialize(sGrossLoss,0.0);
   ArrayInitialize(sSumR,0.0);

   dayKey = CurrentDayKey();

   Print("=================================================================");
   Print("[V7] initialised on ",_Symbol," TF=",EnumToString(EntryTF));
   Print("[V7] Setups: VWAP=",UseSetupVWAPReclaim,
         " Pullback=",UseSetupEMAPullback," ORB=",UseSetupORB);
   Print("[V7] Point scale=",DoubleToString(g_ptScale,0),
         " -> MinATR=",DoubleToString(Pts(MinATRPoints),g_digits),
         " MaxSpread=",DoubleToString(Pts(MaxSpreadPoints),g_digits));
   Print("[V7] Risk=",DoubleToString(RiskPercent,2),"% RR=",DoubleToString(RewardRisk,2),
         " MaxDailyLoss=",DoubleToString(MaxDailyLossPercent,2),"%");
   Print("[V7] Server time now: ",TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
         " | session ",SessionStartHour,"-",SessionEndHour," SERVER time");
   Print("[V7] NO profitability is claimed. Read the per-setup attribution");
   Print("[V7] block at the end of the run before trusting anything.");
   Print("=================================================================");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFastEMA!=INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA!=INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hATR    !=INVALID_HANDLE) IndicatorRelease(hATR);
   PrintReport();
}

void PrintReport()
{
   Print("============== V7 PER-SETUP ATTRIBUTION ==============");
   Print("Days seen: ",cDaysSeen,"   Days with >=1 trade: ",cDaysTraded,
         (cDaysSeen>0 ? "   ("+DoubleToString(100.0*cDaysTraded/cDaysSeen,1)+"% of days)" : ""));
   Print("-----------------------------------------------------");
   for(int s=0;s<SETUP_COUNT;s++)
   {
      long closed = sWins[s]+sLosses[s];
      double pf   = (sGrossLoss[s]>0.0 ? sGrossWin[s]/sGrossLoss[s] : 0.0);
      double wr   = (closed>0 ? 100.0*sWins[s]/closed : 0.0);
      double eR   = (closed>0 ? sSumR[s]/closed : 0.0);
      Print(sName[s],
            " | signals=",sSignals[s],
            " trades=",sTrades[s],
            " closed=",closed,
            " win%=",DoubleToString(wr,1),
            " PF=",DoubleToString(pf,2),
            " netR=",DoubleToString(sSumR[s],2),
            " E[R]/trade=",DoubleToString(eR,3));
   }
   Print("-----------------------------------------------------");
   Print("Rejections: session=",cSession," dailyLimit=",cDaily,
         " lossLimit=",cLossLimit," streak=",cStreak," openPos=",cOpenPos);
   Print("            regime=",cRegime," spread=",cSpread,
         " spread%OfStop=",cSpreadPct," stops=",cStops,
         " size=",cSize," sendFail=",cSendFail);
   Print("Bars evaluated: ",cBars);
   Print("-----------------------------------------------------");
   Print("HOW TO READ THIS: a setup with few closed trades proves nothing,");
   Print("however good its PF looks. Disable setups with E[R]/trade <= 0");
   Print("across MULTIPLE periods, not one. A setup that only works in the");
   Print("period you tuned on is a curve fit.");
   Print("=====================================================");
}

//==================================================
// Main
//==================================================
void OnTick()
{
   SettleClosedPosition();
   ManagePosition();

   if(!IsNewBar()) return;

   int k = CurrentDayKey();
   if(k!=dayKey)
   {
      if(lastCountedDay!=-1) { cDaysSeen++; if(dayHadTrade) cDaysTraded++; }
      dayKey=k; tradesToday=0; dayHadTrade=false; lastCountedDay=k;
   }
   else if(lastCountedDay==-1) lastCountedDay=k;

   cBars++;

   if(!InSession())                      { cSession++;  return; }
   if(MaxOpenPositions>0 && CountOurPositions()>=MaxOpenPositions)
                                         { cOpenPos++;  return; }

   double dailyPct; int dTrades, streak;
   RefreshDailyState(dailyPct,dTrades,streak);
   g_lossStreak = streak;

   if(MaxTradesPerDay>0 && dTrades>=MaxTradesPerDay)          { cDaily++;     return; }
   if(MaxDailyLossPercent>0.0 && dailyPct<=-MaxDailyLossPercent){ cLossLimit++; return; }
   if(MaxConsecutiveLosses>0 && streak>=MaxConsecutiveLosses) { cStreak++;    return; }

   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,EntryTF,0,3,r)<3) return;

   double fast1,fast2,slow1,atr1;
   if(!GetIndicators(fast1,fast2,slow1,atr1)) return;

   // regime: ATR must be large enough that costs are a small fraction
   if(MinATRPoints>0.0 && atr1 < Pts(MinATRPoints)) { cRegime++; return; }

   double vwap1=0.0, vwap2=0.0;
   int b1=0,b2=0;
   bool vwapOK = (BuildVWAPCache() && VWAPForShift(1,vwap1,b1) && VWAPForShift(2,vwap2,b2));

   int dir=0, setupId=-1;

   if(vwapOK)
   {
      dir = SetupVWAPReclaim(r[1],r[2],vwap1,vwap2,fast1,fast2,slow1,atr1);
      if(dir!=0) setupId=SETUP_VWAP;
   }
   if(dir==0)
   {
      dir = SetupEMAPullback(r[1],fast1,fast2,slow1,atr1);
      if(dir!=0) setupId=SETUP_PULL;
   }
   // FIX 7.02: Setup C does not read the VWAP at all, so gating it behind
   // vwapOK was wrong. On timeframes with few bars per day (H4 has six) the
   // daily VWAP can never reach MinVWAPBars, which silently disabled the
   // breakout setup as well and produced zero trades.
   if(dir==0)
   {
      dir = SetupORB(r[1],fast1,fast2,slow1,atr1);
      if(dir!=0) setupId=SETUP_ORB;
   }

   if(dir==0 || setupId<0) return;

   sSignals[setupId]++;
   Diag(StringFormat("%s signal dir=%d close=%s ATR=%s",
                     sName[setupId],dir,
                     DoubleToString(r[1].close,g_digits),
                     DoubleToString(atr1,g_digits)));

   TryEnter(dir,setupId,r[1],atr1);
}
//+------------------------------------------------------------------+
