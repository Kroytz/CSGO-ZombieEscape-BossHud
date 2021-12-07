#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <zombieplague>

#pragma semicolon 1
#pragma newdecls required

// Cvar vars
ConVar g_cVHudColor, g_cVHudSymbols;
int HudColor[3];
bool HudSymbols;

// Client vars
Handle g_hCookie = INVALID_HANDLE;
bool g_bStatus[MAXPLAYERS+1] = {false, ...};
// int g_iTimer;

// Config vars
enum struct BossEntity
{
    int  Type; // 1-func_breakable 2-math_counter
    char DisplayName[32];
    char Bar[32];
    int  BarPTR;
    int  BarHealth;
    char Counter[32];
    int  CounterPTR;

    int  StartTime;
    int  StartHealth;

    void ResetStatus()
    {
        this.BarPTR      = -1;
        this.BarHealth   = 0;
        this.CounterPTR  = -1;

        this.StartTime   = -1;
        this.StartHealth = -1;
    }
}
BossEntity g_BossEntity[32];
int  g_iEntCounts = 0;
bool g_bConfigLoaded = false;

StringMap EntityMaxes;

public Plugin myinfo =
{
    name = "Boss Hud",
    author = "AntiTeal & Kroytz",
    description = "",
    version = "2.5 Remake",
    url = "https://github.com/Kroytz"
};

public void OnPluginStart()
{
    g_hCookie = RegClientCookie("bhud_cookie", "Status of BHud", CookieAccess_Private);
    for(int i = 1; i <= MaxClients; i++)
    {
        if (!AreClientCookiesCached(i))
            continue;

        OnClientCookiesCached(i);
    }

    RegConsoleCmd("sm_bhud", Command_BHud, "Toggle Boss Hud");

    HookEntityOutput("func_physbox", "OnHealthChanged", OnDamage);
    HookEntityOutput("func_physbox_multiplayer", "OnHealthChanged", OnDamage);
    HookEntityOutput("func_breakable", "OnHealthChanged", OnDamage);
    HookEntityOutput("math_counter", "OutValue", OnDamageCounter);

    //HookEntityOutput("math_counter", "OnChangedFromMin", OnMaxChanged);
    HookEvent("round_start", Event_OnRoundStart, EventHookMode_PostNoCopy); 

    g_cVHudColor = CreateConVar("sm_bhud_color", "255 0 0", "RGB color value for the hud.");
    g_cVHudSymbols = CreateConVar("sm_bhud_symbols", "1", "Determines whether >> and << are wrapped around the text.");

    g_cVHudColor.AddChangeHook(ConVarChange);
    g_cVHudSymbols.AddChangeHook(ConVarChange);
    AutoExecConfig(true);
    GetConVars();

    EntityMaxes = CreateTrie();
    ClearTrie(EntityMaxes);
}

public void Event_OnRoundStart(Handle event, const char[] name, bool dontBroadcast) 
{ 
    EntityMaxes = CreateTrie();
    ClearTrie(EntityMaxes); 
}  

public void OnClientPostAdminCheck(int client)
{
}

public void ColorStringToArray(const char[] sColorString, int aColor[3])
{
    char asColors[4][4];
    ExplodeString(sColorString, " ", asColors, sizeof(asColors), sizeof(asColors[]));

    aColor[0] = StringToInt(asColors[0]);
    aColor[1] = StringToInt(asColors[1]);
    aColor[2] = StringToInt(asColors[2]);
}

public void GetConVars()
{
    char ColorValue[64];
    g_cVHudColor.GetString(ColorValue, sizeof(ColorValue));
    ColorStringToArray(ColorValue, HudColor);

    HudSymbols = g_cVHudSymbols.BoolValue;
}

public void ConVarChange(ConVar convar, char[] oldValue, char[] newValue)
{
    GetConVars();
}

public void OnConfigsExecuted()
{
    LoadConfig();
}

public void OnClientCookiesCached(int client)
{
    char sValue[8];
    GetClientCookie(client, g_hCookie, sValue, sizeof(sValue));
    g_bStatus[client] = (sValue[0] != '\0' && StringToInt(sValue));
}

public void LoadConfig()
{
    g_iEntCounts = 0;
    g_bConfigLoaded = false;

    char path[128];
    GetCurrentMap(path, 128);
    Format(path, 128, "cfg/sourcemod/map-boss/%s.cfg", path);

    if(!FileExists(path))
    {
        LogMessage("Loading %s but does not exists", path);
        return;
    }

    KeyValues kv = new KeyValues("entities");

    kv.ImportFromFile(path);
    kv.Rewind();
    
    if(!kv.GotoFirstSubKey())
    {
        delete kv;
        return;
    }

    char sTemp[32];

    do
    {
        // 类型
        kv.GetString("type", sTemp, sizeof(sTemp));
        if (StrContains(sTemp, "func_", false) != -1)
        {
            g_BossEntity[g_iEntCounts].Type = 1;
            PrintToServer("[BHUD] Config: Type - func");
        }
        else if (StrContains(sTemp, "math_", false) != -1)
        {
            g_BossEntity[g_iEntCounts].Type = 2;
            PrintToServer("[BHUD] Config: Type - math");
        }
        else
        {
            LogError("[BHUD] This type of entity is not supported.");
            continue;
        }

        // 显示名称
        kv.GetString("displayname", sTemp, sizeof(sTemp));
        strcopy(g_BossEntity[g_iEntCounts].DisplayName, 32, sTemp);
        PrintToServer("[BHUD] Config: Displayname - %s", sTemp);

        // 目标
        kv.GetString("bar", sTemp, sizeof(sTemp));
        strcopy(g_BossEntity[g_iEntCounts].Bar, 32, sTemp);
        PrintToServer("[BHUD] Config: Bar - %s", sTemp);

        // 目标
        kv.GetString("counter", sTemp, sizeof(sTemp));
        strcopy(g_BossEntity[g_iEntCounts].Counter, 32, sTemp);
        PrintToServer("[BHUD] Config: Counter - %s", sTemp);

        g_iEntCounts ++;
    }
    while(kv.GotoNextKey());

    if(g_iEntCounts)
    {
        g_bConfigLoaded = true;
        LogMessage("Load %s successful", path);
    }
    else LogError("Loaded %s but not found any data", path);
}

public Action Command_BHud(int client, int argc)
{
    char sValue[8];
    g_bStatus[client] = !g_bStatus[client];
    PrintToChat(client, "[SM] BHud has been %s.", g_bStatus[client] ? "enabled" : "disabled");
    Format(sValue, sizeof(sValue), "%i", g_bStatus[client]);
    SetClientCookie(client, g_hCookie, sValue);

    return Plugin_Handled;
}

public void SendMsgAll(char szMessage[128])
{
    for (int i=0; i<MAXPLAYERS+1; i++)
    {
        if (!IsPlayerExist(i) || IsFakeClient(i))
        {
            continue;
        }

        int rgb;
        rgb |= ((HudColor[0] & 0xFF) << 16);
        rgb |= ((HudColor[1] & 0xFF) << 8 );
        rgb |= ((HudColor[2] & 0xFF) << 0 );
        PrintHintText(i, "<font color='#%06X'>%s</font>", rgb, szMessage);
    }
}

public void OnDamage(const char[] output, int caller, int activator, float delay)
{
    if(g_bConfigLoaded)
    {
        // if (g_iTimer > GetTime())
        // {
        //     return;
        // }

        char szString[128];

        static int entid = 0;
        for(entid=0; entid<g_iEntCounts; ++entid)
        {
            if (caller == g_BossEntity[entid].CounterPTR)
            {
                int health = GetEntProp(caller, Prop_Data, "m_iHealth");
                if(health > 0 && health <= 900000)
                {
                    if(HudSymbols)
                        Format(szString, sizeof(szString), "[%s] : %i HP", g_BossEntity[entid].DisplayName, health);
                    else
                        Format(szString, sizeof(szString), "%s: %i HP", g_BossEntity[entid].DisplayName, health);

                    SendMsgAll(szString);
                    // g_iTimer = GetTime() + 1;
                }
            }
        }
    }
}

public void OnDamageCounter(const char[] output, int caller, int activator, float delay)
{
    if(g_bConfigLoaded)
    {
        // if (g_iTimer > GetTime())
        // {
        //     return;
        // }

        char szName[64], szString[128];
        GetEntPropString(caller, Prop_Data, "m_iName", szName, sizeof(szName));

        static int entid = 0;
        for(entid=0; entid<g_iEntCounts; ++entid)
        {
            if (caller == g_BossEntity[entid].CounterPTR)
            {
                static int offset = -1;
                if (offset == -1)
                    offset = FindDataMapInfo(caller, "m_OutValue");

                int health = RoundFloat(GetEntDataFloat(caller, offset));
                int entmax;
                if(GetTrieValue(EntityMaxes, szName, entmax) && entmax != RoundFloat(GetEntPropFloat(caller, Prop_Data, "m_flMax")))
                    health = RoundFloat(GetEntPropFloat(caller, Prop_Data, "m_flMax")) - health;

                float flETA = 9999.0;
                if (g_BossEntity[entid].StartTime == -1)
                {
                    g_BossEntity[entid].StartTime = GetTime();
                    g_BossEntity[entid].StartHealth = health;
                }
                else
                {
                    // ETA = HealthRemain / (DamageTotal / TimeElapsed)
                    int iDamageTotal = g_BossEntity[entid].StartHealth - health;
                    int iTimeElapsed = g_BossEntity[entid].StartTime - GetTime();
                    float flDamageAvg = float(iDamageTotal) / float(iTimeElapsed);

                    flETA = float(health) / flDamageAvg;
                }

                if(HudSymbols)
                {
                    if (g_BossEntity[entid].BarPTR != -1)
                    {
                        Format(szString, sizeof(szString), "[%s][%dx] : %i HP\nETA: %.2fs", g_BossEntity[entid].DisplayName, g_BossEntity[entid].BarHealth, health, flETA);
                    }
                    else
                    {
                        Format(szString, sizeof(szString), "[%s] : %i HP", g_BossEntity[entid].DisplayName, health, flETA);
                    }
                }
                else
                {
                    Format(szString, sizeof(szString), "%s: %i HP", g_BossEntity[entid].DisplayName, health, flETA);
                }

                // if(HudSymbols)
                //     Format(szString, sizeof(szString), "[%s] : %i HP", szName, health);
                // else
                //     Format(szString, sizeof(szString), "%s: %i HP", szName, health);

                SendMsgAll(szString);
                // g_iTimer = GetTime() + 1;
            }
            else if (caller == g_BossEntity[entid].BarPTR)
            {
                static int offset = -1;
                if (offset == -1)
                    offset = FindDataMapInfo(caller, "m_OutValue");

                int health = RoundFloat(GetEntDataFloat(caller, offset));
                g_BossEntity[entid].BarHealth = health;
            }
        }
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if(IsValidEntity(entity))
    {
        SDKHook(entity, SDKHook_SpawnPost, OnEntitySpawnPost);
    }
}

public void OnEntitySpawnPost(int ent)
{
    RequestFrame(CheckEnt, ent);
}

public void CheckEnt(any ent)
{
    if (IsValidEntity(ent))
    {
        char szName[64], szType[64];
        GetEntityClassname(ent, szType, sizeof(szType));
        GetEntPropString(ent, Prop_Data, "m_iName", szName, sizeof(szName));

        if(StrEqual(szType, "math_counter", false))
        {
            SetTrieValue(EntityMaxes, szName, RoundFloat(GetEntPropFloat(ent, Prop_Data, "m_flMax")), true);

            static int entid = 0;
            for(entid=0; entid<g_iEntCounts; ++entid)
            {
                if (strcmp(szName, g_BossEntity[entid].Counter, false) == 0)
                {
                    g_BossEntity[entid].CounterPTR = ent;
                    PrintToServer("CheckEnt: Found ent %d | %s as %d counter", ent, szName, entid);
                }
                else if (strcmp(szName, g_BossEntity[entid].Bar, false) == 0)
                {
                    g_BossEntity[entid].BarPTR = ent;
                    PrintToServer("CheckEnt: Found ent %d | %s as %d bar", ent, szName, entid);
                    g_BossEntity[entid].BarHealth = RoundFloat(GetEntPropFloat(ent, Prop_Data, "m_flMax"));
                }
            }
        }
    }
}