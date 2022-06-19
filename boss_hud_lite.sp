#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <zombiereloaded>
#include <csgocolors_fix>

#undef REQUIRE_EXTENSIONS
#include <outputinfo>
#define REQUIRE_EXTENSIONS

#pragma newdecls required
#define PLUGIN_VERSION "1.3"

public Plugin myinfo = 
{
	name = "Boss_Hud",
	author = "Anubis, Strellic, Kroytz",
	description = "Plugin that displays boss and breakable health.",
	url = "https://github.com/Stewart-Anubis",
	version = PLUGIN_VERSION
};

// colors
#define COLOR_SIMPLEHUD	 "#FF0000"
#define COLOR_BOSSNAME	  "#FF00FF"
#define COLOR_TOPBOSSDMG	"#FF0000"
#define COLOR_CIRCLEHI	  "#FFFF00"
#define COLOR_CIRCLEMID	 "#FFFF00"
#define COLOR_CIRCLELOW	 "#FFFF00"

// delays
#define DELAY_SIMPLEHUD	 2
#define DELAY_BOSSDEAD	  3
#define DELAY_BOSSTIMEOUT   10
#define DELAY_MULTBOSS	  1
#define DELAY_HUDUPDATE	 0.75

#define BOSS_NAME_LEN 256
#define MAX_BOSSES 64

// any breakables above this HP won't be triggered
#define MAX_BREAKABLE_HP 900000

enum HPType 
{
	decreasing,
	increasing,
	none
};

enum struct Boss 
{
	char szDisplayName[BOSS_NAME_LEN];
	char szTargetName[BOSS_NAME_LEN];
	char szHPBarName[BOSS_NAME_LEN];
	char szHPInitName[BOSS_NAME_LEN];

	int iBossEnt;
	int iHPCounterEnt;
	int iInitEnt;

	int iMaxBars;
	int iCurrentBars;

	int iHP;
	int iInitHP;
	int iHighestHP;
	int iHighestTotalHP;

	int iForceBars;

	HPType hpBarMode;
	HPType hpMode;

	int iDamage[MAXPLAYERS+1];
	int iTotalHits;

	bool bDead;
	bool bDeadInit;
	bool bActive;

	int iLastHit;
	int iFirstActive;
}

enum struct SimpleHUD 
{
	int iEntID[MAXPLAYERS+1];
	int iTimer[MAXPLAYERS+1];
}

bool g_bBossHud,
	g_bBreakableHud,
	g_bShowTopDMG,
	g_bMultBoss,
	g_bMultHP,
	g_bBoshudDebugger[MAXPLAYERS+1];

int g_iBosses,
	g_iMultShowing,
	g_iMultLastSwitch,
	g_bOutputInfo,
	g_iOutValueOffset = -1;

Handle g_hTimer = INVALID_HANDLE;

ConVar g_cBossHud = null,
	g_cBreakableHud = null,
	g_cVUpdateTime = null;

float g_fVUpdateTime;

Boss bosses[MAX_BOSSES];
SimpleHUD simplehud;
StringMap EntityMaxes;

public void OnPluginStart()
{
	LoadTranslations("boss_hud_lite.phrases");
	LoadTranslations("common.phrases");
	LoadTranslations("core.phrases");


	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	LoadConfig();

	RegAdminCmd("sm_currenthp",	 Command_CHP, ADMFLAG_GENERIC, "See Current HP");
	RegAdminCmd("sm_subtracthp",	Command_SHP, ADMFLAG_GENERIC, "Subtract Current HP");
	RegAdminCmd("sm_addhp",		 Command_AHP, ADMFLAG_GENERIC, "Add Current HP");
	RegAdminCmd("sm_bhuddebug", Command_BhudDebug, ADMFLAG_GENERIC, "Bhud_Debug");

	HookEntityOutput("func_physbox",				"OnHealthChanged",  Output_OnHealthChanged);
	HookEntityOutput("func_physbox_multiplayer",	"OnHealthChanged",  Output_OnHealthChanged);
	HookEntityOutput("func_breakable",			  "OnHealthChanged",  Output_OnHealthChanged);
	HookEntityOutput("func_physbox",				"OnBreak",		  Output_OnBreak);
	HookEntityOutput("func_physbox_multiplayer",	"OnBreak",		  Output_OnBreak);
	HookEntityOutput("func_breakable",			  "OnBreak",		  Output_OnBreak);
	HookEntityOutput("math_counter",				"OutValue",		 Output_OutValue);

	EntityMaxes = CreateTrie();
	ClearTrie(EntityMaxes);

	g_cBossHud = CreateConVar("sm_boss_hud", "1", "Boss Hud Enable = 1/Disable = 0");
	g_cBreakableHud = CreateConVar("sm_boss_breakable_hud", "1", "Breakable Hud Enable = 1/Disable = 0");
	g_cVUpdateTime = CreateConVar("sm_boss_hud_updatetime", "0.75", "Delay between each update of the BHUD hud.", _, true, 0.0);


	g_cBossHud.AddChangeHook(OnConVarChanged);
	g_cBreakableHud.AddChangeHook(OnConVarChanged);
	g_cVUpdateTime.AddChangeHook(OnConVarChanged);
	
	OnConVarChanged(null, "", "");

	AutoExecConfig(true, "Boss_hud");
	InitiateTimer();

	g_bOutputInfo = LibraryExists("OutputInfo");
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	MarkNativeAsOptional("GetOutputActionValueFloat");
	return APLRes_Success;
}

public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "OutputInfo")) {
		g_bOutputInfo = false;
	}
}
 
public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "OutputInfo")) {
		g_bOutputInfo = true;
	}
}

public void OnConVarChanged(ConVar CVar, const char[] oldVal, const char[] newVal)
{
	g_bBossHud = g_cBossHud.BoolValue;
	g_bBreakableHud = g_cBreakableHud.BoolValue;
	g_fVUpdateTime = g_cVUpdateTime.FloatValue;
	InitiateTimer();
}

public void InitiateTimer()
{
	if(g_hTimer != INVALID_HANDLE)
	{
		KillTimer(g_hTimer); 
		g_hTimer = INVALID_HANDLE; 
	}

	if (g_bBossHud || g_bBreakableHud)
	{
		// PrintToChatAll("[InitiateTimer] Initalized Boss Timer");
		g_hTimer = CreateTimer(g_fVUpdateTime, Timer_HUDUpdate, _, TIMER_REPEAT);
	}
}

public void Event_RoundStart(Handle ev, const char[] name, bool broadcast)
{
	LoadConfig();

	if (EntityMaxes != INVALID_HANDLE)
		CloseHandle(EntityMaxes);

	EntityMaxes = CreateTrie();
	ClearTrie(EntityMaxes);
}

void LoadConfig(int id = -1)
{
	g_iBosses = 0;
	g_iMultShowing = 0;

	char mapname[128], filename[256];
	GetCurrentMap(mapname, sizeof(mapname));
	Format(filename, sizeof(filename), "addons/sourcemod/configs/Boss_Hud/%s.txt", mapname);
	// PrintToServer("[LoadConfig] -> %s", filename);

	KeyValues kv = new KeyValues("math_counter");
	kv.ImportFromFile(filename);

	if (!kv.GotoFirstSubKey()) {
		// PrintToServer("[LoadConfig] -> Failed to GotoFirstSubKey");
		delete kv;
		return;
	}

	// default values
	g_bShowTopDMG   = true;
	g_bMultBoss	 = false;
	g_bMultHP		= false;

	do {
		if(id != -1 && id != g_iBosses) {
			g_iBosses++;
			continue;
		}

		char section[64];
		kv.GetSectionName(section, sizeof(section));

		if (StrEqual(section, "config")) 
		{
			g_bShowTopDMG   = (kv.GetNum("BossBeatenShowTopDamage", g_bShowTopDMG) == 1);
			g_bMultBoss	 = (kv.GetNum("MultBoss", g_bMultBoss) == 1);
			g_bMultHP		= (kv.GetNum("MultHP", g_bMultHP) == 1);
			continue;
		}

		kv.GetString("HP_counter",	  bosses[g_iBosses].szTargetName, BOSS_NAME_LEN, bosses[g_iBosses].szTargetName);
		// PrintToServer("[LoadConfig] Index %d -> HP_counter: %s", g_iBosses, bosses[g_iBosses].szTargetName);
		kv.GetString("BreakableName",   bosses[g_iBosses].szTargetName, BOSS_NAME_LEN, bosses[g_iBosses].szTargetName);
		// PrintToServer("[LoadConfig] Index %d -> BreakableName: %s", g_iBosses, bosses[g_iBosses].szTargetName);

		kv.GetString("CustomText", 		bosses[g_iBosses].szDisplayName, BOSS_NAME_LEN, bosses[g_iBosses].szTargetName);
		// PrintToServer("[LoadConfig] Index %d -> CustomText: %s", g_iBosses, bosses[g_iBosses].szDisplayName);

		kv.GetString("HPbar_counter",   bosses[g_iBosses].szHPBarName,  BOSS_NAME_LEN, bosses[g_iBosses].szHPBarName);
		// PrintToServer("[LoadConfig] Index %d -> HPbar_counter: %s", g_iBosses, bosses[g_iBosses].szHPBarName);
		kv.GetString("HPinit_counter",  bosses[g_iBosses].szHPInitName, BOSS_NAME_LEN, bosses[g_iBosses].szHPInitName);
		// PrintToServer("[LoadConfig] Index %d -> HPinit_counter: %s", g_iBosses, bosses[g_iBosses].szHPInitName);

		bosses[g_iBosses].iMaxBars	  = kv.GetNum("HPbar_max",		10); //now basing it off of current bars on first activation (IF BAR TYPE == DECREASING)
		// PrintToServer("[LoadConfig] Index %d -> HPbar_max: %d", g_iBosses, bosses[g_iBosses].iMaxBars);
		bosses[g_iBosses].iCurrentBars  = kv.GetNum("HPbar_default",	0);
		// PrintToServer("[LoadConfig] Index %d -> HPbar_default: %d", g_iBosses, bosses[g_iBosses].iCurrentBars);
		bosses[g_iBosses].iForceBars	= kv.GetNum("HPbar_force",	  0);
		// PrintToServer("[LoadConfig] Index %d -> HPbar_force: %d", g_iBosses, bosses[g_iBosses].iForceBars);

		int iBarMode = kv.GetNum("HPbar_mode", 0);
		if(iBarMode == 1)
			bosses[g_iBosses].hpBarMode = decreasing;
		else if(iBarMode == 2) {
			bosses[g_iBosses].hpBarMode = increasing;
			bosses[g_iBosses].iCurrentBars = bosses[g_iBosses].iMaxBars - bosses[g_iBosses].iCurrentBars;
		}
		else
			bosses[g_iBosses].hpBarMode = none;

		bosses[g_iBosses].bDead = false;
		bosses[g_iBosses].bDeadInit = false;
		bosses[g_iBosses].bActive = false;

		bosses[g_iBosses].iBossEnt	   = -1;
		bosses[g_iBosses].iHPCounterEnt  = -1;
		bosses[g_iBosses].iInitEnt	   = -1;

		for(int i = 0; i <= MaxClients; i++) {
			bosses[g_iBosses].iDamage[i] = 0;
		}

		bosses[g_iBosses].iTotalHits 	= 0;
		bosses[g_iBosses].iLastHit 		= -1;
		bosses[g_iBosses].iFirstActive 	= -1;

		g_iBosses++;
	} while (kv.GotoNextKey());
	
	delete kv;
}

stock int GetCounterValue(int counter) {
	char szType[64];
	GetEntityClassname(counter, szType, sizeof(szType));

	if(!StrEqual(szType, "math_counter", false)) {
		return -1;
	}

	if(g_iOutValueOffset == -1)
		g_iOutValueOffset = FindDataMapInfo(counter, "m_OutValue");

	if(g_bOutputInfo)
		return RoundFloat(GetOutputActionValueFloat(counter, "m_OutValue"));
	return RoundFloat(GetEntDataFloat(counter, g_iOutValueOffset));
}

stock bool IsValidClient(int client) {
	if (!(1 <= client <= MaxClients) || !IsClientInGame(client))
		return false;
	return true;
}

public Action Command_BhudDebug(int client, int argc)
{
	if(IsValidClient(client))
	{
		if (g_bBoshudDebugger[client])
		{
			g_bBoshudDebugger[client] = false;
			CPrintToChat(client, "%t", "Boshud Debugger Desabled");
		}
		else
		{
			g_bBoshudDebugger[client] = true;
			CPrintToChat(client, "%t", "Boshud Debugger Enabled");
		}
	}
	else
	PrintToChat(client, "%t", "No Access");
	return Plugin_Handled;
}

public void Output_OnHealthChanged(const char[] output, int caller, int activator, float delay)
{
	if (!g_bBreakableHud)
		return;

	char szName[64];
	GetEntPropString(caller, Prop_Data, "m_iName", szName, sizeof(szName));

	if (IsValidClient(activator))
	{
		if (g_bBoshudDebugger[activator])
		{
			int hammerIDi = GetEntProp(caller, Prop_Data, "m_iHammerID");
			int HPvalue = GetEntProp(caller, Prop_Data, "m_iHealth");
			PrintToChat(activator, " \x04[Boss_HUD] Breakable: \x01%s  \x04HammerID: \x01%d  \x04HP: \x01%d\x04.", szName, hammerIDi, HPvalue);
		}
	}

	for (int i = 0; i < g_iBosses; i++) {
		if (StrEqual(bosses[i].szTargetName, szName, false)) {
			if(bosses[i].bDead)
				return;

			int hp = GetEntProp(caller, Prop_Data, "m_iHealth");

			if(hp > MAX_BREAKABLE_HP)
				return;

			if(hp > bosses[i].iHighestHP)
				bosses[i].iHighestHP = hp;

			// HP AND PERCENTAGE RECALIBRATION
			int percentLeft = RoundFloat((hp * 1.0 / bosses[i].iHighestHP) * 100); // if percentLeft <= 75 within the first 3 seconds, reset it
			if(GetTime() - bosses[i].iFirstActive <= 3 && percentLeft <= 75) {
				bosses[i].iHighestHP = hp;
			}
			if(percentLeft == 0 && hp >= 1000) { // if 0 percent left and hp >= 1000, reset it
				bosses[i].iHighestHP = hp;
			}

			bosses[i].iHP = hp;
			bosses[i].iBossEnt = caller;

			if (IsValidClient(activator)) 
			{
				if(bosses[i].iTotalHits > 5) 
				{
					if(bosses[i].iFirstActive == -1)
						bosses[i].iFirstActive = GetTime();

					// PrintToChatAll("[Output_OnHealthChanged] -> Set activated");
					bosses[i].bActive = true;
				}

				bosses[i].iLastHit = GetTime();
				bosses[i].iDamage[activator] += 1;
				bosses[i].iTotalHits += 1;

				AddClientMoney(activator, 15);

				if(hp <= 0 && bosses[i].hpBarMode == none) 
				{
					bosses[i].bDead = true;
					bosses[i].bDeadInit = true;
				}
			}

			return;
		}
	}

	if (IsValidClient(activator)) 
	{
		simplehud.iEntID[activator] = caller;
		simplehud.iTimer[activator] = GetTime();
	}
}

public void Output_OnBreak(const char[] output, int caller, int activator, float delay)
{
	for (int i = 0; i < g_iBosses; i++) {
		if(bosses[i].iBossEnt == caller) {
			bosses[i].iHP	   = 0;
			bosses[i].bDead	 = true;
			bosses[i].bDeadInit  = true;
		}
	}
}

public void Output_OutValue(const char[] output, int caller, int activator, float delay)
{
	if (!g_bBossHud) return;
	char szName[64];
	GetEntPropString(caller, Prop_Data, "m_iName", szName, sizeof(szName));

	if(IsValidClient(activator))
	{
		simplehud.iEntID[activator] = caller;
		simplehud.iTimer[activator] = GetTime();

		if (g_bBoshudDebugger[activator])
		{
			int hammerIDi = GetEntProp(caller, Prop_Data, "m_iHammerID");
			int HPvalue = RoundToNearest(GetEntDataFloat(caller, FindDataMapInfo(caller, "m_OutValue")));
			PrintToChat(activator, " \x04[Boss_HUD] MathCounter: \x01%s  \x04HammerID: \x01%d  \x04HP: \x01%d\x04.", szName, hammerIDi, HPvalue);
		}
	}

	for (int i = 0; i < g_iBosses; i++) {
		if (StrEqual(bosses[i].szTargetName, szName, false)) {
			if(bosses[i].bDead)
				return;

			int counter = GetCounterValue(caller);
			int hp = counter;
			bosses[i].iBossEnt = caller;

			int min = RoundFloat(GetEntPropFloat(caller, Prop_Data, "m_flMin"));
			int max = RoundFloat(GetEntPropFloat(caller, Prop_Data, "m_flMax"));

			if(bosses[i].hpMode == increasing) {
				hp = max - hp;
			}

			bosses[i].iHP = hp;

			if(hp > bosses[i].iHighestHP)
				bosses[i].iHighestHP = hp;

			// HP AND PERCENTAGE RECALIBRATION
			if(bosses[i].hpBarMode != none) {
				if(hp > 25 && (bosses[i].iHighestHP*1.0) / hp > 150.0) { // if iHighestHP seems too large for a segment, reset it
					bosses[i].iHighestHP = hp;
					bosses[i].iHighestTotalHP = 0;
				}
			}
			else {
				int percentLeft = RoundFloat((hp * 1.0 / bosses[i].iHighestHP) * 100); // if percentLeft <= 75 within the first 3 seconds, reset it
				if(GetTime() - bosses[i].iFirstActive <= 3 && percentLeft <= 75) {
					bosses[i].iHighestHP = hp;
				}
			}

			if(IsValidClient(activator)) {
				if(bosses[i].hpBarMode == none) {
					if(bosses[i].bActive && bosses[i].iTotalHits > 5) {
						if((bosses[i].hpMode == decreasing && hp <= min) || (bosses[i].hpMode == increasing && counter >= max)) {
							bosses[i].bDead	 = true;
							bosses[i].bDeadInit = true;
						}
					}
				}

				AddClientMoney(activator, 15);

				bosses[i].iDamage[activator] += 1;
				bosses[i].iTotalHits += 1;

				if(bosses[i].iTotalHits > 5) {
					if(bosses[i].iFirstActive == -1)
						bosses[i].iFirstActive = GetTime();

					bosses[i].bActive = true;
				}

				bosses[i].iLastHit = GetTime();
			}

			return;
		}
		else if(StrEqual(bosses[i].szHPBarName, szName, false)) {
			if(bosses[i].bDead)
				return;

			int barCount = GetCounterValue(caller);

			if(bosses[i].hpBarMode == increasing)
				barCount = bosses[i].iMaxBars - barCount;

			bosses[i].iHPCounterEnt = caller;

			if(IsValidClient(activator)) {
				if(bosses[i].bActive && barCount == 0) {
					bosses[i].bDead	 = true;
					bosses[i].bDeadInit  = true;
				}

				bosses[i].iCurrentBars = barCount;

				
				if(!bosses[i].bActive) {
					if(bosses[i].hpBarMode == decreasing)
						bosses[i].iMaxBars = barCount;
				}
				else {
				   if(bosses[i].iMaxBars == 0) {
						if(bosses[i].hpBarMode == decreasing) // if no HPBar set, set max to current +1 (bc this only triggers on decrease)
							bosses[i].iMaxBars = barCount + 1;
					} 
				}

				bosses[i].iLastHit = GetTime();
			}

			return;
		}
		else if(StrEqual(bosses[i].szHPInitName, szName, false)) {
			if(bosses[i].bDead)
				return;

			bosses[i].iInitHP = GetCounterValue(caller);
			bosses[i].iInitEnt = caller;

			return;
		}
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (IsValidEntity(entity))
	{
		SDKHook(entity, SDKHook_SpawnPost, OnEntitySpawnPost);
	}
}

public void OnEntitySpawnPost(int ent) {
	RequestFrame(CheckEnt, ent);
}

public void CheckEnt(any ent) {
	if (IsValidEntity(ent)) {
		char szName[64], szType[64];
		GetEntityClassname(ent, szType, sizeof(szType));
		GetEntPropString(ent, Prop_Data, "m_iName", szName, sizeof(szName));

		if (StrEqual(szType, "math_counter", false)) {
			SetTrieValue(EntityMaxes, szName, RoundFloat(GetEntPropFloat(ent, Prop_Data, "m_flMax")), true);
		}
	}
}

stock int GetClientMoney(int client) {
	return GetEntProp(client, Prop_Send, "m_iAccount");
}
stock void SetClientMoney(int client, int money) {
	SetEntProp(client, Prop_Send, "m_iAccount", money);
}
stock void AddClientMoney(int client, int money) {
	SetClientMoney(client, GetClientMoney(client) + money);
}

stock void StringEllipser(char[] szMessage, int cutoff) {
	if(strlen(szMessage) > cutoff) {
		szMessage[cutoff] = '.';
		szMessage[cutoff+1] = '.';
		szMessage[cutoff+2] = '.';
		szMessage[cutoff+3] = '\0';
	}
}

public Action Timer_HUDUpdate(Handle timer) 
{
	bool inConfig = false;
	for(int i = 0; i < g_iBosses; i++) 
	{
		if (IsValidBoss(i)) 
		{
			inConfig = true;
			break;
		}
	}

	if(!inConfig) {
		for(int i = 1; i <= MaxClients; i++) {
			if(IsValidClient(i)) {
				HUD_SimpleUpdate(i);
			}
		}
		return Plugin_Continue;
	}

	char message[512];
	if(g_bMultBoss) {
		int count = 0;
		for(int i = 0; i < g_iBosses; i++) {
			if(IsValidBoss(i)) {
				count++;
			}
		}

		int[] bossIds = new int[count];
		for(int i = 0, j = 0; i < g_iBosses; i++) {
			if(IsValidBoss(i)) {
				bossIds[j++] = i;
			}
		}

		if(GetTime() > g_iMultLastSwitch + DELAY_MULTBOSS) {
			g_iMultShowing++;
			g_iMultLastSwitch = GetTime();
		}
		if(g_iMultShowing >= count) {
			g_iMultShowing = 0;
		}

		bool bForceUpdate = false;

		for(int i = 0; i < g_iBosses; i++) {
			if(bosses[i].bActive && bosses[i].bDead && bosses[i].bDeadInit) {
				HUD_Update(i, message, sizeof(message));
				bForceUpdate = true;
				break;
			}
		}

		if(!bForceUpdate)
			HUD_Update(bossIds[g_iMultShowing], message, sizeof(message));
	}
	else {
		for(int i = 0; i < g_iBosses; i++) {
			if(IsValidBoss(i)) {
				HUD_Update(i, message, sizeof(message));
				break;
			}
		}
	}

	if (strlen(message) != 0) {
		for (int client = 1; client <= MaxClients; client++) {
			if (IsClientInGame(client)) {
				PrintHintText(client, "%s", message);
			}
		}
	}
	return Plugin_Continue;
}

stock bool IsValidBoss(int i) 
{
	if (bosses[i].bActive) 
	{
		// active and not timedout
		if((bosses[i].bDead && GetTime() < bosses[i].iLastHit + DELAY_BOSSDEAD) || (!bosses[i].bDead && GetTime() < bosses[i].iLastHit + DELAY_BOSSTIMEOUT)) 
		{
			return true;
		}
	}
	return false;
}

public void HUD_Update(int i, char[] message, int len) 
{
	if(!bosses[i].bActive)
	{
		// PrintToChatAll("[HUD_Update] Index %d -> Not active", i);
		return;
	}

	if(bosses[i].bDead) 
	{
		if (GetTime() < bosses[i].iLastHit + DELAY_BOSSDEAD) 
		{
			// PrintToChatAll("[HUD_Update] Index %d -> Boss dead", i);
			HUD_BossDead(i, message, len);
		}
	}
	else if (GetTime() < bosses[i].iLastHit + DELAY_BOSSTIMEOUT) 
	{
		if(bosses[i].hpBarMode == none) 
		{
			if(bosses[i].iForceBars == 0) 
			{
				// PrintToChatAll("[HUD_Update] Index %d -> HUD_BossNoBars", i);
				HUD_BossNoBars(i, message, len);
			}
			else
			{
				// PrintToChatAll("[HUD_Update] Index %d -> HUD_BossForceBars", i);
				HUD_BossForceBars(i, message, len);
			}
		}
		else 
		{
			// PrintToChatAll("[HUD_Update] Index %d -> HUD_BossWithBars", i);
			HUD_BossWithBars(i, message, len);
		}
	}
}

public void HUD_SimpleUpdate(int client) {
	int ent = simplehud.iEntID[client];
	int time = simplehud.iTimer[client];

	if(IsValidEntity(ent) && (GetTime() - time) < DELAY_SIMPLEHUD) {
		char szName[64], szType[64];
		int health;

		GetEntityClassname(ent, szType, sizeof(szType));
		GetEntPropString(ent, Prop_Data, "m_iName", szName, sizeof(szName));

		if(strlen(szName) == 0)
			Format(szName, sizeof(szName), "Health");

		if(StrEqual(szType, "math_counter", false)) {
			health = GetCounterValue(ent);

			int max;
			if(GetTrieValue(EntityMaxes, szName, max) && max != RoundFloat(GetEntPropFloat(ent, Prop_Data, "m_flMax")))
				health = RoundFloat(GetEntPropFloat(ent, Prop_Data, "m_flMax")) - health;
		}
		else
			health = GetEntProp(ent, Prop_Data, "m_iHealth");

		if(health <= 0 || health > MAX_BREAKABLE_HP)
			return;

		char szMessage[128];
		char colorh[8];
		if(health >= 66) colorh = "00FF00";
		else if(health >= 33) colorh = "ffff00";
		else colorh = "ff0000";

		Format(szMessage, sizeof(szMessage), "►[<font color='" ... COLOR_SIMPLEHUD ... "'>%s</font>]◄ HP: <font class='fontSize-xl' font color='#%s'>%d</font>", szName, colorh, health);
		PrintHintText(client, "%s", szMessage);
	}
}

public void HUD_BossDead(int id, char[] szMessage, int len) {
	if(g_bShowTopDMG) {
		int one = 0, two = 0, three = 0;
		char szNotice[128];
		for (int i = 1; i <= MaxClients; i++) {
			if (bosses[id].iDamage[i] > bosses[id].iDamage[one]) {
				three = two;
				two = one;
				one = i;
			} else if (bosses[id].iDamage[i] > bosses[id].iDamage[two]) {
				three = two;
				two = i;
			} else if (bosses[id].iDamage[i] > bosses[id].iDamage[three]) {
				three = i;
			}

			if(IsClientInGame(i) && bosses[id].iDamage[i] > 5) 
			{
				SetGlobalTransTarget(i);
				Format(szNotice, sizeof(szNotice), "%t", "Hud Boss Dead Dmg", bosses[id].iDamage[i]);
				SetHudTextParams(-1.0, 0.9, 3.0, 255,255, 0, 255);
				ShowHudText(i, -1, szNotice);
				SetGlobalTransTarget(LANG_SERVER);
			}
		}

		char message[512];
		if (one != 0 && bosses[id].iDamage[one] > 5) {
			StrCat(message, sizeof(message), "<font class='fontSize-xl' color='" ... COLOR_TOPBOSSDMG ..."'>对BOSS伤害排行:</font>");

			if(bosses[id].bDeadInit)
				CPrintToChatAll("{red}%t", "Chat Top Dmg Title");

			char template[64], name[32];
			GetClientName(one, name, sizeof(name));
			StringEllipser(name, 12);

			Format(template, sizeof(template), "<br>1. %s - %d hits", name, bosses[id].iDamage[one]);
			StrCat(message, sizeof(message), template);

			if(bosses[id].bDeadInit)
				CPrintToChatAll("1. {green}%N{default} - {red}%d{default} hits", one, bosses[id].iDamage[one]);

			if (one != two && two != 0 && bosses[id].iDamage[two] > 5) {
				GetClientName(two, name, sizeof(name));
				StringEllipser(name, 12);

				Format(template, sizeof(template), "<br>2. %s - %d hits", name, bosses[id].iDamage[two]);
				StrCat(message, sizeof(message), template);

				if(bosses[id].bDeadInit)
					CPrintToChatAll("2. {green}%N{default} - {red}%d{default} hits", two, bosses[id].iDamage[two]);

				if (two != three && three != 0 && bosses[id].iDamage[three] > 5) {
					GetClientName(three, name, sizeof(name));
					StringEllipser(name, 12);

					Format(template, sizeof(template), "<br>3. %s - %d hits", name, bosses[id].iDamage[three]);
					StrCat(message, sizeof(message), template);

					if(bosses[id].bDeadInit)
						CPrintToChatAll("3. {green}%N{default} - {red}%d{default} hits", three, bosses[id].iDamage[three]);
				}
			}
		}
		else
			Format(message, sizeof(message), "<br><font class='fontSize-xl' color='" ... COLOR_BOSSNAME ... "'>%s</font> 已被击败", bosses[id].szDisplayName);
		
		StrCat(szMessage, len, message);
	}
	else {
		char message[75 + BOSS_NAME_LEN];
		Format(message, sizeof(message), "<br><font class='fontSize-xl' color='" ... COLOR_BOSSNAME ... "'>%s</font> 已被击败", bosses[id].szDisplayName);
		StrCat(szMessage, len, message);
	}

	if(bosses[id].bDeadInit) 
	{
		bosses[id].bDeadInit = false;
		CreateTimer(DELAY_BOSSDEAD + 6.0, Timer_ResetBoss, id);
	}

	return;
}

public Action Timer_ResetBoss(Handle timer, int id) {
	ResetBoss(id);
}

public void ResetBoss(int id) {
	bosses[id].iTotalHits = 0; // stop it from reactivating in the future
	if(g_bMultHP) {
		LoadConfig(id);
	}
}

public void HUD_BossNoBars(int id, char[] szMessage, int len) 
{
	int percentLeft = RoundFloat((bosses[id].iHP * 1.0 / bosses[id].iHighestHP) * 100);
	int totalHP = bosses[id].iHP;
	int iTimePassed = GetTime() - bosses[id].iFirstActive;
	int damageDealtDuringFight = bosses[id].iHighestHP - bosses[id].iHP;
	float flETA = float(totalHP) / (float(damageDealtDuringFight) / float(iTimePassed)); // totalHP / (damageDealt)
	if (flETA < 0.0)
		flETA = 1145141919.0; // 2147483647.0

	char message[256];
	if(percentLeft > 200 || percentLeft < 0) {
		char colorh[8];
		if(bosses[id].iHP >= 66) colorh = "00FF00";
		else if(bosses[id].iHP >= 33) colorh = "ffff00";
		else colorh = "ff0000";

		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ HP: <font class='fontSize-xl' font color='#%s'>%d</font>\nETA: %.2f", bosses[id].szDisplayName, colorh, bosses[id].iHP, flETA);
	}
	else {
		if(percentLeft > 100)
			percentLeft = 100;

		char colorh[8];
		if(percentLeft >= 66) colorh = "00FF00";
		else if(percentLeft >= 33) colorh = "ffff00";
		else colorh = "ff0000";

		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ [%d%%] HP: <font class='fontSize-xl' font color='#%s'>%d</font>ETA: %.2f", bosses[id].szDisplayName, percentLeft, colorh, bosses[id].iHP, flETA);
	}

	StrCat(szMessage, len, message);
}

public void HUD_BossForceBars(int id, char[] szMessage, int len) {
	int percentLeft = RoundFloat((bosses[id].iHP * 1.0 / bosses[id].iHighestHP) * 100);
	int forceBars = bosses[id].iForceBars;

	int totalHP = bosses[id].iHP;
	int iTimePassed = GetTime() - bosses[id].iFirstActive;
	int damageDealtDuringFight = bosses[id].iHighestHP - bosses[id].iHP;
	float flETA = float(totalHP) / (float(damageDealtDuringFight) / float(iTimePassed)); // totalHP / (damageDealt)
	if (flETA < 0.0)
		flETA = 1145141919.0; // 2147483647.0

	char circleClass[32];
	if (forceBars > 32)
		Format(circleClass, sizeof(circleClass), "fontSize-l");
	else
		Format(circleClass, sizeof(circleClass), "fontSize-xl");

	int barCount = RoundToFloor(forceBars * (bosses[id].iHP * 1.0 / bosses[id].iHighestHP));

	char circleColor[32];
	if(percentLeft >= 40)
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLEHI);
	else if(percentLeft >= 15)
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLEMID);
	else
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLELOW);

	char message[512];
	if(percentLeft > 200 || percentLeft < 0) {
		char colorh[8];
		if(bosses[id].iHP >= 66) colorh = "00FF00";
		else if(bosses[id].iHP >= 33) colorh = "ffff00";
		else colorh = "ff0000";
		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ HP: <font class='fontSize-xl' font color='#%s'>%d</font>\n<font class='%s' color='%s'>\nETA: %.2f", bosses[id].szDisplayName, colorh, bosses[id].iHP, circleClass, circleColor, flETA);
	}
	else {
		if(percentLeft > 100)
			percentLeft = 100;

		char colorh[8];
		if(percentLeft >= 66) colorh = "00FF00";
		else if(percentLeft >= 33) colorh = "ffff00";
		else colorh = "ff0000";
		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ [%d%%%%] HP: <font class='fontSize-xl' font color='#%s'>%d</font>\n<font class='%s' color='%s'>\nETA: %.2f", bosses[id].szDisplayName, percentLeft, colorh, bosses[id].iHP, circleClass, circleColor, flETA);
	}

	for (int i = 0; i < barCount; i++)
		StrCat(message, sizeof(message), "⚫");
	for (int i = 0; i < forceBars - barCount; i++)
		StrCat(message, sizeof(message), "⚪");

	StrCat(message, sizeof(message), "</font>");

	StrCat(szMessage, len, message);
}

public void HUD_BossWithBars(int id, char[] szMessage, int len) {
	int barsRemaining = bosses[id].iCurrentBars - 1;
	if (barsRemaining < 0)
		barsRemaining = 0;

	char circleClass[32];
	if (bosses[id].iMaxBars > 32)
		Format(circleClass, sizeof(circleClass), "fontSize-l");
	else
		Format(circleClass, sizeof(circleClass), "fontSize-xl");

	int totalHP = 0, percentLeft = 0, damageDealtDuringFight = 0;
	if (bosses[id].iInitHP != 0) {
		totalHP = bosses[id].iHP + (barsRemaining * bosses[id].iInitHP);
		percentLeft = RoundFloat((totalHP * 1.0 / (bosses[id].iMaxBars * bosses[id].iInitHP)) * 100);
		damageDealtDuringFight = (bosses[id].iMaxBars * bosses[id].iInitHP) - totalHP;
	}
	else {
		totalHP = bosses[id].iHP + (barsRemaining * bosses[id].iHighestHP);
		if(totalHP > bosses[id].iHighestTotalHP)
			bosses[id].iHighestTotalHP = totalHP;
		
		percentLeft = RoundFloat((totalHP * 1.0 / bosses[id].iHighestTotalHP) * 100);
		damageDealtDuringFight = bosses[id].iHighestTotalHP - totalHP;
	}

	int iTimePassed = GetTime() - bosses[id].iFirstActive;
	float flETA = float(totalHP) / (float(damageDealtDuringFight) / float(iTimePassed)); // totalHP / (damageDealt)
	if (flETA < 0.0)
		flETA = 1145141919.0; // 2147483647.0

	char circleColor[32];
	if(percentLeft >= 40)
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLEHI);
	else if(percentLeft >= 15)
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLEMID);
	else
		Format(circleColor, sizeof(circleColor), COLOR_CIRCLELOW);

	char message[512];
	if(percentLeft > 200 || percentLeft < 0) {
		char colorh[8];
		if(totalHP >= 66) colorh = "00FF00";
		else if(totalHP >= 33) colorh = "ffff00";
		else colorh = "ff0000";
		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ HP: <font class='fontSize-xl' font color='#%s'>%d</font>\n<font class='%s' color='%s'>\nETA: %.2f", bosses[id].szDisplayName, colorh, totalHP, circleClass, circleColor, flETA);
	}
	else {
		if(percentLeft > 100)
			percentLeft = 100;

		char colorh[8];
		if(percentLeft >= 66) colorh = "00FF00";
		else if(percentLeft >= 33) colorh = "ffff00";
		else colorh = "ff0000";
		Format(message, sizeof(message), "►[<font color='" ... COLOR_BOSSNAME ... "'>%s</font>]◄ [%d%%] HP: <font class='fontSize-xl' font color='#%s'>%d</font>\n<font class='%s' color='%s'>\nETA: %.2f", bosses[id].szDisplayName, percentLeft, colorh, totalHP, circleClass, circleColor, flETA);
	}

	for (int i = 0; i < bosses[id].iCurrentBars; i++) {
		StrCat(message, sizeof(message), "⚫");
	}
	for (int i = 0; i < bosses[id].iMaxBars - bosses[id].iCurrentBars; i++) {
		StrCat(message, sizeof(message), "⚪");
	}
	StrCat(message, sizeof(message), "</font>");

	StrCat(szMessage, len, message);
}

public Action Command_CHP(int client, int argc) {
	if (!IsValidEntity(simplehud.iEntID[client])) {
		CPrintToChat(client, "%t", "Invalid Entity", simplehud.iEntID[client]);
		return Plugin_Handled;
	}

	char szName[64], szType[64];
	int health;
	GetEntityClassname(simplehud.iEntID[client], szType, sizeof(szType));
	GetEntPropString(simplehud.iEntID[client], Prop_Data, "m_iName", szName, sizeof(szName));

	if (StrEqual(szType, "math_counter", false)) {
		health = GetCounterValue(simplehud.iEntID[client]);
	} else {
		health = GetEntProp(simplehud.iEntID[client], Prop_Data, "m_iHealth");
	}

	CPrintToChat(client, "%t", "Change Entity Hp", szName, simplehud.iEntID[client], szType, health);
	return Plugin_Handled;
}

public Action Command_SHP(int client, int argc) {
	if (!IsValidEntity(simplehud.iEntID[client])) {
		CPrintToChat(client, "%t", "Invalid Entity", simplehud.iEntID[client]);
		return Plugin_Handled;
	}

	if (argc < 1) {
		ReplyToCommand(client, "[SM] Usage: sm_subtracthp <health>");
		return Plugin_Handled;
	}

	char szName[64], szType[64], arg[8];
	int health, max;

	GetEntityClassname(simplehud.iEntID[client], szType, sizeof(szType));
	GetEntPropString(simplehud.iEntID[client], Prop_Data, "m_iName", szName, sizeof(szName));
	GetCmdArg(1, arg, sizeof(arg));
	SetVariantInt(StringToInt(arg));

	if (StrEqual(szType, "math_counter", false)) {
		health = GetCounterValue(simplehud.iEntID[client]);

		if (GetTrieValue(EntityMaxes, szName, max) && max != RoundFloat(GetEntPropFloat(simplehud.iEntID[client], Prop_Data, "m_flMax")))
			AcceptEntityInput(simplehud.iEntID[client], "Add", client, client);
		else
			AcceptEntityInput(simplehud.iEntID[client], "Subtract", client, client);

		CPrintToChat(client, "%t", "Health subtracted", StringToInt(arg), health, health - StringToInt(arg));
	} else {
		health = GetEntProp(simplehud.iEntID[client], Prop_Data, "m_iHealth");
		AcceptEntityInput(simplehud.iEntID[client], "RemoveHealth", client, client);
		CPrintToChat(client, "%t", "Health subtracted", StringToInt(arg), health, health - StringToInt(arg));
	}

	return Plugin_Handled;
}

public Action Command_AHP(int client, int argc) {
	if (!IsValidEntity(simplehud.iEntID[client])) {
		CPrintToChat(client, "%t", "Invalid Entity", simplehud.iEntID[client]);
		return Plugin_Handled;
	}

	if (argc < 1) {
		ReplyToCommand(client, "[SM] Usage: sm_addhp <health>");
		return Plugin_Handled;
	}

	char szName[64], szType[64], arg[8];
	int health, max;

	GetEntityClassname(simplehud.iEntID[client], szType, sizeof(szType));
	GetEntPropString(simplehud.iEntID[client], Prop_Data, "m_iName", szName, sizeof(szName));
	GetCmdArg(1, arg, sizeof(arg));
	SetVariantInt(StringToInt(arg));

	if (StrEqual(szType, "math_counter", false)) {
		health = GetCounterValue(simplehud.iEntID[client]);

		if (GetTrieValue(EntityMaxes, szName, max) && max != RoundFloat(GetEntPropFloat(simplehud.iEntID[client], Prop_Data, "m_flMax")))
			AcceptEntityInput(simplehud.iEntID[client], "Subtract", client, client);
		else
			AcceptEntityInput(simplehud.iEntID[client], "Add", client, client);

		CPrintToChat(client, "%t", "Health added", StringToInt(arg), health, health + StringToInt(arg));
	} else {
		health = GetEntProp(simplehud.iEntID[client], Prop_Data, "m_iHealth");
		AcceptEntityInput(simplehud.iEntID[client], "AddHealth", client, client);
		CPrintToChat(client, "%t", "Health added", StringToInt(arg), health, health + StringToInt(arg));
	}

	return Plugin_Handled;
}