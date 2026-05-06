#property strict
#property version   "0.2.0"
#property description "Finatic MT5 Connector — posts JSON heartbeats to Finatic Background (see WebRequest allowlist in MT5 options)."

input string FinaticPlatform = "mt5";
input string FinaticConnectorId = "";
input string FinaticConnectorSecret = "";
input string FinaticIngestUrl = "";
input int    FinaticSigningSchemeVersion = 1;
input int    FinaticTimestampSkewSeconds = 300;
input bool   FinaticSnapshotRequired = true;
input int    FinaticHeartbeatSeconds = 15;
input int    FinaticSecretVersion = 1;

long  g_heartbeatSequence = 0;
bool  g_ingestConfigurationValid = false;
string g_heartbeatRequestUrl = "";

void OnInit()
  {
   g_ingestConfigurationValid = finaticValidateIngestConfiguration();
   if(!g_ingestConfigurationValid)
     return(INIT_FAILED);
   g_heartbeatRequestUrl = finaticBuildHeartbeatUrl(FinaticIngestUrl);
   EventSetTimer(FinaticHeartbeatSeconds);
   Print("Finatic MT5 Connector: timer=", FinaticHeartbeatSeconds, "s URL=", g_heartbeatRequestUrl);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
   // Timer-driven heartbeat only; push events/snapshot via future EA logic if needed.
  }

void OnTimer()
  {
   if(!g_ingestConfigurationValid)
     return;
   if(StringLen(g_heartbeatRequestUrl) < 8)
     return;
   string jsonBody =
     "{\"sequence\":" + IntegerToString(g_heartbeatSequence) +
     ",\"secret_version\":" + IntegerToString(FinaticSecretVersion) +
     ",\"platform\":\"" + FinaticPlatform +
     "\",\"payload\":{}}";
   uchar  postData[];
   StringToCharArray(jsonBody, postData, 0, WHOLE_ARRAY, CP_UTF8);
   string httpHeaders = "Content-Type: application/json\r\n";
   uchar  responseData[];
   string responseHeaders;
   ResetLastError();
   int httpCode = WebRequest("POST", g_heartbeatRequestUrl, httpHeaders, 8000, postData, responseData, responseHeaders);
   if(httpCode == -1)
     {
      int err = GetLastError();
      Print("Finatic heartbeat WebRequest failed. Error=", err,
            " — In MT5: Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL (add http://localhost:8001 or your ingest host:port).");
      return;
     }
   if(httpCode < 200 || httpCode > 299)
     {
      Print("Finatic heartbeat HTTP ", httpCode, " body=", CharArrayToString(responseData, 0, WHOLE_ARRAY, CP_UTF8));
      return;
     }
   g_heartbeatSequence++;
  }

bool finaticValidateIngestConfiguration()
  {
   if(StringLen(FinaticIngestUrl) < 12)
     {
      Print("Finatic: set FinaticIngestUrl from the Connect portal (Generate connector credentials).");
      return(false);
     }
   if(StringFind(FinaticIngestUrl, "http://", 0) != 0 && StringFind(FinaticIngestUrl, "https://", 0) != 0)
     {
      Print("Finatic: FinaticIngestUrl must start with http:// or https://");
      return(false);
     }
   if(StringLen(FinaticPlatform) < 2)
     {
      Print("Finatic: set FinaticPlatform to mt4 or mt5");
      return(false);
     }
   if(FinaticSecretVersion < 1)
     {
      Print("Finatic: FinaticSecretVersion must be >= 1 (match rotate-secret / portal).");
      return(false);
     }
   return(true);
  }

string finaticBuildHeartbeatUrl(string baseUrl)
  {
   string trimmed = baseUrl;
   StringTrimLeft(trimmed);
   StringTrimRight(trimmed);
   while(StringLen(trimmed) > 0 && StringGetCharacter(trimmed, StringLen(trimmed) - 1) == '/')
      trimmed = StringSubstr(trimmed, 0, StringLen(trimmed) - 1);
   return(trimmed + "/heartbeat");
  }
