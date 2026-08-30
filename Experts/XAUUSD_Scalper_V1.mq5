//+------------------------------------------------------------------+
//|                                          XAUUSD_Scalper_V1.mq5   |
//|                                                                  |
//|  XAUUSD scalper:                                                 |
//|    M15 bias -> M5 liquidity sweep -> M5 MSS/BOS -> M5 FVG ->     |
//|    M1 retracement -> M1 confirmation candle -> entry             |
//|                                                                  |
//|  Every structural decision is taken on CLOSED bars only.         |
//|  Fixed fractional risk. No martingale, no averaging, no risk     |
//|  increase after a loss.                                          |
//|                                                                  |
//|  The formal definition of every term used below is documented in |
//|  docs/XAUUSD_Scalper_V1.md and implemented literally here.       |
//+------------------------------------------------------------------+
#property copyright "XAUUSD_Scalper_V1"
#property link      "https://github.com/apillanesmark62-cloud/AlgorithmBot"
#property version   "1.00"
#property description "XAUUSD scalper: M15 bias, M5 sweep/MSS/FVG, M1 confirmation entry."
#property description "Fixed fractional risk - no martingale, no averaging, no recovery trades."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_BIAS
  {
   BIAS_NONE    =  0, // None
   BIAS_BULLISH =  1, // Bullish
   BIAS_BEARISH = -1  // Bearish
  };

enum ENUM_SCALPER_STATE
  {
   ST_WAIT_BIAS     = 0, // Waiting for M15 bias
   ST_WAIT_SWEEP    = 1, // Waiting for M5 liquidity sweep
   ST_WAIT_MSS      = 2, // Waiting for M5 MSS/BOS
   ST_WAIT_FVG      = 3, // Waiting for M5 FVG
   ST_WAIT_RETRACE  = 4, // Waiting for M1 retracement into FVG
   ST_WAIT_CONFIRM  = 5, // Waiting for M1 confirmation candle
   ST_TRADE_OPEN    = 6  // Trade open
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== M15 bias structure ==="
input int    M15_SwingStrength   = 2;        // M15 swing strength (bars each side)
input int    M15_LookbackBars    = 200;      // M15 lookback bars

input group "=== M5 setup structure ==="
input int    M5_SwingStrength    = 2;        // M5 swing strength (bars each side)
input int    M5_LookbackBars     = 200;      // M5 lookback bars
input double SweepMinPenetration = 10;       // Min sweep penetration (points)
input int    MaxSweepAgeBars     = 20;       // Max sweep age (M5 bars)
input int    MSSSwingSearchBars  = 20;       // MSS swing search depth before sweep (M5 bars)
input double MinimumFVGSize      = 30;       // Minimum FVG size (points)

input group "=== M1 entry confirmation ==="
input double M1_MinBodyPercent   = 25.0;     // Min candle body (% of M1 bar range)
input double M1_MinClosePct      = 50.0;     // Min close position (% of M1 bar range)

input group "=== Risk ==="
input double RiskPercent         = 0.25;     // Risk per trade (% of equity)
input double RiskReward          = 2.0;      // Reward : Risk ratio
input double SLBufferPoints      = 50;       // SL buffer beyond sweep extreme (points)
input double MaxLotSize          = 1.0;      // Maximum lot size

input group "=== Scalping protection ==="
input int    MaxTradesPerDay      = 5;       // Max trades per day
input int    MaxConsecutiveLosses = 3;       // Max consecutive losses (per day)
input double MaxDailyLossPercent  = 1.5;     // Max daily loss (%)
input int    MaxOpenPositions     = 1;       // Max simultaneous positions
input double MaxSpreadPoints      = 40;      // Max allowed spread (points)
input int    SetupExpirationBars  = 12;      // Setup expiration (M5 bars)

input group "=== Session (BROKER / SERVER TIME!) ==="
input int    TradingSessionStart = 7;        // Session start hour (server time)
input int    TradingSessionEnd   = 20;       // Session end hour (server time)

input group "=== Execution ==="
input long   MagicNumber         = 20250817; // Magic number
input int    MaxSlippagePoints   = 30;       // Max deviation (broker points)
input string TradeComment        = "XAUScalpV1"; // Trade comment
input bool   AutoAdjustForDigits = true;     // Scale point inputs on 3/5 digit feeds

input group "=== Diagnostics ==="
input bool   ShowStatusComment   = true;     // Show status comment on chart
input bool   VerboseLogging      = true;     // Log every strategy step

//+------------------------------------------------------------------+
//| Setup container                                                  |
//+------------------------------------------------------------------+
struct ScalpSetup
  {
   ENUM_BIAS  dir;            // direction of the setup
   datetime   id;             // unique id = sweep bar time
   double     swept_level;    // M5 swing level that was taken out
   double     sweep_extreme;  // sweep low (bull) / sweep high (bear)
   datetime   sweep_time;     // M5 bar time of the sweep candle
   int        bars_alive;     // age in M5 bars
   bool       mss_done;       // MSS/BOS confirmed
   double     mss_level;      // broken M5 swing level
   datetime   mss_time;       // M5 bar time of the breaking candle
   bool       fvg_done;       // FVG located
   double     fvg_low;        // FVG lower boundary
   double     fvg_high;       // FVG upper boundary
   datetime   fvg_time;       // M5 bar time of candle 3 of the FVG
   bool       retrace_done;   // price has traded into the FVG on M1
   bool       traded;         // setup has produced its one trade
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade             trade;

ScalpSetup         g_setup;
ENUM_SCALPER_STATE g_state       = ST_WAIT_BIAS;
ENUM_BIAS          g_bias        = BIAS_NONE;
ENUM_BIAS          g_bias_prev   = BIAS_NONE;

datetime           g_last_m5     = 0;   // last processed M5 bar
datetime           g_last_m1     = 0;   // last processed M1 bar
datetime           g_last_setup  = 0;   // last consumed sweep (duplicate guard)
datetime           g_day_start   = 0;

double             g_point       = 0.0;
int                g_digits      = 0;
double             g_pt_scale    = 1.0; // input point -> broker point factor
double             g_vol_min     = 0.0;
double             g_vol_max     = 0.0;
double             g_vol_step    = 0.0;
int                g_vol_digits  = 2;
int                g_stops_level = 0;

int                g_trades_today = 0;
int                g_loss_streak  = 0;
double             g_realized     = 0.0;
double             g_daily_pl_pct = 0.0;
double             g_day_start_bal= 0.0;

bool               g_init_ok      = false;
string             g_halt_reason  = "";
string             g_last_reject  = "";
bool               g_hard_reject  = false;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   Print(msg);
  }

void LogStep(const string msg)
  {
   if(VerboseLogging)
      Print(msg);
  }

//+------------------------------------------------------------------+
//| Rejection logging - identical reasons are printed only once      |
//| until something else happens, so the journal stays readable.     |
//+------------------------------------------------------------------+
void Reject(const string reason,const bool hard=false)
  {
   if(hard)
      g_hard_reject = true;
   if(reason==g_last_reject)
      return;
   g_last_reject = reason;
   Print("Trade rejected: "+reason);
  }

string BiasToString(const ENUM_BIAS b)
  {
   if(b==BIAS_BULLISH) return("BULLISH");
   if(b==BIAS_BEARISH) return("BEARISH");
   return("NONE");
  }

string StateToString(const ENUM_SCALPER_STATE s)
  {
   switch(s)
     {
      case ST_WAIT_BIAS:    return("WAIT_BIAS");
      case ST_WAIT_SWEEP:   return("WAIT_SWEEP");
      case ST_WAIT_MSS:     return("WAIT_MSS");
      case ST_WAIT_FVG:     return("WAIT_FVG");
      case ST_WAIT_RETRACE: return("WAIT_RETRACE");
      case ST_WAIT_CONFIRM: return("WAIT_CONFIRM");
      case ST_TRADE_OPEN:   return("TRADE_OPEN");
     }
   return("UNKNOWN");
  }

//+------------------------------------------------------------------+
//| Convert an input "point" value into a price distance             |
//+------------------------------------------------------------------+
double Pts(const double points)
  {
   return(points*g_pt_scale*g_point);
  }

//+------------------------------------------------------------------+
//| Broker points currently between bid and ask                      |
//+------------------------------------------------------------------+
double SpreadPoints()
  {
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0 || g_point<=0.0)
      return(1e9);
   return((ask-bid)/g_point);
  }

//+------------------------------------------------------------------+
//| Volume digits derived from the broker volume step                |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   if(step<=0.0)
      return(2);
   for(int d=0; d<=8; d++)
     {
      double scaled = step*MathPow(10.0,d);
      if(MathAbs(scaled-MathRound(scaled))<1e-8)
         return(d);
     }
   return(2);
  }

//+------------------------------------------------------------------+
//| Cache symbol properties                                          |
//+------------------------------------------------------------------+
bool RefreshSymbolInfo()
  {
   g_point       = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits      = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_vol_min     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_vol_max     = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_vol_step    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_stops_level = (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_vol_digits  = VolumeDigits(g_vol_step);

   g_pt_scale = 1.0;
   if(AutoAdjustForDigits && (g_digits==3 || g_digits==5))
      g_pt_scale = 10.0;

   if(g_point<=0.0 || g_vol_step<=0.0)
     {
      Log("Init error: invalid symbol properties (point / volume step).");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Reset the setup and return to the sweep hunt                     |
//+------------------------------------------------------------------+
void ResetSetup(const string reason)
  {
   if(g_setup.dir!=BIAS_NONE && reason!="")
      LogStep("Setup cancelled ("+BiasToString(g_setup.dir)+" "
              +TimeToString(g_setup.id,TIME_DATE|TIME_MINUTES)+"): "+reason);

   g_setup.dir           = BIAS_NONE;
   g_setup.id            = 0;
   g_setup.swept_level   = 0.0;
   g_setup.sweep_extreme = 0.0;
   g_setup.sweep_time    = 0;
   g_setup.bars_alive    = 0;
   g_setup.mss_done      = false;
   g_setup.mss_level     = 0.0;
   g_setup.mss_time      = 0;
   g_setup.fvg_done      = false;
   g_setup.fvg_low       = 0.0;
   g_setup.fvg_high      = 0.0;
   g_setup.fvg_time      = 0;
   g_setup.retrace_done  = false;
   g_setup.traded        = false;

   g_hard_reject = false;
   g_last_reject = "";

   g_state = (g_bias==BIAS_NONE ? ST_WAIT_BIAS : ST_WAIT_SWEEP);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!RefreshSymbolInfo())
      return(INIT_FAILED);

   if(M15_SwingStrength<1 || M5_SwingStrength<1)
     {
      Log("Init error: swing strength must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(M15_LookbackBars < M15_SwingStrength*2+20 || M5_LookbackBars < M5_SwingStrength*2+20)
     {
      Log("Init error: lookback bars too small for the configured swing strength.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(RiskPercent<=0.0 || RiskReward<=0.0 || MaxLotSize<=0.0)
     {
      Log("Init error: RiskPercent, RiskReward and MaxLotSize must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(SetupExpirationBars<1 || MaxSweepAgeBars<1 || MSSSwingSearchBars<1)
     {
      Log("Init error: bar-count inputs must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(M1_MinBodyPercent<0.0 || M1_MinBodyPercent>100.0
      || M1_MinClosePct<0.0 || M1_MinClosePct>100.0)
     {
      Log("Init error: M1 confirmation percentages must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(TradingSessionStart<0 || TradingSessionStart>23
      || TradingSessionEnd<0 || TradingSessionEnd>23)
     {
      Log("Init error: session hours must be between 0 and 23.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)MathMax(1,MaxSlippagePoints));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   g_bias = BIAS_NONE;
   ResetSetup("");
   g_last_m5 = 0;
   g_last_m1 = 0;

   UpdateDailyStats(true);
   RecoverOpenPosition();

   g_init_ok = true;

   Log("=================================================================");
   Log("XAUUSD_Scalper_V1 initialised on "+_Symbol);
   Log(StringFormat("Point scaling: digits=%d point=%s scale=%.0f  => 1 input point = %s price",
                    g_digits,DoubleToString(g_point,g_digits),g_pt_scale,
                    DoubleToString(Pts(1.0),g_digits)));
   Log("  MinimumFVGSize      "+DoubleToString(MinimumFVGSize,0)+" pts = "
       +DoubleToString(Pts(MinimumFVGSize),g_digits));
   Log("  SLBufferPoints      "+DoubleToString(SLBufferPoints,0)+" pts = "
       +DoubleToString(Pts(SLBufferPoints),g_digits));
   Log("  SweepMinPenetration "+DoubleToString(SweepMinPenetration,0)+" pts = "
       +DoubleToString(Pts(SweepMinPenetration),g_digits));
   Log("  MaxSpreadPoints     "+DoubleToString(MaxSpreadPoints,0)+" pts = "
       +DoubleToString(Pts(MaxSpreadPoints),g_digits));
   Log(StringFormat("Volume: min=%s max=%s step=%s",
                    DoubleToString(g_vol_min,g_vol_digits),
                    DoubleToString(g_vol_max,g_vol_digits),
                    DoubleToString(g_vol_step,g_vol_digits)));
   Log(StringFormat("Current server time: %s  (session filter %d:00-%d:00 server)",
                    TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
                    TradingSessionStart,TradingSessionEnd));
   Log("Session hours are BROKER/SERVER time - adjust them to your broker's timezone.");

   if(StringFind(_Symbol,"XAU")<0 && StringFind(_Symbol,"GOLD")<0
      && StringFind(_Symbol,"Gold")<0)
      Log("WARNING: this EA is tuned for XAUUSD - the defaults will not suit "+_Symbol+".");

   Log("=================================================================");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
//| New bar detection per timeframe                                  |
//+------------------------------------------------------------------+
bool IsNewBar(const ENUM_TIMEFRAMES tf,datetime &last)
  {
   datetime t = iTime(_Symbol,tf,0);
   if(t==0 || t==last)
      return(false);
   last = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Load closed-bar history, series ordered (index 0 = forming bar)  |
//+------------------------------------------------------------------+
int LoadRates(const ENUM_TIMEFRAMES tf,const int count,MqlRates &r[])
  {
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,tf,0,count,r);
   return(copied>0 ? copied : 0);
  }

//+------------------------------------------------------------------+
//| Definitions 1/5: confirmed swing high at index i                 |
//|   i >= strength+1, H[i] strictly above the 'strength' bars on    |
//|   both sides.                                                    |
//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[],const int i,const int strength)
  {
   int total = ArraySize(r);
   if(i < strength+1 || i+strength >= total)
      return(false);
   double h = r[i].high;
   for(int k=1; k<=strength; k++)
     {
      if(r[i+k].high >= h) return(false);
      if(r[i-k].high >= h) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Definitions 2/6: confirmed swing low at index i                  |
//+------------------------------------------------------------------+
bool IsSwingLow(const MqlRates &r[],const int i,const int strength)
  {
   int total = ArraySize(r);
   if(i < strength+1 || i+strength >= total)
      return(false);
   double l = r[i].low;
   for(int k=1; k<=strength; k++)
     {
      if(r[i+k].low <= l) return(false);
      if(r[i-k].low <= l) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| The two most recent confirmed swing highs (newest first)         |
//+------------------------------------------------------------------+
bool LastTwoSwingHighs(const MqlRates &r[],const int strength,int &i1,int &i2)
  {
   i1 = -1;
   i2 = -1;
   int total = ArraySize(r);
   for(int i=strength+1; i<total-strength; i++)
     {
      if(!IsSwingHigh(r,i,strength))
         continue;
      if(i1<0)      i1 = i;
      else        { i2 = i; return(true); }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| The two most recent confirmed swing lows (newest first)          |
//+------------------------------------------------------------------+
bool LastTwoSwingLows(const MqlRates &r[],const int strength,int &i1,int &i2)
  {
   i1 = -1;
   i2 = -1;
   int total = ArraySize(r);
   for(int i=strength+1; i<total-strength; i++)
     {
      if(!IsSwingLow(r,i,strength))
         continue;
      if(i1<0)      i1 = i;
      else        { i2 = i; return(true); }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Definitions 3/4: objective M15 directional bias                  |
//|                                                                  |
//|   BULLISH: higher high AND higher low AND last M15 close still   |
//|            above the most recent confirmed swing low.            |
//|   BEARISH: lower high AND lower low AND last M15 close still     |
//|            below the most recent confirmed swing high.           |
//|   Anything else is NONE and blocks all trading.                  |
//+------------------------------------------------------------------+
ENUM_BIAS ComputeM15Bias()
  {
   MqlRates r[];
   int copied = LoadRates(PERIOD_M15,M15_LookbackBars,r);
   if(copied < M15_SwingStrength*2+10)
      return(BIAS_NONE);

   int h1=-1,h2=-1,l1=-1,l2=-1;
   if(!LastTwoSwingHighs(r,M15_SwingStrength,h1,h2))
      return(BIAS_NONE);
   if(!LastTwoSwingLows(r,M15_SwingStrength,l1,l2))
      return(BIAS_NONE);

   double last_close = r[1].close;

   bool higher_high = (r[h1].high > r[h2].high);
   bool higher_low  = (r[l1].low  > r[l2].low);
   bool lower_high  = (r[h1].high < r[h2].high);
   bool lower_low   = (r[l1].low  < r[l2].low);

   if(higher_high && higher_low && last_close > r[l1].low)
      return(BIAS_BULLISH);
   if(lower_high && lower_low && last_close < r[h1].high)
      return(BIAS_BEARISH);

   return(BIAS_NONE);
  }

//+------------------------------------------------------------------+
//| Refresh the bias and report changes                              |
//+------------------------------------------------------------------+
void UpdateM15Bias()
  {
   g_bias_prev = g_bias;
   g_bias      = ComputeM15Bias();

   if(g_bias!=g_bias_prev)
     {
      LogStep("M15 bias detected: "+BiasToString(g_bias)
              +" (was "+BiasToString(g_bias_prev)+")");

      // a setup only exists while the bias that produced it still holds
      if(g_setup.dir!=BIAS_NONE && g_setup.dir!=g_bias && !g_setup.traded)
         ResetSetup("M15 bias changed to "+BiasToString(g_bias));
     }

   if(g_state==ST_WAIT_BIAS && g_bias!=BIAS_NONE)
      g_state = ST_WAIT_SWEEP;
   if(g_bias==BIAS_NONE && g_setup.dir==BIAS_NONE)
      g_state = ST_WAIT_BIAS;
  }

//+------------------------------------------------------------------+
//| Index of the newest bar whose open time is <= t, or -1           |
//+------------------------------------------------------------------+
int IndexOfTime(const MqlRates &r[],const datetime t)
  {
   int total = ArraySize(r);
   for(int i=0; i<total; i++)
      if(r[i].time<=t)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Definition 7: M5 liquidity sweep                                 |
//|                                                                  |
//| Closed bar j sweeps a confirmed swing low s (s >= j+K5+1) when   |
//| it penetrates the level by at least SweepMinPenetration points   |
//| and closes back above it. A bare touch is not a sweep.           |
//+------------------------------------------------------------------+
bool DetectM5Sweep()
  {
   if(g_bias==BIAS_NONE)
      return(false);

   MqlRates r[];
   int need = (int)MathMax((double)M5_LookbackBars,
                           (double)(MaxSweepAgeBars+MSSSwingSearchBars+M5_SwingStrength*2+20));
   int copied = LoadRates(PERIOD_M5,need,r);
   if(copied < M5_SwingStrength*2+10)
      return(false);

   int max_j = (int)MathMin((double)MaxSweepAgeBars,
                            (double)(copied-(M5_SwingStrength*2+3)));
   double penetration = Pts(SweepMinPenetration);

   for(int j=1; j<=max_j; j++)
     {
      if(r[j].time <= g_last_setup)   // this sweep was already used
         break;

      if(g_bias==BIAS_BULLISH)
        {
         int s = -1;
         for(int i=j+M5_SwingStrength+1; i<copied-M5_SwingStrength; i++)
            if(IsSwingLow(r,i,M5_SwingStrength))
              {
               s = i;
               break;
              }
         if(s<0)
            continue;

         double level = r[s].low;
         if(r[j].low < level-penetration && r[j].close > level)
           {
            LogStep("M5 liquidity level detected: swing low "
                    +DoubleToString(level,g_digits)+" at "
                    +TimeToString(r[s].time,TIME_DATE|TIME_MINUTES));
            OpenSetup(BIAS_BULLISH,r[j].time,level,r[j].low);
            return(true);
           }
        }
      else
         if(g_bias==BIAS_BEARISH)
           {
            int s = -1;
            for(int i=j+M5_SwingStrength+1; i<copied-M5_SwingStrength; i++)
               if(IsSwingHigh(r,i,M5_SwingStrength))
                 {
                  s = i;
                  break;
                 }
            if(s<0)
               continue;

            double level = r[s].high;
            if(r[j].high > level+penetration && r[j].close < level)
              {
               LogStep("M5 liquidity level detected: swing high "
                       +DoubleToString(level,g_digits)+" at "
                       +TimeToString(r[s].time,TIME_DATE|TIME_MINUTES));
               OpenSetup(BIAS_BEARISH,r[j].time,level,r[j].high);
               return(true);
              }
           }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Start a new setup from a confirmed sweep                         |
//+------------------------------------------------------------------+
void OpenSetup(const ENUM_BIAS dir,const datetime sweep_time,
               const double swept_level,const double sweep_extreme)
  {
   g_setup.dir           = dir;
   g_setup.id            = sweep_time;
   g_setup.sweep_time    = sweep_time;
   g_setup.swept_level   = swept_level;
   g_setup.sweep_extreme = sweep_extreme;
   g_setup.bars_alive    = 0;
   g_setup.mss_done      = false;
   g_setup.mss_level     = 0.0;
   g_setup.mss_time      = 0;
   g_setup.fvg_done      = false;
   g_setup.fvg_low       = 0.0;
   g_setup.fvg_high      = 0.0;
   g_setup.fvg_time      = 0;
   g_setup.retrace_done  = false;
   g_setup.traded        = false;

   g_last_setup  = sweep_time;
   g_hard_reject = false;
   g_last_reject = "";
   g_state       = ST_WAIT_MSS;

   Log(StringFormat("Liquidity sweep detected: %s | swept level %s | sweep extreme %s | candle %s",
                    BiasToString(dir),
                    DoubleToString(swept_level,g_digits),
                    DoubleToString(sweep_extreme,g_digits),
                    TimeToString(sweep_time,TIME_DATE|TIME_MINUTES)));
  }

//+------------------------------------------------------------------+
//| Definition 8: M5 MSS/BOS                                         |
//|                                                                  |
//| The earliest closed bar b after the sweep whose CLOSE breaks the |
//| most recent M5 swing that was already confirmed when b closed.   |
//+------------------------------------------------------------------+
bool DetectM5MSS()
  {
   if(g_setup.dir==BIAS_NONE)
      return(false);

   MqlRates r[];
   int need = (int)MathMax((double)M5_LookbackBars,
                           (double)(MaxSweepAgeBars+MSSSwingSearchBars
                                    +SetupExpirationBars+M5_SwingStrength*2+20));
   int copied = LoadRates(PERIOD_M5,need,r);
   if(copied < M5_SwingStrength*2+10)
      return(false);

   int j = IndexOfTime(r,g_setup.sweep_time);
   if(j<1)
      return(false);

   int search_limit = (int)MathMin((double)(j+MSSSwingSearchBars),
                                   (double)(copied-M5_SwingStrength-1));

   // b runs from the bar right after the sweep towards the newest closed bar
   for(int b=j-1; b>=1; b--)
     {
      int s = -1;
      for(int i=b+M5_SwingStrength+1; i<=search_limit; i++)
        {
         bool hit = (g_setup.dir==BIAS_BULLISH
                     ? IsSwingHigh(r,i,M5_SwingStrength)
                     : IsSwingLow(r,i,M5_SwingStrength));
         if(hit)
           {
            s = i;
            break;
           }
        }
      if(s<0)
         continue;

      bool broken = (g_setup.dir==BIAS_BULLISH
                     ? (r[b].close > r[s].high)
                     : (r[b].close < r[s].low));
      if(!broken)
         continue;

      g_setup.mss_done  = true;
      g_setup.mss_level = (g_setup.dir==BIAS_BULLISH ? r[s].high : r[s].low);
      g_setup.mss_time  = r[b].time;

      Log(StringFormat("M5 MSS/BOS confirmed: %s break of %s by candle closing at %s (%s)",
                       BiasToString(g_setup.dir),
                       DoubleToString(g_setup.mss_level,g_digits),
                       DoubleToString(r[b].close,g_digits),
                       TimeToString(r[b].time,TIME_DATE|TIME_MINUTES)));
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Definition 9: bullish FVG at candle-3 index c                    |
//|   L[c] > H[c+2], gap at least MinimumFVGSize points wide.        |
//+------------------------------------------------------------------+
bool IsBullishFVG(const MqlRates &r[],const int c,double &zlow,double &zhigh)
  {
   zlow  = 0.0;
   zhigh = 0.0;
   if(c<0 || c+2>=ArraySize(r))
      return(false);

   double a_high = r[c+2].high;   // candle 1
   double c_low  = r[c].low;      // candle 3
   if(c_low <= a_high)
      return(false);

   zlow  = a_high;
   zhigh = c_low;
   return((zhigh-zlow) >= Pts(MinimumFVGSize));
  }

//+------------------------------------------------------------------+
//| Definition 10: bearish FVG at candle-3 index c                   |
//|   H[c] < L[c+2], gap at least MinimumFVGSize points wide.        |
//+------------------------------------------------------------------+
bool IsBearishFVG(const MqlRates &r[],const int c,double &zlow,double &zhigh)
  {
   zlow  = 0.0;
   zhigh = 0.0;
   if(c<0 || c+2>=ArraySize(r))
      return(false);

   double a_low  = r[c+2].low;    // candle 1
   double c_high = r[c].high;     // candle 3
   if(c_high >= a_low)
      return(false);

   zlow  = c_high;
   zhigh = a_low;
   return((zhigh-zlow) >= Pts(MinimumFVGSize));
  }

//+------------------------------------------------------------------+
//| Locate the FVG for the current setup - it must have completed    |
//| at or after the MSS break candle.                                |
//+------------------------------------------------------------------+
bool DetectM5FVG()
  {
   if(g_setup.dir==BIAS_NONE || !g_setup.mss_done)
      return(false);

   MqlRates r[];
   int copied = LoadRates(PERIOD_M5,M5_LookbackBars,r);
   if(copied<10)
      return(false);

   int b = IndexOfTime(r,g_setup.mss_time);
   if(b<1)
      return(false);

   double last_close = r[1].close;

   for(int c=1; c<=b && c+2<copied; c++)
     {
      double zlow=0.0, zhigh=0.0;
      bool found = (g_setup.dir==BIAS_BULLISH
                    ? IsBullishFVG(r,c,zlow,zhigh)
                    : IsBearishFVG(r,c,zlow,zhigh));
      if(!found)
         continue;

      // the zone must sit on the correct side of the sweep so the stop stays
      // behind the sweep extreme, and must not already be filled through
      if(g_setup.dir==BIAS_BULLISH)
        {
         if(zlow <= g_setup.sweep_extreme) continue;
         if(last_close <= zlow)            continue;
        }
      else
        {
         if(zhigh >= g_setup.sweep_extreme) continue;
         if(last_close >= zhigh)            continue;
        }

      g_setup.fvg_done = true;
      g_setup.fvg_low  = zlow;
      g_setup.fvg_high = zhigh;
      g_setup.fvg_time = r[c].time;
      g_setup.retrace_done = false;

      Log(StringFormat("M5 FVG detected: %s zone %s - %s (%.0f points, candle 3 at %s)",
                       BiasToString(g_setup.dir),
                       DoubleToString(zlow,g_digits),
                       DoubleToString(zhigh,g_digits),
                       (zhigh-zlow)/g_point,
                       TimeToString(r[c].time,TIME_DATE|TIME_MINUTES)));
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Definitions 11/12: M1 entry confirmation on the last closed bar  |
//|                                                                  |
//| The confirming bar must itself trade inside the zone, close in   |
//| the trade's direction with a real body, close in the far part of |
//| its own range, and close on the correct side of the gap.         |
//+------------------------------------------------------------------+
bool M1Confirms(const MqlRates &r[])
  {
   double o = r[1].open;
   double h = r[1].high;
   double l = r[1].low;
   double c = r[1].close;
   double range = h-l;

   if(range<=0.0)
      return(false);

   // (11b)/(12b) the bar must overlap the zone
   if(!(l<=g_setup.fvg_high && h>=g_setup.fvg_low))
      return(false);

   double min_body  = M1_MinBodyPercent/100.0*range;
   double min_close = M1_MinClosePct/100.0*range;

   if(g_setup.dir==BIAS_BULLISH)
     {
      if(c<=o)                    return(false);   // bullish body
      if((c-o) < min_body)        return(false);   // body large enough
      if((c-l) < min_close)       return(false);   // closes in the upper part
      if(c<=g_setup.fvg_low)      return(false);   // gap floor held
      return(true);
     }

   if(g_setup.dir==BIAS_BEARISH)
     {
      if(c>=o)                    return(false);
      if((o-c) < min_body)        return(false);
      if((h-c) < min_close)       return(false);
      if(c>=g_setup.fvg_high)     return(false);
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Session filter (server time, wrap-around supported)              |
//+------------------------------------------------------------------+
bool InTradingSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);

   int s = TradingSessionStart;
   int e = TradingSessionEnd;
   if(s==e)
      return(true);                     // 24 hours
   if(s<e)
      return(dt.hour>=s && dt.hour<e);
   return(dt.hour>=s || dt.hour<e);     // wraps midnight
  }

//+------------------------------------------------------------------+
//| Daily statistics rebuilt from deal history (restart safe)        |
//+------------------------------------------------------------------+
void UpdateDailyStats(const bool force=false)
  {
   static datetime last_calc = 0;
   datetime now = TimeCurrent();

   if(!force && last_calc!=0 && now>=last_calc && (now-last_calc)<5)
      return;
   last_calc = now;

   MqlDateTime dt;
   TimeToStruct(now,dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day_start = StructToTime(dt);

   if(day_start!=g_day_start)
     {
      g_day_start = day_start;
      LogStep("New trading day: "+TimeToString(day_start,TIME_DATE)
              +" - daily counters reset.");
     }

   int    trades   = 0;
   int    streak   = 0;
   double realized = 0.0;

   if(HistorySelect(day_start,now+1))
     {
      int total = HistoryDealsTotal();
      for(int i=0; i<total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket==0)
            continue;
         if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
            continue;
         if((long)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber)
            continue;
         long type = (long)HistoryDealGetInteger(ticket,DEAL_TYPE);
         if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL)
            continue;

         long entry = (long)HistoryDealGetInteger(ticket,DEAL_ENTRY);
         double pl  = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket,DEAL_SWAP)
                      + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         realized += pl;

         if(entry==DEAL_ENTRY_IN)
            trades++;

         // deals are returned in chronological order, so the streak that
         // survives the loop is the current one
         if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
           {
            if(pl<0.0) streak++;
            else       streak = 0;
           }
        }
     }

   g_trades_today = trades;
   g_loss_streak  = streak;
   g_realized     = realized;

   double floating = 0.0;
   int positions = PositionsTotal();
   for(int i=0; i<positions; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      floating += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_start_bal = balance-realized;
   if(g_day_start_bal<=0.0)
      g_day_start_bal = MathMax(balance,1.0);

   g_daily_pl_pct = (realized+floating)/g_day_start_bal*100.0;
  }

//+------------------------------------------------------------------+
//| Count this EA's open positions                                   |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Trading halt checks - returns "" when trading is allowed         |
//+------------------------------------------------------------------+
string TradingHaltReason()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return("terminal trading disabled");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return("EA trading disabled");
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return("account trading disabled");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return("expert trading disabled on account");

   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY)
      return("symbol trading disabled");

   if(MaxDailyLossPercent>0.0 && g_daily_pl_pct <= -MathAbs(MaxDailyLossPercent))
      return(StringFormat("daily loss limit reached (%.2f%% of %.2f%%)",
                          g_daily_pl_pct,-MathAbs(MaxDailyLossPercent)));
   if(MaxTradesPerDay>0 && g_trades_today>=MaxTradesPerDay)
      return(StringFormat("max trades per day reached (%d)",g_trades_today));
   if(MaxConsecutiveLosses>0 && g_loss_streak>=MaxConsecutiveLosses)
      return(StringFormat("max consecutive losses reached (%d)",g_loss_streak));
   if(MaxOpenPositions>0 && CountOpenPositions()>=MaxOpenPositions)
      return("a position is already open");
   if(!InTradingSession())
      return("outside trading session");

   double sp = SpreadPoints();
   if(sp > MaxSpreadPoints*g_pt_scale)
      return(StringFormat("spread too high (%.0f > %.0f broker points)",
                          sp,MaxSpreadPoints*g_pt_scale));

   return("");
  }

//+------------------------------------------------------------------+
//| Minimum stop distance accepted by the broker                     |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double stops  = (double)g_stops_level*g_point;
   double freeze = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
   double spread = SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double d = MathMax(stops,freeze);
   return(MathMax(d,spread+g_point));
  }

//+------------------------------------------------------------------+
//| Normalize a volume to the broker's step / limits                 |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   if(g_vol_step<=0.0)
      return(0.0);
   lots = MathFloor(lots/g_vol_step+1e-8)*g_vol_step;
   if(lots>g_vol_max)
      lots = g_vol_max;
   if(lots>MaxLotSize)
      lots = MathFloor(MaxLotSize/g_vol_step+1e-8)*g_vol_step;
   return(NormalizeDouble(lots,g_vol_digits));
  }

//+------------------------------------------------------------------+
//| Position size from equity risk and the real stop distance.       |
//| Depends only on equity, RiskPercent and the stop - never on      |
//| previous results.                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(const double entry,const double sl)
  {
   double sl_distance = MathAbs(entry-sl);
   if(sl_distance<=0.0)
     {
      Reject("stop distance is zero",true);
      return(0.0);
     }

   double tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0)
      tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0 || tick_value<=0.0)
     {
      Reject("broker tick size / tick value unavailable",true);
      return(0.0);
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity*RiskPercent/100.0;
   if(risk_money<=0.0)
     {
      Reject("computed risk amount is zero",true);
      return(0.0);
     }

   double loss_per_lot = (sl_distance/tick_size)*tick_value;
   if(loss_per_lot<=0.0)
     {
      Reject("computed loss per lot is zero",true);
      return(0.0);
     }

   double lots = NormalizeLots(risk_money/loss_per_lot);

   if(lots < g_vol_min)
     {
      Reject(StringFormat("risk-correct volume %s is below the broker minimum %s "
                          "(stop %.0f points, risk %.2f%%) - not rounding up",
                          DoubleToString(lots,g_vol_digits),
                          DoubleToString(g_vol_min,g_vol_digits),
                          sl_distance/g_point,RiskPercent),true);
      return(0.0);
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Margin validation                                                |
//+------------------------------------------------------------------+
bool MarginIsSufficient(const ENUM_ORDER_TYPE type,const double lots,const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type,_Symbol,lots,price,margin))
     {
      Reject("OrderCalcMargin failed, error "+IntegerToString(GetLastError()),true);
      return(false);
     }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin>free_margin)
     {
      Reject(StringFormat("insufficient margin (need %.2f, free %.2f)",margin,free_margin),true);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Execute the entry for the current setup                          |
//+------------------------------------------------------------------+
bool OpenTrade()
  {
   // ---- setup integrity -------------------------------------------------
   if(g_setup.dir==BIAS_NONE || !g_setup.mss_done || !g_setup.fvg_done)
     {
      Reject("setup incomplete",true);
      return(false);
     }
   if(g_setup.traded)
     {
      Reject("setup has already produced a trade",true);
      return(false);
     }
   if(g_setup.bars_alive > SetupExpirationBars)
     {
      Reject("setup expired",true);
      return(false);
     }
   if(g_bias!=g_setup.dir)
     {
      Reject("M15 bias no longer matches the setup direction",true);
      return(false);
     }

   // ---- account / market gates -----------------------------------------
   UpdateDailyStats(true);
   string halt = TradingHaltReason();
   if(halt!="")
     {
      Reject(halt);
      return(false);
     }

   long trade_mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(g_setup.dir==BIAS_BULLISH && trade_mode==SYMBOL_TRADE_MODE_SHORTONLY)
     {
      Reject("symbol is short-only",true);
      return(false);
     }
   if(g_setup.dir==BIAS_BEARISH && trade_mode==SYMBOL_TRADE_MODE_LONGONLY)
     {
      Reject("symbol is long-only",true);
      return(false);
     }

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      Reject("no valid market prices");
      return(false);
     }

   bool   is_buy = (g_setup.dir==BIAS_BULLISH);
   double entry  = NormalizeDouble(is_buy ? ask : bid,g_digits);
   double buffer = Pts(SLBufferPoints);
   double sl     = NormalizeDouble(is_buy ? g_setup.sweep_extreme-buffer
                                          : g_setup.sweep_extreme+buffer,g_digits);

   if((is_buy && sl>=entry) || (!is_buy && sl<=entry))
     {
      Reject("stop loss is on the wrong side of the entry",true);
      return(false);
     }

   double risk     = MathAbs(entry-sl);
   double min_dist = MinStopDistance();
   if(risk < min_dist)
     {
      Reject(StringFormat("stop distance %s below the broker minimum %s",
                          DoubleToString(risk,g_digits),
                          DoubleToString(min_dist,g_digits)),true);
      return(false);
     }

   double tp = NormalizeDouble(is_buy ? entry+risk*RiskReward
                                      : entry-risk*RiskReward,g_digits);
   if((is_buy && (tp<=entry || tp-entry<min_dist))
      || (!is_buy && (tp>=entry || entry-tp<min_dist)))
     {
      Reject("take profit distance is invalid",true);
      return(false);
     }

   double lots = CalculateLotSize(entry,sl);
   if(lots<=0.0)
      return(false);
   if(lots<g_vol_min || lots>g_vol_max)
     {
      Reject("volume outside the broker's allowed range",true);
      return(false);
     }
   if(!MarginIsSufficient(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,lots,entry))
      return(false);

   // ---- send ------------------------------------------------------------
   bool sent = (is_buy ? trade.Buy(lots,_Symbol,0.0,sl,tp,TradeComment)
                       : trade.Sell(lots,_Symbol,0.0,sl,tp,TradeComment));
   uint code = trade.ResultRetcode();

   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL
                && code!=TRADE_RETCODE_PLACED))
     {
      Log(StringFormat("%s order FAILED. Retcode=%d (%s) LastError=%d",
                       is_buy ? "BUY" : "SELL",
                       (int)code,trade.ResultRetcodeDescription(),GetLastError()));
      return(false);
     }

   double fill = trade.ResultPrice();
   if(fill<=0.0)
      fill = entry;

   g_setup.traded = true;
   g_state        = ST_TRADE_OPEN;

   Log("-----------------------------------------------------------------");
   Log((is_buy ? "TRADE OPENED: BUY " : "TRADE OPENED: SELL ")+_Symbol);
   Log("  Volume     : "+DoubleToString(lots,g_vol_digits));
   Log("  Entry      : "+DoubleToString(fill,g_digits));
   Log("  Stop loss  : "+DoubleToString(sl,g_digits)
       +"  ("+DoubleToString(risk/g_point,0)+" points)");
   Log("  Take profit: "+DoubleToString(tp,g_digits)
       +"  (R:R "+DoubleToString(RiskReward,2)+")");
   Log(StringFormat("  Risk       : %.2f%% of equity | trade %d of %d today | loss streak %d",
                    RiskPercent,g_trades_today+1,MaxTradesPerDay,g_loss_streak));
   Log("  Setup      : sweep "+TimeToString(g_setup.id,TIME_DATE|TIME_MINUTES)
       +" | FVG "+DoubleToString(g_setup.fvg_low,g_digits)
       +" - "+DoubleToString(g_setup.fvg_high,g_digits));
   Log("-----------------------------------------------------------------");

   return(true);
  }

//+------------------------------------------------------------------+
//| Recover a position that outlived a terminal restart              |
//+------------------------------------------------------------------+
void RecoverOpenPosition()
  {
   if(CountOpenPositions()<=0)
      return;

   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      g_setup.dir    = (type==POSITION_TYPE_BUY ? BIAS_BULLISH : BIAS_BEARISH);
      g_setup.traded = true;
      g_setup.id     = (datetime)PositionGetInteger(POSITION_TIME);
      g_last_setup   = g_setup.id;
      g_state        = ST_TRADE_OPEN;
      Log("Recovered an open position after restart - managing it to its SL/TP.");
      return;
     }
  }

//+------------------------------------------------------------------+
//| Return to setup hunting once the position is gone                |
//+------------------------------------------------------------------+
void SyncPositionState()
  {
   if(g_state==ST_TRADE_OPEN && CountOpenPositions()==0)
     {
      LogStep("Position closed - looking for the next setup.");
      ResetSetup("");
     }
  }

//+------------------------------------------------------------------+
//| Cancel the setup when its premise no longer holds                |
//+------------------------------------------------------------------+
bool SetupInvalidated(const MqlRates &r[])
  {
   if(g_setup.dir==BIAS_NONE || g_setup.traded)
      return(false);

   double c = r[1].close;

   if(g_setup.dir==BIAS_BULLISH && c < g_setup.sweep_extreme)
     {
      ResetSetup("M5 close below the sweep low - sweep failed");
      return(true);
     }
   if(g_setup.dir==BIAS_BEARISH && c > g_setup.sweep_extreme)
     {
      ResetSetup("M5 close above the sweep high - sweep failed");
      return(true);
     }

   if(g_setup.fvg_done)
     {
      if(g_setup.dir==BIAS_BULLISH && c < g_setup.fvg_low)
        {
         ResetSetup("M5 close through the FVG - gap failed");
         return(true);
        }
      if(g_setup.dir==BIAS_BEARISH && c > g_setup.fvg_high)
        {
         ResetSetup("M5 close through the FVG - gap failed");
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| M5 processing: bias, sweep, MSS/BOS, FVG, expiry                 |
//+------------------------------------------------------------------+
void ProcessM5Bar()
  {
   UpdateDailyStats(true);
   SyncPositionState();
   UpdateM15Bias();

   if(g_state==ST_TRADE_OPEN)
      return;

   if(g_setup.dir!=BIAS_NONE && !g_setup.traded)
     {
      g_setup.bars_alive++;
      if(g_setup.bars_alive > SetupExpirationBars)
        {
         ResetSetup(StringFormat("expired after %d M5 bars without an entry",
                                 g_setup.bars_alive));
        }
     }

   if(g_setup.dir!=BIAS_NONE)
     {
      MqlRates r[];
      if(LoadRates(PERIOD_M5,5,r)>=2 && SetupInvalidated(r))
         return;
     }

   if(g_bias==BIAS_NONE)
     {
      if(g_setup.dir==BIAS_NONE)
         g_state = ST_WAIT_BIAS;
      return;
     }

   // 1) liquidity sweep
   if(g_state==ST_WAIT_BIAS || g_state==ST_WAIT_SWEEP)
     {
      if(!DetectM5Sweep())
        {
         g_state = ST_WAIT_SWEEP;
         return;
        }
     }

   // 2) MSS / BOS - never an entry on its own
   if(g_state==ST_WAIT_MSS)
     {
      if(DetectM5MSS())
         g_state = ST_WAIT_FVG;
      else
         return;
     }

   // 3) fair value gap formed at or after the MSS
   if(g_state==ST_WAIT_FVG)
     {
      if(DetectM5FVG())
         g_state = ST_WAIT_RETRACE;
      else
         return;
     }
  }

//+------------------------------------------------------------------+
//| M1 processing: retracement into the zone, then confirmation      |
//+------------------------------------------------------------------+
void ProcessM1Bar()
  {
   if(g_state!=ST_WAIT_RETRACE && g_state!=ST_WAIT_CONFIRM)
      return;
   if(!g_setup.fvg_done || g_setup.traded)
      return;

   MqlRates r[];
   if(LoadRates(PERIOD_M1,5,r)<2)
      return;

   bool overlaps = (r[1].low<=g_setup.fvg_high && r[1].high>=g_setup.fvg_low);

   if(!g_setup.retrace_done && overlaps)
     {
      g_setup.retrace_done = true;
      g_state = ST_WAIT_CONFIRM;
      LogStep(StringFormat("M1 retracement detected: bar %s traded into the %s FVG %s - %s",
                           TimeToString(r[1].time,TIME_DATE|TIME_MINUTES),
                           BiasToString(g_setup.dir),
                           DoubleToString(g_setup.fvg_low,g_digits),
                           DoubleToString(g_setup.fvg_high,g_digits)));
     }

   if(!g_setup.retrace_done)
      return;

   if(!M1Confirms(r))
      return;

   LogStep(StringFormat("M1 entry confirmation detected: %s candle at %s "
                        "(O %s H %s L %s C %s)",
                        BiasToString(g_setup.dir),
                        TimeToString(r[1].time,TIME_DATE|TIME_MINUTES),
                        DoubleToString(r[1].open,g_digits),
                        DoubleToString(r[1].high,g_digits),
                        DoubleToString(r[1].low,g_digits),
                        DoubleToString(r[1].close,g_digits)));

   if(!OpenTrade() && g_hard_reject)
      ResetSetup("entry could not be executed for this setup");
  }

//+------------------------------------------------------------------+
//| Chart status                                                     |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   static datetime last = 0;
   datetime now = TimeCurrent();
   if(now==last)
      return;
   last = now;

   UpdateDailyStats();   // throttled internally, keeps the panel numbers live

   string halt = TradingHaltReason();
   string txt  = "XAUUSD_Scalper_V1  ["+_Symbol+"]\n";
   txt += "-----------------------------------\n";
   txt += "State          : "+StateToString(g_state)+"\n";
   txt += "M15 bias       : "+BiasToString(g_bias)+"\n";
   txt += "Setup          : "+BiasToString(g_setup.dir);
   if(g_setup.dir!=BIAS_NONE)
      txt += StringFormat("  (age %d/%d M5 bars)",g_setup.bars_alive,SetupExpirationBars);
   txt += "\n";
   txt += "Sweep level    : "+(g_setup.dir!=BIAS_NONE
                               ? DoubleToString(g_setup.swept_level,g_digits) : "-")+"\n";
   txt += "MSS/BOS        : "+(g_setup.mss_done
                               ? DoubleToString(g_setup.mss_level,g_digits) : "waiting")+"\n";
   txt += "FVG            : "+(g_setup.fvg_done
                               ? DoubleToString(g_setup.fvg_low,g_digits)+" - "
                                 +DoubleToString(g_setup.fvg_high,g_digits) : "none")+"\n";
   txt += "M1 retrace     : "+(g_setup.retrace_done ? "yes" : "no")+"\n";
   txt += "-----------------------------------\n";
   txt += StringFormat("Spread         : %.0f / %.0f broker pts\n",
                       SpreadPoints(),MaxSpreadPoints*g_pt_scale);
   txt += StringFormat("Trades today   : %d / %d\n",g_trades_today,MaxTradesPerDay);
   txt += StringFormat("Loss streak    : %d / %d\n",g_loss_streak,MaxConsecutiveLosses);
   txt += StringFormat("Daily P/L      : %.2f%%  (limit -%.2f%%)\n",
                       g_daily_pl_pct,MathAbs(MaxDailyLossPercent));
   txt += StringFormat("Risk per trade : %.2f%%   R:R %.2f\n",RiskPercent,RiskReward);
   txt += "Trading        : "+(halt=="" ? "ALLOWED" : "HALTED - "+halt)+"\n";

   Comment(txt);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_init_ok)
      return;

   if(IsNewBar(PERIOD_M5,g_last_m5))
      ProcessM5Bar();

   if(IsNewBar(PERIOD_M1,g_last_m1))
      ProcessM1Bar();

   if(ShowStatusComment)
      UpdateStatusComment();
  }
//+------------------------------------------------------------------+
