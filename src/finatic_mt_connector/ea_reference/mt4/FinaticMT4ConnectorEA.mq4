#property strict
#property version   "0.1.0"
#property description "Finatic MT4 Connector Reference EA"

input string FinaticPlatform = "mt4";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int FinaticSigningSchemeVersion = 1;
input int FinaticTimestampSkewSeconds = 300;
input bool FinaticSnapshotRequired = true;
input int FinaticHeartbeatSeconds = 15;

int OnInit()
  {
   EventSetTimer(FinaticHeartbeatSeconds);
   Print("Finatic MT4 Connector initialized. Platform=", FinaticPlatform);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
   // Reference implementation placeholder: transport and signing are handled
   // by the companion Python reference in this repo.
  }

void OnTimer()
  {
   // Heartbeat cadence placeholder for reference EA implementation.
  }
