//+------------------------------------------------------------------+
//|                                   Aggressive_Algorithm_bot.mq5   |
//|                                                                  |
//|  Strategy sequence:                                              |
//|    H1 Liquidity -> Liquidity Grab -> M15 MSS/BOS -> FVG ->       |
//|    Retracement -> Entry                                          |
//|                                                                  |
//|  NO martingale, NO grid, NO averaging down, NO lot increase      |
//|  after losses, NO revenge/recovery trades.                       |
//+------------------------------------------------------------------+
#property copyright "Aggressive Algorithm Bot"
#property link      "https://github.com/apillanesmark62-cloud/AlgorithmBot"
#property version   "1.00"
#property description "H1 liquidity sweep -> M15 MSS/BOS -> FVG retracement entry."
#property description "Fixed fractional risk. No martingale / grid / averaging."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_EA_STATE
  {
   STATE_WAITING_FOR_LIQUIDITY = 0, // Waiting for liquidity
   STATE_LIQUIDITY_FOUND       = 1, // Liquidity found
   STATE_WAITING_FOR_MSS       = 2, // Waiting for MSS/BOS
   STATE_MSS_CONFIRMED         = 3, // MSS/BOS confirmed
   STATE_FVG_FOUND             = 4, // FVG found
   STATE_WAITING_FOR_RETRACE   = 5, // Waiting for retrace
   STATE_TRADE_OPENED          = 6, // Trade opened
   STATE_SETUP_COMPLETE        = 7  // Setup complete
  };

enum ENUM_SETUP_DIR
  {
   SETUP_NONE    =  0, // None
   SETUP_BULLISH =  1, // Bullish
   SETUP_BEARISH = -1  // Bearish
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Structure ==="
input int    H1_SwingStrength        = 3;      // H1 swing strength (bars each side)
input int    H1_LookbackBars         = 100;    // H1 lookback bars
input int    M15_SwingStrength       = 2;      // M15 swing strength (bars each side)
input int    M15_LookbackBars        = 100;    // M15 lookback bars

input group "=== Liquidity ==="
input int    MaxSweepAgeBars         = 30;     // Max sweep age (H1 bars)
input int    SetupExpirationBars     = 16;     // Setup expiration (M15 bars)

input group "=== Fair Value Gap ==="
input double MinFVGPoints            = 20;     // Minimum FVG size (points)
input bool   UseFVG50Entry           = false;  // Enter at 50% of the FVG
input bool   RequireEntryConfirmation= false;  // Require M15 confirmation candle

input group "=== Risk ==="
input double RiskPercent             = 1.0;    // Risk per trade (% of equity)
input double RiskReward              = 2.0;    // Reward : Risk ratio
input double SL_BufferPoints         = 20;     // Stop loss buffer beyond sweep (points)
input double MaxLotSize              = 1.00;   // Maximum lot size

input group "=== Limits ==="
input int    MaxTradesPerDay         = 5;      // Max trades per day
input int    MaxOpenPositions        = 1;      // Max simultaneous positions
input double MaxDailyLossPercent     = 3.0;    // Max daily loss (%)
input int    MaxSpreadPoints         = 50;     // Max allowed spread (points)

input group "=== Sessions (BROKER / SERVER TIME!) ==="
input bool   UseLondonSession        = true;   // Trade London session
input int    LondonStartHour         = 8;      // London start hour (server time)
input int    LondonEndHour           = 17;     // London end hour (server time)
input bool   UseNewYorkSession       = true;   // Trade New York session
input int    NewYorkStartHour        = 13;     // New York start hour (server time)
input int    NewYorkEndHour          = 22;     // New York end hour (server time)
input bool   UseAsianSession         = false;  // Trade Asian session
input int    AsianStartHour          = 0;      // Asian start hour (server time)
input int    AsianEndHour            = 8;      // Asian end hour (server time)

input group "=== Display ==="
input bool   ShowDebugObjects        = true;   // Draw structure objects
input bool   ShowDashboard           = true;   // Show on-chart dashboard

input group "=== Execution ==="
input long   MagicNumber             = 20250816; // Magic number
input int    MaxSlippagePoints       = 20;       // Max deviation (points)
input string TradeComment            = "AggAlgoBot"; // Trade comment

//+------------------------------------------------------------------+
//| Setup container                                                  |
//+------------------------------------------------------------------+
struct SetupInfo
  {
   ENUM_SETUP_DIR    dir;             // direction of the setup
   datetime          setup_id;        // unique id = sweep bar time
   double            swept_level;     // H1 swing level that was taken out
   double            sweep_extreme;   // SweepLow (bull) / SweepHigh (bear)
   datetime          sweep_time;      // H1 bar time of the sweep candle
   int               bars_alive;      // age in M15 bars
   bool              mss_confirmed;   // MSS/BOS confirmed
   double            mss_level;       // broken M15 swing level
   datetime          mss_time;        // M15 bar time of the breaking candle
   bool              fvg_valid;       // FVG located
   double            fvg_low;         // FVG lower boundary
   double            fvg_high;        // FVG upper boundary
   datetime          fvg_time;        // time of candle C of the FVG
   bool              entry_confirmed; // confirmation candle seen
   bool              traded;          // setup already produced a trade
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         trade;

SetupInfo      g_setup;
ENUM_EA_STATE  g_state          = STATE_WAITING_FOR_LIQUIDITY;

datetime       g_last_bar_time  = 0;      // last processed M15 bar
datetime       g_last_setup_id  = 0;      // last consumed sweep (duplicate guard)
datetime       g_day_start      = 0;      // start of the current trading day

double         g_point          = 0.0;
int            g_digits         = 0;
double         g_tick_size      = 0.0;
double         g_tick_value     = 0.0;
double         g_vol_min        = 0.0;
double         g_vol_max        = 0.0;
double         g_vol_step       = 0.0;
int            g_vol_digits     = 2;
int            g_stops_level    = 0;

int            g_trades_today   = 0;
double         g_realized_today = 0.0;
double         g_daily_pl_pct   = 0.0;
double         g_day_start_bal  = 0.0;

string         g_prefix         = "AAB_";
string         g_dash_prefix    = "AAB_DASH_";
datetime       g_last_dash_time = 0;
string         g_block_reason   = "";
bool           g_init_ok        = false;

bool           g_entry_logged   = false;  // "price entered FVG" printed once
datetime       g_stats_time     = 0;      // last daily statistics refresh
string         g_last_reject    = "";     // throttling of repeated rejections
datetime       g_last_reject_tm = 0;
bool           g_hard_reject    = false;  // rejection that will not resolve itself

//+------------------------------------------------------------------+
//| Helper: state to text                                            |
//+------------------------------------------------------------------+
string StateToString(const ENUM_EA_STATE s)
  {
   switch(s)
     {
      case STATE_WAITING_FOR_LIQUIDITY: return("WAITING_FOR_LIQUIDITY");
      case STATE_LIQUIDITY_FOUND:       return("LIQUIDITY_FOUND");
      case STATE_WAITING_FOR_MSS:       return("WAITING_FOR_MSS");
      case STATE_MSS_CONFIRMED:         return("MSS_CONFIRMED");
      case STATE_FVG_FOUND:             return("FVG_FOUND");
      case STATE_WAITING_FOR_RETRACE:   return("WAITING_FOR_RETRACE");
      case STATE_TRADE_OPENED:          return("TRADE_OPENED");
      case STATE_SETUP_COMPLETE:        return("SETUP_COMPLETE");
     }
   return("UNKNOWN");
  }

string DirToString(const ENUM_SETUP_DIR d)
  {
   if(d==SETUP_BULLISH) return("BULLISH");
   if(d==SETUP_BEARISH) return("BEARISH");
   return("NONE");
  }

void Log(const string msg)
  {
   Print(msg);
  }

//+------------------------------------------------------------------+
//| Rejection logging - price can sit inside an FVG for many ticks,   |
//| so identical rejections are printed at most once every 5 minutes. |
//+------------------------------------------------------------------+
void LogRejection(const string msg,const bool hard=false)
  {
   if(hard)
      g_hard_reject = true;

   datetime now = TimeCurrent();
   if(msg==g_last_reject && (now-g_last_reject_tm)<300)
      return;

   g_last_reject    = msg;
   g_last_reject_tm = now;
   Print(msg);
  }

//+------------------------------------------------------------------+
//| Volume digits from the volume step                                |
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
   g_point      = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits     = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   g_vol_min    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_vol_max    = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_vol_step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_stops_level= (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_vol_digits = VolumeDigits(g_vol_step);

   if(g_point<=0.0 || g_tick_size<=0.0 || g_vol_step<=0.0)
     {
      Log("Init error: invalid symbol properties (point/tick size/volume step).");
      return(false);
     }
   if(g_tick_value<=0.0)
     {
      Log("Init warning: SYMBOL_TRADE_TICK_VALUE is zero - lot sizing may fail.");
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Reset the current setup                                          |
//+------------------------------------------------------------------+
void ResetSetup(const string reason)
  {
   if(g_setup.dir!=SETUP_NONE && reason!="")
      Log(StringFormat("Setup reset (%s %s): %s",
                       DirToString(g_setup.dir),
                       TimeToString(g_setup.setup_id,TIME_DATE|TIME_MINUTES),
                       reason));

   if(ShowDebugObjects && g_setup.setup_id>0)
      DeleteSetupObjects(g_setup.setup_id);

   g_setup.dir             = SETUP_NONE;
   g_setup.setup_id        = 0;
   g_setup.swept_level     = 0.0;
   g_setup.sweep_extreme   = 0.0;
   g_setup.sweep_time      = 0;
   g_setup.bars_alive      = 0;
   g_setup.mss_confirmed   = false;
   g_setup.mss_level       = 0.0;
   g_setup.mss_time        = 0;
   g_setup.fvg_valid       = false;
   g_setup.fvg_low         = 0.0;
   g_setup.fvg_high        = 0.0;
   g_setup.fvg_time        = 0;
   g_setup.entry_confirmed = false;
   g_setup.traded          = false;

   g_entry_logged = false;
   g_hard_reject  = false;
   g_last_reject  = "";

   g_state = STATE_WAITING_FOR_LIQUIDITY;
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!RefreshSymbolInfo())
      return(INIT_FAILED);

   if(H1_SwingStrength<1 || M15_SwingStrength<1)
     {
      Log("Init error: swing strength must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(H1_LookbackBars < (H1_SwingStrength*2+5) || M15_LookbackBars < (M15_SwingStrength*2+5))
     {
      Log("Init error: lookback bars too small for the configured swing strength.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(RiskPercent<=0.0 || RiskReward<=0.0)
     {
      Log("Init error: RiskPercent and RiskReward must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(MaxLotSize<=0.0)
     {
      Log("Init error: MaxLotSize must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(SetupExpirationBars<1 || MaxSweepAgeBars<1)
     {
      Log("Init error: SetupExpirationBars and MaxSweepAgeBars must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints((ulong)MathMax(1,MaxSlippagePoints));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   ResetSetup("");
   g_last_bar_time = 0;
   g_last_dash_time= 0;

   UpdateDailyStats();
   RestoreState();

   g_init_ok = true;

   Log("---------------------------------------------------------------");
   Log("Aggressive_Algorithm_bot initialised on "+_Symbol);
   Log("Point="+DoubleToString(g_point,g_digits)
       +"  Digits="+IntegerToString(g_digits)
       +"  StopsLevel="+IntegerToString(g_stops_level));
   Log("Volume: min="+DoubleToString(g_vol_min,g_vol_digits)
       +"  max="+DoubleToString(g_vol_max,g_vol_digits)
       +"  step="+DoubleToString(g_vol_step,g_vol_digits));
   Log("Session hours are BROKER/SERVER time - adjust them to your broker's timezone.");
   Log("Current server time: "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES));
   Log("---------------------------------------------------------------");

   if(ShowDashboard)
      UpdateDashboard();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0,g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| New bar detection                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol,PERIOD_M15,0);
   if(t==0)
      return(false);
   if(t==g_last_bar_time)
      return(false);
   g_last_bar_time = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Swing helpers (arrays must be series ordered)                     |
//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[],const int i,const int strength)
  {
   int total = ArraySize(r);
   if(i-strength<0 || i+strength>=total)
      return(false);
   double h = r[i].high;
   for(int k=1; k<=strength; k++)
     {
      if(r[i+k].high >= h) return(false);   // older bars
      if(r[i-k].high >= h) return(false);   // newer bars
     }
   return(true);
  }

bool IsSwingLow(const MqlRates &r[],const int i,const int strength)
  {
   int total = ArraySize(r);
   if(i-strength<0 || i+strength>=total)
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
//| Load rates of a timeframe (series ordered, index 0 = current)     |
//+------------------------------------------------------------------+
int LoadRates(const ENUM_TIMEFRAMES tf,const int count,MqlRates &r[])
  {
   ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol,tf,0,count,r);
   if(copied<=0)
      return(0);
   return(copied);
  }

//+------------------------------------------------------------------+
//| How many M15 bars must be available to cover the oldest sweep     |
//| that is still tradable (MaxSweepAgeBars is expressed in H1 bars). |
//+------------------------------------------------------------------+
int M15BarsNeeded()
  {
   int span = MaxSweepAgeBars*4 + SetupExpirationBars + M15_SwingStrength*2 + 10;
   return((int)MathMax((double)M15_LookbackBars,(double)span));
  }

//+------------------------------------------------------------------+
//| FindH1SwingHigh: most recent confirmed swing high strictly older  |
//| than bar index 'before_index'. Returns index or -1.               |
//+------------------------------------------------------------------+
int FindH1SwingHigh(const MqlRates &r[],const int before_index,const int strength)
  {
   int total = ArraySize(r);
   // the swing must be fully confirmed before bar 'before_index' closes:
   // its confirming bars (i-1 .. i-strength) must all be older than before_index
   for(int i=before_index+strength+1; i<total-strength; i++)
      if(IsSwingHigh(r,i,strength))
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| FindH1SwingLow: mirror of FindH1SwingHigh                         |
//+------------------------------------------------------------------+
int FindH1SwingLow(const MqlRates &r[],const int before_index,const int strength)
  {
   int total = ArraySize(r);
   for(int i=before_index+strength+1; i<total-strength; i++)
      if(IsSwingLow(r,i,strength))
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Detect a liquidity grab on H1 closed candles                     |
//| Returns true and fills the setup on success.                     |
//+------------------------------------------------------------------+
bool DetectLiquidityGrab()
  {
   MqlRates r[];
   int need = (int)MathMax((double)H1_LookbackBars,
                           (double)(MaxSweepAgeBars+H1_SwingStrength*2+10));
   int copied = LoadRates(PERIOD_H1,need,r);
   if(copied < H1_SwingStrength*2+5)
      return(false);

   int max_j = (int)MathMin((double)MaxSweepAgeBars,
                            (double)(copied-(H1_SwingStrength*2+3)));

   // j = 1 is the last CLOSED H1 candle; scan from newest to oldest and
   // take the most recent valid sweep.
   for(int j=1; j<=max_j; j++)
     {
      datetime bar_time = r[j].time;
      if(bar_time <= g_last_setup_id)   // already consumed
         break;

      // ---- bullish sweep: wick below a confirmed swing low, close back above
      int sl_idx = FindH1SwingLow(r,j,H1_SwingStrength);
      if(sl_idx>0)
        {
         double swing_low = r[sl_idx].low;
         if(r[j].low < swing_low && r[j].close > swing_low)
           {
            CreateSetup(SETUP_BULLISH,bar_time,swing_low,r[j].low);
            return(true);
           }
        }

      // ---- bearish sweep: wick above a confirmed swing high, close back below
      int sh_idx = FindH1SwingHigh(r,j,H1_SwingStrength);
      if(sh_idx>0)
        {
         double swing_high = r[sh_idx].high;
         if(r[j].high > swing_high && r[j].close < swing_high)
           {
            CreateSetup(SETUP_BEARISH,bar_time,swing_high,r[j].high);
            return(true);
           }
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Create a new setup from a detected sweep                         |
//+------------------------------------------------------------------+
void CreateSetup(const ENUM_SETUP_DIR dir,const datetime sweep_time,
                 const double swept_level,const double sweep_extreme)
  {
   g_setup.dir             = dir;
   g_setup.setup_id        = sweep_time;
   g_setup.sweep_time      = sweep_time;
   g_setup.swept_level     = swept_level;
   g_setup.sweep_extreme   = sweep_extreme;
   g_setup.bars_alive      = 0;
   g_setup.mss_confirmed   = false;
   g_setup.mss_level       = 0.0;
   g_setup.mss_time        = 0;
   g_setup.fvg_valid       = false;
   g_setup.fvg_low         = 0.0;
   g_setup.fvg_high        = 0.0;
   g_setup.fvg_time        = 0;
   g_setup.entry_confirmed = false;
   g_setup.traded          = false;

   g_entry_logged  = false;
   g_hard_reject   = false;
   g_last_reject   = "";

   g_last_setup_id = sweep_time;
   g_state         = STATE_LIQUIDITY_FOUND;

   Log(StringFormat("%s liquidity sweep detected at %s (swept H1 level %s, wick extreme %s) on H1 candle %s",
                    DirToString(dir),
                    DoubleToString(swept_level,g_digits),
                    DoubleToString(swept_level,g_digits),
                    DoubleToString(sweep_extreme,g_digits),
                    TimeToString(sweep_time,TIME_DATE|TIME_MINUTES)));

   if(ShowDebugObjects)
      DrawLiquidity();
  }

//+------------------------------------------------------------------+
//| M15 MSS/BOS detection (bullish = DetectMSS on swing highs)       |
//+------------------------------------------------------------------+
bool DetectMSS()
  {
   if(g_setup.dir==SETUP_BULLISH)
      return(DetectBullishMSS());
   if(g_setup.dir==SETUP_BEARISH)
      return(DetectBearishMSS());
   return(false);
  }

//+------------------------------------------------------------------+
//| DetectBOS - alias kept for readability of the strategy sequence   |
//+------------------------------------------------------------------+
bool DetectBOS()
  {
   return(DetectMSS());
  }

//+------------------------------------------------------------------+
//| Index of the newest M15 bar whose time is <= t, or -1            |
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
//| Bullish MSS: close above the most recent confirmed M15 swing high |
//| that formed after the liquidity grab.                             |
//+------------------------------------------------------------------+
bool DetectBullishMSS()
  {
   MqlRates r[];
   int copied = LoadRates(PERIOD_M15,M15BarsNeeded(),r);
   if(copied < M15_SwingStrength*2+5)
      return(false);

   int anchor = IndexOfTime(r,g_setup.sweep_time);
   if(anchor<0)
      return(false);

   int b_start = (int)MathMin((double)(anchor-1),(double)(copied-1));

   // walk forward in time (decreasing index) over closed bars only
   for(int b=b_start; b>=1; b--)
     {
      // most recent confirmed swing high older than bar b and not older than the sweep
      int s = -1;
      for(int i=b+M15_SwingStrength+1; i<=anchor && i<copied-M15_SwingStrength; i++)
        {
         if(IsSwingHigh(r,i,M15_SwingStrength))
           {
            s = i;
            break;
           }
        }
      if(s<0)
         continue;

      if(r[b].close > r[s].high)
        {
         g_setup.mss_confirmed = true;
         g_setup.mss_level     = r[s].high;
         g_setup.mss_time      = r[b].time;
         Log(StringFormat("Bullish MSS confirmed at %s (break candle %s)",
                          DoubleToString(g_setup.mss_level,g_digits),
                          TimeToString(g_setup.mss_time,TIME_DATE|TIME_MINUTES)));
         if(ShowDebugObjects)
            DrawMSS();
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Bearish MSS: close below the most recent confirmed M15 swing low  |
//+------------------------------------------------------------------+
bool DetectBearishMSS()
  {
   MqlRates r[];
   int copied = LoadRates(PERIOD_M15,M15BarsNeeded(),r);
   if(copied < M15_SwingStrength*2+5)
      return(false);

   int anchor = IndexOfTime(r,g_setup.sweep_time);
   if(anchor<0)
      return(false);

   int b_start = (int)MathMin((double)(anchor-1),(double)(copied-1));

   for(int b=b_start; b>=1; b--)
     {
      int s = -1;
      for(int i=b+M15_SwingStrength+1; i<=anchor && i<copied-M15_SwingStrength; i++)
        {
         if(IsSwingLow(r,i,M15_SwingStrength))
           {
            s = i;
            break;
           }
        }
      if(s<0)
         continue;

      if(r[b].close < r[s].low)
        {
         g_setup.mss_confirmed = true;
         g_setup.mss_level     = r[s].low;
         g_setup.mss_time      = r[b].time;
         Log(StringFormat("Bearish MSS confirmed at %s (break candle %s)",
                          DoubleToString(g_setup.mss_level,g_digits),
                          TimeToString(g_setup.mss_time,TIME_DATE|TIME_MINUTES)));
         if(ShowDebugObjects)
            DrawMSS();
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Bullish FVG: candle A high < candle C low                        |
//| c_index is the index of candle C (the newest of the three).      |
//+------------------------------------------------------------------+
bool DetectBullishFVG(const MqlRates &r[],const int c_index,double &fvg_low,double &fvg_high)
  {
   fvg_low  = 0.0;
   fvg_high = 0.0;
   if(c_index+2>=ArraySize(r))
      return(false);

   double a_high = r[c_index+2].high;
   double c_low  = r[c_index].low;
   if(a_high >= c_low)
      return(false);

   fvg_low  = a_high;
   fvg_high = c_low;
   return((fvg_high-fvg_low) >= MinFVGPoints*g_point);
  }

//+------------------------------------------------------------------+
//| Bearish FVG: candle A low > candle C high                        |
//+------------------------------------------------------------------+
bool DetectBearishFVG(const MqlRates &r[],const int c_index,double &fvg_low,double &fvg_high)
  {
   fvg_low  = 0.0;
   fvg_high = 0.0;
   if(c_index+2>=ArraySize(r))
      return(false);

   double a_low  = r[c_index+2].low;
   double c_high = r[c_index].high;
   if(a_low <= c_high)
      return(false);

   fvg_low  = c_high;
   fvg_high = a_low;
   return((fvg_high-fvg_low) >= MinFVGPoints*g_point);
  }

//+------------------------------------------------------------------+
//| Locate the FVG to trade for the current setup                    |
//| Preference: newest FVG formed after MSS, else after the sweep.   |
//+------------------------------------------------------------------+
bool FindSetupFVG()
  {
   if(g_setup.dir==SETUP_NONE)
      return(false);

   MqlRates r[];
   int copied = LoadRates(PERIOD_M15,M15BarsNeeded(),r);
   if(copied<5)
      return(false);

   double last_close = r[1].close;

   for(int pass=0; pass<2; pass++)
     {
      datetime min_time = (pass==0 ? g_setup.mss_time : g_setup.sweep_time);
      if(pass==0 && !g_setup.mss_confirmed)
         continue;
      if(min_time<=0)
         continue;

      // newest first: index 1 is the last closed candle
      for(int c=1; c+2<copied; c++)
        {
         if(r[c].time < min_time)
            break;

         double low=0.0, high=0.0;
         bool found = false;
         if(g_setup.dir==SETUP_BULLISH)
            found = DetectBullishFVG(r,c,low,high);
         else
            found = DetectBearishFVG(r,c,low,high);
         if(!found)
            continue;

         // sanity: the FVG must sit on the correct side of the sweep so that
         // the stop loss stays behind the sweep extreme
         if(g_setup.dir==SETUP_BULLISH)
           {
            if(low <= g_setup.sweep_extreme) continue;
            if(last_close <= low)            continue; // already traded through
           }
         else
           {
            if(high >= g_setup.sweep_extreme) continue;
            if(last_close >= high)            continue;
           }

         g_setup.fvg_valid = true;
         g_setup.fvg_low   = low;
         g_setup.fvg_high  = high;
         g_setup.fvg_time  = r[c].time;
         g_setup.entry_confirmed = false;
         g_entry_logged          = false;

         Log(StringFormat("%s FVG detected: %s - %s (size %.0f points, candle %s)",
                          DirToString(g_setup.dir),
                          DoubleToString(low,g_digits),
                          DoubleToString(high,g_digits),
                          (high-low)/g_point,
                          TimeToString(g_setup.fvg_time,TIME_DATE|TIME_MINUTES)));
         if(ShowDebugObjects)
            DrawFVG();
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0 || g_point<=0.0)
      return(1e9);
   return((ask-bid)/g_point);
  }

bool CheckSpread()
  {
   double sp = CurrentSpreadPoints();
   return(sp <= (double)MaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Session filter (server time)                                     |
//+------------------------------------------------------------------+
bool HourInRange(const int hour,const int start,const int end)
  {
   int s = start % 24;
   int e = end   % 24;
   if(s<0) s += 24;
   if(e<0) e += 24;
   if(s==e)
      return(true);            // full day
   if(s<e)
      return(hour>=s && hour<e);
   return(hour>=s || hour<e);  // wraps over midnight
  }

bool CheckTradingSession()
  {
   if(!UseLondonSession && !UseNewYorkSession && !UseAsianSession)
      return(true);            // no session filter configured

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);

   if(UseLondonSession  && HourInRange(dt.hour,LondonStartHour,LondonEndHour))   return(true);
   if(UseNewYorkSession && HourInRange(dt.hour,NewYorkStartHour,NewYorkEndHour)) return(true);
   if(UseAsianSession   && HourInRange(dt.hour,AsianStartHour,AsianEndHour))     return(true);

   return(false);
  }

//+------------------------------------------------------------------+
//| Daily statistics (survives restarts - rebuilt from history)      |
//+------------------------------------------------------------------+
void UpdateDailyStats(const bool force=false)
  {
   datetime now = TimeCurrent();

   // the history scan is not cheap - refresh it at most every 5 seconds
   // unless a caller explicitly needs fresh numbers
   if(!force && g_stats_time!=0 && (now-g_stats_time)<5 && now>=g_stats_time)
      return;
   g_stats_time = now;

   MqlDateTime dt;
   TimeToStruct(now,dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day_start = StructToTime(dt);

   if(day_start!=g_day_start)
     {
      g_day_start = day_start;
      Log("New trading day started: "+TimeToString(day_start,TIME_DATE));
     }

   int    trades   = 0;
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
         if((long)HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN)
            trades++;
         realized += HistoryDealGetDouble(ticket,DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket,DEAL_SWAP)
                     + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
        }
     }

   g_trades_today   = trades;
   g_realized_today = realized;

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
      floating += PositionGetDouble(POSITION_PROFIT)
                  + PositionGetDouble(POSITION_SWAP);
     }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_start_bal = balance - realized;
   if(g_day_start_bal<=0.0)
      g_day_start_bal = MathMax(balance,1.0);

   g_daily_pl_pct = (realized+floating)/g_day_start_bal*100.0;
  }

//+------------------------------------------------------------------+
//| Daily loss guard                                                 |
//+------------------------------------------------------------------+
bool CheckDailyLoss()
  {
   if(MaxDailyLossPercent<=0.0)
      return(true);
   return(g_daily_pl_pct > -MathAbs(MaxDailyLossPercent));
  }

//+------------------------------------------------------------------+
//| Count open positions belonging to this EA                        |
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
//| Stop loss / take profit                                          |
//+------------------------------------------------------------------+
double CalculateStopLoss(const ENUM_SETUP_DIR dir)
  {
   double buffer = SL_BufferPoints*g_point;
   if(dir==SETUP_BULLISH)
      return(NormalizeDouble(g_setup.sweep_extreme-buffer,g_digits));
   if(dir==SETUP_BEARISH)
      return(NormalizeDouble(g_setup.sweep_extreme+buffer,g_digits));
   return(0.0);
  }

double CalculateTakeProfit(const ENUM_SETUP_DIR dir,const double entry,const double sl)
  {
   if(dir==SETUP_BULLISH)
     {
      double risk = entry-sl;
      if(risk<=0.0) return(0.0);
      return(NormalizeDouble(entry+risk*RiskReward,g_digits));
     }
   if(dir==SETUP_BEARISH)
     {
      double risk = sl-entry;
      if(risk<=0.0) return(0.0);
      return(NormalizeDouble(entry-risk*RiskReward,g_digits));
     }
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Minimum stop distance in price units                             |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   double dist = (double)g_stops_level*g_point;
   double freeze = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
   double spread = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double min_d = MathMax(dist,freeze);
   // brokers with a zero stops level still need at least the spread + 1 point
   return(MathMax(min_d,spread+g_point));
  }

//+------------------------------------------------------------------+
//| Normalize a lot size to the symbol constraints                   |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   if(g_vol_step<=0.0)
      return(0.0);
   lots = MathFloor(lots/g_vol_step+1e-8)*g_vol_step;
   lots = NormalizeDouble(lots,g_vol_digits);
   if(lots>g_vol_max)  lots = g_vol_max;
   if(lots>MaxLotSize) lots = MathFloor(MaxLotSize/g_vol_step+1e-8)*g_vol_step;
   lots = NormalizeDouble(lots,g_vol_digits);
   return(lots);
  }

//+------------------------------------------------------------------+
//| Position sizing from equity risk and stop distance               |
//| Returns 0.0 when a valid size cannot be produced.                |
//+------------------------------------------------------------------+
double CalculateLotSize(const double entry,const double sl)
  {
   double sl_distance = MathAbs(entry-sl);
   if(sl_distance<=0.0)
     {
      Log("Lot sizing failed: stop distance is zero.");
      return(0.0);
     }

   double tick_size  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0)
      tick_value = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0 || tick_value<=0.0)
     {
      Log("Lot sizing failed: invalid tick size / tick value.");
      return(0.0);
     }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity*RiskPercent/100.0;
   if(risk_money<=0.0)
     {
      Log("Lot sizing failed: risk amount is zero.");
      return(0.0);
     }

   double loss_per_lot = (sl_distance/tick_size)*tick_value;
   if(loss_per_lot<=0.0)
     {
      Log("Lot sizing failed: loss per lot is zero.");
      return(0.0);
     }

   double lots = risk_money/loss_per_lot;
   lots = NormalizeLots(lots);
   // NEVER scale the size with previous results - fixed fractional risk only

   if(lots < g_vol_min)
     {
      LogRejection("Trade rejected: required lot "+DoubleToString(lots,g_vol_digits)
                   +" is below the broker minimum "+DoubleToString(g_vol_min,g_vol_digits)
                   +" for "+DoubleToString(RiskPercent,2)+"% risk (stop distance "
                   +DoubleToString(sl_distance/g_point,0)+" points).",true);
      return(0.0);
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Trading permission checks                                        |
//+------------------------------------------------------------------+
bool TradingAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_block_reason = "terminal trading disabled";
      return(false);
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_block_reason = "EA trading disabled";
      return(false);
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      g_block_reason = "account trading disabled";
      return(false);
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      g_block_reason = "expert trading disabled on account";
      return(false);
     }
   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      g_block_reason = "symbol trading disabled";
      return(false);
     }
   g_block_reason = "";
   return(true);
  }

bool DirectionAllowedBySymbol(const ENUM_SETUP_DIR dir)
  {
   long mode = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(dir==SETUP_BULLISH && mode==SYMBOL_TRADE_MODE_SHORTONLY)
      return(false);
   if(dir==SETUP_BEARISH && mode==SYMBOL_TRADE_MODE_LONGONLY)
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Margin check                                                     |
//+------------------------------------------------------------------+
bool HasEnoughMargin(const ENUM_ORDER_TYPE type,const double lots,const double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type,_Symbol,lots,price,margin))
     {
      Log("Margin check failed: OrderCalcMargin error "+IntegerToString(GetLastError()));
      return(false);
     }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > free_margin)
     {
      LogRejection(StringFormat("Trade rejected: insufficient margin (required %.2f, free %.2f).",
                                margin,free_margin),true);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Pre-trade validation shared by BUY and SELL                      |
//+------------------------------------------------------------------+
bool ValidateTradeConditions()
  {
   if(g_setup.dir==SETUP_NONE)
     {
      LogRejection("Trade rejected: no setup.",true);
      return(false);
     }
   if(g_setup.traded)
     {
      LogRejection("Trade rejected: setup already traded.",true);
      return(false);
     }
   if(!g_setup.mss_confirmed || !g_setup.fvg_valid)
     {
      LogRejection("Trade rejected: required information is missing (MSS/FVG).",true);
      return(false);
     }
   if(g_setup.bars_alive > SetupExpirationBars)
     {
      LogRejection("Trade rejected: setup expired.",true);
      return(false);
     }
   if(!TradingAllowed())
     {
      LogRejection("Trade rejected: "+g_block_reason+".");
      return(false);
     }
   if(!DirectionAllowedBySymbol(g_setup.dir))
     {
      LogRejection("Trade rejected: symbol does not allow this direction.",true);
      return(false);
     }
   if(!CheckTradingSession())
     {
      LogRejection("Trade rejected: outside of the configured trading sessions.");
      return(false);
     }
   if(!CheckSpread())
     {
      LogRejection(StringFormat("Trade rejected: spread too high (%.0f > %d points).",
                                CurrentSpreadPoints(),MaxSpreadPoints));
      return(false);
     }
   UpdateDailyStats();
   if(!CheckDailyLoss())
     {
      LogRejection(StringFormat("Trade rejected: daily loss limit reached (%.2f%%).",g_daily_pl_pct));
      return(false);
     }
   if(MaxTradesPerDay>0 && g_trades_today>=MaxTradesPerDay)
     {
      LogRejection(StringFormat("Trade rejected: max trades per day reached (%d).",g_trades_today));
      return(false);
     }
   if(MaxOpenPositions>0 && CountOpenPositions()>=MaxOpenPositions)
     {
      LogRejection("Trade rejected: maximum open positions reached.");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Open a BUY position                                              |
//+------------------------------------------------------------------+
bool OpenBuy()
  {
   if(!ValidateTradeConditions())
      return(false);

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      Log("Trade rejected: no valid prices.");
      return(false);
     }

   double entry = NormalizeDouble(ask,g_digits);
   double sl    = CalculateStopLoss(SETUP_BULLISH);
   if(sl<=0.0 || sl>=entry)
     {
      LogRejection("Trade rejected: invalid stop distance (SL is not below entry).",true);
      return(false);
     }

   double min_dist = MinStopDistance();
   if((entry-sl) < min_dist)
     {
      LogRejection("Trade rejected: invalid stop distance ("+DoubleToString(entry-sl,g_digits)
                   +", broker minimum "+DoubleToString(min_dist,g_digits)+").",true);
      return(false);
     }

   double tp = CalculateTakeProfit(SETUP_BULLISH,entry,sl);
   if(tp<=entry || (tp-entry) < min_dist)
     {
      LogRejection("Trade rejected: invalid take profit distance.",true);
      return(false);
     }

   double lots = CalculateLotSize(entry,sl);
   if(lots<=0.0)
      return(false);

   if(!HasEnoughMargin(ORDER_TYPE_BUY,lots,entry))
      return(false);

   if(!trade.Buy(lots,_Symbol,0.0,sl,tp,TradeComment))
     {
      Log(StringFormat("BUY order failed. Retcode=%d (%s) Error=%d",
                       (int)trade.ResultRetcode(),trade.ResultRetcodeDescription(),GetLastError()));
      return(false);
     }

   uint code = trade.ResultRetcode();
   if(code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL && code!=TRADE_RETCODE_PLACED)
     {
      Log(StringFormat("BUY rejected by server. Retcode=%d (%s)",(int)code,trade.ResultRetcodeDescription()));
      return(false);
     }

   double fill = trade.ResultPrice();
   if(fill<=0.0)
      fill = entry;

   Log("BUY opened");
   Log("  Volume: "+DoubleToString(lots,g_vol_digits)+"  Entry: "+DoubleToString(fill,g_digits));
   Log("  SL: "+DoubleToString(sl,g_digits));
   Log("  TP: "+DoubleToString(tp,g_digits));
   Log(StringFormat("  Risk: %.2f%%  R:R %.2f  Setup: %s",
                    RiskPercent,RiskReward,TimeToString(g_setup.setup_id,TIME_DATE|TIME_MINUTES)));

   g_setup.traded = true;
   g_state        = STATE_TRADE_OPENED;

   if(ShowDebugObjects)
      DrawTrade(fill,sl,tp);

   return(true);
  }

//+------------------------------------------------------------------+
//| Open a SELL position                                             |
//+------------------------------------------------------------------+
bool OpenSell()
  {
   if(!ValidateTradeConditions())
      return(false);

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      Log("Trade rejected: no valid prices.");
      return(false);
     }

   double entry = NormalizeDouble(bid,g_digits);
   double sl    = CalculateStopLoss(SETUP_BEARISH);
   if(sl<=0.0 || sl<=entry)
     {
      LogRejection("Trade rejected: invalid stop distance (SL is not above entry).",true);
      return(false);
     }

   double min_dist = MinStopDistance();
   if((sl-entry) < min_dist)
     {
      LogRejection("Trade rejected: invalid stop distance ("+DoubleToString(sl-entry,g_digits)
                   +", broker minimum "+DoubleToString(min_dist,g_digits)+").",true);
      return(false);
     }

   double tp = CalculateTakeProfit(SETUP_BEARISH,entry,sl);
   if(tp<=0.0 || tp>=entry || (entry-tp) < min_dist)
     {
      LogRejection("Trade rejected: invalid take profit distance.",true);
      return(false);
     }

   double lots = CalculateLotSize(entry,sl);
   if(lots<=0.0)
      return(false);

   if(!HasEnoughMargin(ORDER_TYPE_SELL,lots,entry))
      return(false);

   if(!trade.Sell(lots,_Symbol,0.0,sl,tp,TradeComment))
     {
      Log(StringFormat("SELL order failed. Retcode=%d (%s) Error=%d",
                       (int)trade.ResultRetcode(),trade.ResultRetcodeDescription(),GetLastError()));
      return(false);
     }

   uint code = trade.ResultRetcode();
   if(code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL && code!=TRADE_RETCODE_PLACED)
     {
      Log(StringFormat("SELL rejected by server. Retcode=%d (%s)",(int)code,trade.ResultRetcodeDescription()));
      return(false);
     }

   double fill = trade.ResultPrice();
   if(fill<=0.0)
      fill = entry;

   Log("SELL opened");
   Log("  Volume: "+DoubleToString(lots,g_vol_digits)+"  Entry: "+DoubleToString(fill,g_digits));
   Log("  SL: "+DoubleToString(sl,g_digits));
   Log("  TP: "+DoubleToString(tp,g_digits));
   Log(StringFormat("  Risk: %.2f%%  R:R %.2f  Setup: %s",
                    RiskPercent,RiskReward,TimeToString(g_setup.setup_id,TIME_DATE|TIME_MINUTES)));

   g_setup.traded = true;
   g_state        = STATE_TRADE_OPENED;

   if(ShowDebugObjects)
      DrawTrade(fill,sl,tp);

   return(true);
  }

//+------------------------------------------------------------------+
//| Tick level entry check - price entering an already confirmed FVG |
//+------------------------------------------------------------------+
bool CheckFVGEntry()
  {
   if(g_state!=STATE_WAITING_FOR_RETRACE && g_state!=STATE_FVG_FOUND)
      return(false);
   if(!g_setup.fvg_valid || g_setup.traded)
      return(false);
   if(RequireEntryConfirmation && !g_setup.entry_confirmed)
      return(false);

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
      return(false);

   double fvg50 = (g_setup.fvg_high+g_setup.fvg_low)/2.0;
   bool   opened = false;

   if(g_setup.dir==SETUP_BULLISH)
     {
      double upper = (UseFVG50Entry ? fvg50 : g_setup.fvg_high);
      if(bid<=upper && bid>=g_setup.fvg_low)
        {
         if(!g_entry_logged)
           {
            g_entry_logged = true;
            Log(StringFormat("Price entered bullish FVG (bid %s, zone %s - %s)",
                             DoubleToString(bid,g_digits),
                             DoubleToString(g_setup.fvg_low,g_digits),
                             DoubleToString(g_setup.fvg_high,g_digits)));
           }
         opened = OpenBuy();
        }
     }
   else
      if(g_setup.dir==SETUP_BEARISH)
        {
         double lower = (UseFVG50Entry ? fvg50 : g_setup.fvg_low);
         if(ask>=lower && ask<=g_setup.fvg_high)
           {
            if(!g_entry_logged)
              {
               g_entry_logged = true;
               Log(StringFormat("Price entered bearish FVG (ask %s, zone %s - %s)",
                                DoubleToString(ask,g_digits),
                                DoubleToString(g_setup.fvg_low,g_digits),
                                DoubleToString(g_setup.fvg_high,g_digits)));
              }
            opened = OpenSell();
           }
        }

   // a rejection that cannot resolve itself (invalid stops, lot below the
   // broker minimum, no margin) would otherwise be retried on every tick
   if(!opened && g_hard_reject)
      ResetSetup("trade could not be executed for this setup");

   return(opened);
  }

//+------------------------------------------------------------------+
//| Optional confirmation candle (evaluated on closed M15 bars)      |
//+------------------------------------------------------------------+
void CheckEntryConfirmation()
  {
   if(!RequireEntryConfirmation || !g_setup.fvg_valid || g_setup.entry_confirmed)
      return;

   MqlRates r[];
   if(LoadRates(PERIOD_M15,5,r)<2)
      return;

   double o = r[1].open, c = r[1].close, h = r[1].high, l = r[1].low;

   if(g_setup.dir==SETUP_BULLISH)
     {
      if(l<=g_setup.fvg_high && c>o && c>=g_setup.fvg_low)
        {
         g_setup.entry_confirmed = true;
         Log("Bullish entry confirmation candle closed at "+DoubleToString(c,g_digits));
        }
     }
   else
      if(g_setup.dir==SETUP_BEARISH)
        {
         if(h>=g_setup.fvg_low && c<o && c<=g_setup.fvg_high)
           {
            g_setup.entry_confirmed = true;
            Log("Bearish entry confirmation candle closed at "+DoubleToString(c,g_digits));
           }
        }
  }

//+------------------------------------------------------------------+
//| Invalidation of the running setup on closed candles              |
//+------------------------------------------------------------------+
bool CheckSetupInvalidation()
  {
   if(g_setup.dir==SETUP_NONE)
      return(false);

   MqlRates r[];
   if(LoadRates(PERIOD_M15,5,r)<2)
      return(false);

   double c = r[1].close;

   // the sweep extreme must hold - if it is broken on a closing basis the
   // whole idea is invalid
   if(g_setup.dir==SETUP_BULLISH && c < g_setup.sweep_extreme)
     {
      ResetSetup("sweep low broken on close");
      return(true);
     }
   if(g_setup.dir==SETUP_BEARISH && c > g_setup.sweep_extreme)
     {
      ResetSetup("sweep high broken on close");
      return(true);
     }

   // FVG traded fully through -> look for a new one within the same setup
   if(g_setup.fvg_valid && !g_setup.traded)
     {
      bool gone = false;
      if(g_setup.dir==SETUP_BULLISH && c < g_setup.fvg_low)  gone = true;
      if(g_setup.dir==SETUP_BEARISH && c > g_setup.fvg_high) gone = true;
      if(gone)
        {
         Log("FVG invalidated (price closed through the zone) - searching for a new FVG.");
         if(ShowDebugObjects)
            ObjectDelete(0,FVGObjectName());
         g_setup.fvg_valid       = false;
         g_setup.entry_confirmed = false;
         g_state = STATE_MSS_CONFIRMED;
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Keep the state machine in sync with the actual positions         |
//+------------------------------------------------------------------+
void SyncPositionState()
  {
   int open = CountOpenPositions();

   if(g_state==STATE_TRADE_OPENED && open==0)
     {
      g_state = STATE_SETUP_COMPLETE;
      Log("Position closed - setup complete.");
     }

   if(g_state==STATE_SETUP_COMPLETE && open==0)
      ResetSetup("");
  }

//+------------------------------------------------------------------+
//| Restore state after a terminal restart (best effort)             |
//+------------------------------------------------------------------+
void RestoreState()
  {
   if(CountOpenPositions()>0)
     {
      g_state = STATE_TRADE_OPENED;

      // recover the direction from the live position so the dashboard is honest
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
         g_setup.dir      = (type==POSITION_TYPE_BUY ? SETUP_BULLISH : SETUP_BEARISH);
         g_setup.traded   = true;
         g_setup.setup_id = (datetime)PositionGetInteger(POSITION_TIME);
         g_last_setup_id  = g_setup.setup_id;
         break;
        }
      Log("State recovered after restart: existing position found, state = TRADE_OPENED.");
     }
  }

//+------------------------------------------------------------------+
//| Per-bar processing of the state machine                          |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   UpdateDailyStats(true);
   SyncPositionState();

   if(g_setup.dir!=SETUP_NONE && !g_setup.traded)
     {
      g_setup.bars_alive++;
      if(g_setup.bars_alive > SetupExpirationBars)
        {
         ResetSetup("setup expired (no MSS/FVG confirmation in time)");
        }
     }

   if(g_state==STATE_TRADE_OPENED || g_state==STATE_SETUP_COMPLETE)
      return;

   if(CheckSetupInvalidation())
      return;

   // 1) liquidity grab
   if(g_state==STATE_WAITING_FOR_LIQUIDITY)
     {
      if(DetectLiquidityGrab())
         g_state = STATE_WAITING_FOR_MSS;
      else
         return;
     }

   // 2) M15 MSS / BOS
   if(g_state==STATE_LIQUIDITY_FOUND || g_state==STATE_WAITING_FOR_MSS)
     {
      if(DetectMSS())
         g_state = STATE_MSS_CONFIRMED;
      else
        {
         g_state = STATE_WAITING_FOR_MSS;
         return;
        }
     }

   // 3) fair value gap
   if(g_state==STATE_MSS_CONFIRMED || (!g_setup.fvg_valid && g_state==STATE_WAITING_FOR_RETRACE))
     {
      if(FindSetupFVG())
         g_state = STATE_FVG_FOUND;
      else
        {
         g_state = STATE_MSS_CONFIRMED;
         return;
        }
     }

   // 4) wait for the retracement into the gap
   if(g_state==STATE_FVG_FOUND)
      g_state = STATE_WAITING_FOR_RETRACE;

   if(g_state==STATE_WAITING_FOR_RETRACE)
      CheckEntryConfirmation();
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_init_ok)
      return;

   if(IsNewBar())
      ProcessNewBar();

   // tick level work is limited to entering an already confirmed FVG
   if(g_state==STATE_WAITING_FOR_RETRACE || g_state==STATE_FVG_FOUND)
      CheckFVGEntry();

   if(ShowDashboard)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Object naming helpers - unique per setup                          |
//+------------------------------------------------------------------+
string SetupTag()
  {
   return(g_prefix+IntegerToString((long)g_setup.setup_id)+"_");
  }

string FVGObjectName()      { return(SetupTag()+"FVG");      }
string SweepLineName()      { return(SetupTag()+"SWEEP");    }
string SweptLevelName()     { return(SetupTag()+"LIQ");      }
string SweepPointName()     { return(SetupTag()+"SWEEPPT");  }
string MSSLineName()        { return(SetupTag()+"MSS");      }
string EntryName()          { return(SetupTag()+"ENTRY");    }
string SLName()             { return(SetupTag()+"SL");       }
string TPName()             { return(SetupTag()+"TP");       }

void DeleteSetupObjects(const datetime id)
  {
   ObjectsDeleteAll(0,g_prefix+IntegerToString((long)id)+"_");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Draw a horizontal segment                                        |
//+------------------------------------------------------------------+
void DrawSegment(const string name,const datetime t1,const double p1,
                 const datetime t2,const double p2,const color clr,
                 const int width,const ENUM_LINE_STYLE style,const string text)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TREND,0,t1,p1,t2,p2))
         return;
     }
   else
     {
      ObjectMove(0,name,0,t1,p1);
      ObjectMove(0,name,1,t2,p2);
     }
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   if(text!="")
      ObjectSetString(0,name,OBJPROP_TOOLTIP,text);
  }

//+------------------------------------------------------------------+
//| DrawLiquidity - swept level, sweep point and the H1 swings       |
//+------------------------------------------------------------------+
void DrawLiquidity()
  {
   if(!ShowDebugObjects || g_setup.dir==SETUP_NONE)
      return;

   datetime t_end = TimeCurrent()+PeriodSeconds(PERIOD_M15)*SetupExpirationBars;
   color clr = (g_setup.dir==SETUP_BULLISH ? clrDodgerBlue : clrOrangeRed);

   DrawSegment(SweptLevelName(),g_setup.sweep_time-PeriodSeconds(PERIOD_H1)*10,g_setup.swept_level,
               t_end,g_setup.swept_level,clr,2,STYLE_SOLID,"Swept liquidity level");

   DrawSegment(SweepLineName(),g_setup.sweep_time,g_setup.sweep_extreme,
               t_end,g_setup.sweep_extreme,clrGray,1,STYLE_DOT,"Sweep extreme");

   string pt = SweepPointName();
   if(ObjectFind(0,pt)<0)
      ObjectCreate(0,pt,OBJ_ARROW,0,g_setup.sweep_time,g_setup.sweep_extreme);
   else
      ObjectMove(0,pt,0,g_setup.sweep_time,g_setup.sweep_extreme);
   ObjectSetInteger(0,pt,OBJPROP_ARROWCODE,(g_setup.dir==SETUP_BULLISH ? 233 : 234));
   ObjectSetInteger(0,pt,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,pt,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,pt,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,pt,OBJPROP_HIDDEN,true);
   ObjectSetString(0,pt,OBJPROP_TOOLTIP,"Liquidity sweep point");

   DrawH1Swings();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Draw the confirmed H1 swing highs and lows                        |
//+------------------------------------------------------------------+
void DrawH1Swings()
  {
   if(!ShowDebugObjects)
      return;

   ObjectsDeleteAll(0,g_prefix+"SWING_");

   MqlRates r[];
   int copied = LoadRates(PERIOD_H1,H1_LookbackBars,r);
   if(copied < H1_SwingStrength*2+3)
      return;

   int drawn = 0;
   for(int i=H1_SwingStrength+1; i<copied-H1_SwingStrength && drawn<40; i++)
     {
      if(IsSwingHigh(r,i,H1_SwingStrength))
        {
         string n = g_prefix+"SWING_H"+IntegerToString(i);
         if(ObjectCreate(0,n,OBJ_ARROW,0,r[i].time,r[i].high))
           {
            ObjectSetInteger(0,n,OBJPROP_ARROWCODE,159);
            ObjectSetInteger(0,n,OBJPROP_COLOR,clrTomato);
            ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
            ObjectSetString(0,n,OBJPROP_TOOLTIP,"H1 swing high");
            drawn++;
           }
        }
      else
         if(IsSwingLow(r,i,H1_SwingStrength))
           {
            string n = g_prefix+"SWING_L"+IntegerToString(i);
            if(ObjectCreate(0,n,OBJ_ARROW,0,r[i].time,r[i].low))
              {
               ObjectSetInteger(0,n,OBJPROP_ARROWCODE,159);
               ObjectSetInteger(0,n,OBJPROP_COLOR,clrDeepSkyBlue);
               ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
               ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
               ObjectSetString(0,n,OBJPROP_TOOLTIP,"H1 swing low");
               drawn++;
              }
           }
     }
  }

//+------------------------------------------------------------------+
//| Draw the MSS/BOS level                                           |
//+------------------------------------------------------------------+
void DrawMSS()
  {
   if(!ShowDebugObjects || !g_setup.mss_confirmed)
      return;

   datetime t_end = TimeCurrent()+PeriodSeconds(PERIOD_M15)*SetupExpirationBars;
   color clr = (g_setup.dir==SETUP_BULLISH ? clrLimeGreen : clrCrimson);
   DrawSegment(MSSLineName(),g_setup.sweep_time,g_setup.mss_level,t_end,g_setup.mss_level,
               clr,2,STYLE_DASH,"MSS / BOS level");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Draw the FVG rectangle                                           |
//+------------------------------------------------------------------+
void DrawFVG()
  {
   if(!ShowDebugObjects || !g_setup.fvg_valid)
      return;

   string name = FVGObjectName();
   datetime t1 = g_setup.fvg_time-PeriodSeconds(PERIOD_M15)*2;
   datetime t2 = TimeCurrent()+PeriodSeconds(PERIOD_M15)*SetupExpirationBars;
   color clr = (g_setup.dir==SETUP_BULLISH ? clrSteelBlue : clrIndianRed);

   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,g_setup.fvg_low,t2,g_setup.fvg_high))
         return;
     }
   else
     {
      ObjectMove(0,name,0,t1,g_setup.fvg_low);
      ObjectMove(0,name,1,t2,g_setup.fvg_high);
     }
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
                   StringFormat("FVG %s - %s",
                                DoubleToString(g_setup.fvg_low,g_digits),
                                DoubleToString(g_setup.fvg_high,g_digits)));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Draw entry / SL / TP of the executed trade                       |
//+------------------------------------------------------------------+
void DrawTrade(const double entry,const double sl,const double tp)
  {
   if(!ShowDebugObjects)
      return;

   datetime t1 = TimeCurrent();
   datetime t2 = t1+PeriodSeconds(PERIOD_M15)*SetupExpirationBars*2;

   DrawSegment(EntryName(),t1,entry,t2,entry,clrGold,2,STYLE_SOLID,"Entry");
   DrawSegment(SLName(),t1,sl,t2,sl,clrRed,2,STYLE_SOLID,"Stop loss");
   DrawSegment(TPName(),t1,tp,t2,tp,clrLime,2,STYLE_SOLID,"Take profit");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void DashLine(const int index,const string text,const color clr)
  {
   string name = g_dash_prefix+IntegerToString(index);
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20+index*15);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
  }

void UpdateDashboard()
  {
   datetime now = TimeCurrent();
   if(now==g_last_dash_time)
      return;
   g_last_dash_time = now;

   UpdateDailyStats();   // throttled internally

   string bg = g_dash_prefix+"BG";
   if(ObjectFind(0,bg)<0)
     {
      if(ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0))
        {
         ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,5);
         ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,12);
         ObjectSetInteger(0,bg,OBJPROP_XSIZE,320);
         ObjectSetInteger(0,bg,OBJPROP_YSIZE,205);
         ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'20,20,25');
         ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(0,bg,OBJPROP_COLOR,clrDimGray);
         ObjectSetInteger(0,bg,OBJPROP_BACK,false);
         ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
        }
     }

   bool allowed  = TradingAllowed();
   bool session  = CheckTradingSession();
   double spread = CurrentSpreadPoints();

   string status = "ACTIVE";
   color  status_clr = clrLime;
   if(!allowed)
     {
      status = "BLOCKED ("+g_block_reason+")";
      status_clr = clrRed;
     }
   else
      if(!CheckDailyLoss())
        {
         status = "PAUSED (daily loss limit)";
         status_clr = clrOrange;
        }
      else
         if(MaxTradesPerDay>0 && g_trades_today>=MaxTradesPerDay)
           {
            status = "PAUSED (daily trade limit)";
            status_clr = clrOrange;
           }
         else
            if(!session)
              {
               status = "IDLE (outside session)";
               status_clr = clrGoldenrod;
              }

   int i = 0;
   DashLine(i++,"AGGRESSIVE ALGORITHM BOT  ["+_Symbol+"]",clrWhite);
   DashLine(i++,"EA Status     : "+status,status_clr);
   DashLine(i++,"State         : "+StateToString(g_state),clrSilver);
   DashLine(i++,"Current Setup : "+DirToString(g_setup.dir),
            g_setup.dir==SETUP_BULLISH ? clrDodgerBlue :
            (g_setup.dir==SETUP_BEARISH ? clrOrangeRed : clrSilver));
   DashLine(i++,"Liquidity     : "+(g_setup.dir!=SETUP_NONE
                                    ? "DETECTED @ "+DoubleToString(g_setup.swept_level,g_digits)
                                    : "NONE"),
            g_setup.dir!=SETUP_NONE ? clrLime : clrSilver);
   DashLine(i++,"MSS/BOS       : "+(g_setup.mss_confirmed
                                    ? "CONFIRMED @ "+DoubleToString(g_setup.mss_level,g_digits)
                                    : (g_setup.dir!=SETUP_NONE ? "WAITING" : "NONE")),
            g_setup.mss_confirmed ? clrLime : clrSilver);
   DashLine(i++,"FVG           : "+(g_setup.fvg_valid
                                    ? "DETECTED "+DoubleToString(g_setup.fvg_low,g_digits)+" - "+DoubleToString(g_setup.fvg_high,g_digits)
                                    : "NONE"),
            g_setup.fvg_valid ? clrLime : clrSilver);
   DashLine(i++,StringFormat("Setup Age     : %d / %d M15 bars",g_setup.bars_alive,SetupExpirationBars),clrSilver);
   DashLine(i++,StringFormat("Spread        : %.0f points (max %d)",spread,MaxSpreadPoints),
            spread<=MaxSpreadPoints ? clrSilver : clrRed);
   DashLine(i++,StringFormat("Session       : %s",session ? "ACTIVE" : "CLOSED"),
            session ? clrLime : clrGoldenrod);
   DashLine(i++,StringFormat("Trades Today  : %d / %d",g_trades_today,MaxTradesPerDay),clrSilver);
   DashLine(i++,StringFormat("Daily P/L     : %.2f%% (limit -%.2f%%)",g_daily_pl_pct,MathAbs(MaxDailyLossPercent)),
            g_daily_pl_pct>=0.0 ? clrLime : clrOrangeRed);
   DashLine(i++,StringFormat("Risk Per Trade: %.2f%%   R:R %.2f",RiskPercent,RiskReward),clrSilver);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
