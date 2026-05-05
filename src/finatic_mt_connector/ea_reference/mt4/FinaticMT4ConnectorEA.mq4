#property strict
#property version   "0.1.0"
#property description "Finatic MT4 Connector Reference EA"

extern string FinaticPlatform = "mt4";
extern string FinaticConnectorId = "";
extern string FinaticConnectorSecret = "";
extern string FinaticIngestUrl = "";
extern int FinaticSigningSchemeVersion = 1;
extern int FinaticTimestampSkewSeconds = 300;
extern bool FinaticSnapshotRequired = true;
extern int FinaticHeartbeatSeconds = 15;

int init()
  {
   EventSetTimer(FinaticHeartbeatSeconds);
   Print("Finatic MT4 Connector initialized. Platform=", FinaticPlatform);
   return(0);
  }

int deinit()
  {
   EventKillTimer();
   return(0);
  }

int start()
  {
   // Reference implementation placeholder: transport and signing are handled
   // by the companion Python reference in this repo.
   return(0);
  }

void OnTimer()
  {
   // Heartbeat cadence placeholder for reference EA implementation.
  }
