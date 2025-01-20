#pragma semicolon               1
#pragma newdecls                required

#include <sourcemod>
#include <nativevotes_rework>
#include <colors>

#undef REQUIRE_PLUGIN
#include <l4d2_changelevel>
#define REQUIRE_PLUGIN


public Plugin myinfo =
{
    name =        "VoteMap",
    author =      "TouchMe",
    description = "The plugin adds the ability to vote for a company change",
    version =     "build_0000",
    url =         "https://github.com/TouchMe-Inc/l4d2_votemap"
}


#define LIB_CHANGELEVEL            "l4d2_changelevel" /*< Lib changelevel */

#define CONFIG_PATH                "configs/votemap.txt"

#define TRANSLATIONS               "votemap.phrases"

#define MAX_MAP_FILENAME_LENGTH    32
#define MAX_MAP_DISPLAYNAME_LENGTH 64

#define TEAM_SPECTATE              1

#define VOTE_TIME                  15


bool g_bChangeLevelAvailable = false; /*< true if LIB_CHANGELEVEL exist */

enum struct MapInfo
{
    char filename[MAX_MAP_FILENAME_LENGTH];
    char displayname[MAX_MAP_DISPLAYNAME_LENGTH];
}

StringMap g_smMapsForGamemodes = null; /*< Map: "versus" => [1 => "c1m1_hotel"] */

int g_iTargetMapIndex = 0;

ConVar g_cvGamemode = null; /*< sv_gamemode */

char g_szGamemode[16]; /*< cache for sv_gamemode */


/**
  * Global event. Called when all plugins loaded.
  */
public void OnAllPluginsLoaded() {
    g_bChangeLevelAvailable = LibraryExists(LIB_CHANGELEVEL);
}

/**
  * Global event. Called when a library is removed.
  *
  * @param sName     Library name
  */
public void OnLibraryRemoved(const char[] sName)
{
    if (StrEqual(sName, LIB_CHANGELEVEL)) {
        g_bChangeLevelAvailable = false;
    }
}

/**
  * Global event. Called when a library is added.
  *
  * @param sName     Library name
  */
public void OnLibraryAdded(const char[] sName)
{
    if (StrEqual(sName, LIB_CHANGELEVEL)) {
        g_bChangeLevelAvailable = true;
    }
}

/**
 * Called before OnPluginStart.
 */
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_smMapsForGamemodes = ReadConfig(CONFIG_PATH);

    // Load translations.
    LoadTranslations(TRANSLATIONS);

    RegConsoleCmd("sm_votemap", Cmd_VoteMap);

    g_cvGamemode = FindConVar("mp_gamemode");
    HookConVarChange(g_cvGamemode, CvChange_Gamemode);
    GetConVarString(g_cvGamemode, g_szGamemode, sizeof(g_szGamemode));
}

/**
 * Called when a console variable value is changed.
 */
void CvChange_Gamemode(ConVar hConVar, const char[] sOldGameMode, const char[] sNewGameMode) {
    strcopy(g_szGamemode, sizeof(g_szGamemode), sNewGameMode);
}

StringMap ReadConfig(char[] szPathToConfig)
{
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), szPathToConfig);

    if (!FileExists(sPath)) {
        SetFailState("Couldn't load %s", sPath);
    }

    KeyValues kvConfig = new KeyValues("Gamemodes");

    if (!kvConfig.ImportFromFile(sPath)) {
        SetFailState("Failed to parse keyvalues for %s", sPath);
    }

    StringMap smMapsForGamemodes = new StringMap();

    if (!kvConfig.GotoFirstSubKey()) {
        return smMapsForGamemodes;
    }

    char szGamemode[16];
    MapInfo map;

    do
    {
        kvConfig.GetSectionName(szGamemode, sizeof(szGamemode));
        kvConfig.Rewind();

        if (!kvConfig.JumpToKey(szGamemode) || !kvConfig.GotoFirstSubKey(false)) {
            continue;
        }

        ArrayList aMapsForGamemode = new ArrayList(sizeof(MapInfo));

        do
        {
            kvConfig.GetSectionName(map.filename, sizeof(map.filename));
            kvConfig.GetString(NULL_STRING, map.displayname, sizeof(map.displayname));
            aMapsForGamemode.PushArray(map);
        } while (kvConfig.GotoNextKey(false));

        kvConfig.GoBack();
        smMapsForGamemodes.SetValue(szGamemode, aMapsForGamemode);
    } while (kvConfig.GotoNextKey());

    return smMapsForGamemodes;
}

/**
 * When a player wants to find out whos becoming tank,
 * output to them.
 */
Action Cmd_VoteMap(int iClient, int args)
{
    if (!iClient || IsClientSpectator(iClient)) {
        return Plugin_Continue;
    }

    ShowVoteMapMenu(iClient);

    return Plugin_Handled;
}

void ShowVoteMapMenu(int iClient)
{
    ArrayList aMapsForGamemode;
    if (!g_smMapsForGamemodes.GetValue(g_szGamemode, aMapsForGamemode)) {
        return;
    }

    Menu hMenu = CreateMenu(HandlerShowVoteMapMenu, MenuAction_Select|MenuAction_End);

    SetMenuTitle(hMenu, "%T", "MENU_TITLE", iClient);

    MapInfo map;
    char szIdx[8];
    char szDisplayName[MAX_MAP_DISPLAYNAME_LENGTH];
    int iSize = aMapsForGamemode.Length;
    for (int iIdx = 0; iIdx < iSize; iIdx++)
    {
        IntToString(iIdx, szIdx, sizeof(szIdx));
        aMapsForGamemode.GetArray(iIdx, map);

        if (TranslationPhraseExists(map.displayname)) {
            FormatEx(szDisplayName, sizeof(szDisplayName), "%T", map.displayname, iClient);
            AddMenuItem(hMenu, szIdx, szDisplayName);
        } else {
            AddMenuItem(hMenu, szIdx, map.displayname);
        }
    }

    DisplayMenu(hMenu, iClient, -1);
}

public int HandlerShowVoteMapMenu(Menu hMenu, MenuAction hAction, int iClient, int iItem)
{
    switch(hAction)
    {
        case MenuAction_End: CloseHandle(hMenu);

        case MenuAction_Select:
        {
            char szIdx[8];
            GetMenuItem(hMenu, iItem, szIdx, sizeof(szIdx));

            int iIdx = StringToInt(szIdx);

            if (!RunVoteByClient(iClient, iIdx)) {
                ShowVoteMapMenu(iClient);
            }
        }
    }

    return 0;
}

bool RunVoteByClient(int iClient, int iIdx)
{
    if (!NativeVotes_IsNewVoteAllowed())
    {
        CPrintToChat(iClient, "%T%T", "TAG", iClient, "VOTE_COULDOWN", iClient, NativeVotes_CheckVoteDelay());
        return false;
    }

    g_iTargetMapIndex = iIdx;

    int iTotalPlayers;
    int[] iPlayers = new int[MaxClients];

    for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer ++)
    {
        if (!IsClientInGame(iPlayer) || IsFakeClient(iPlayer) || IsClientSpectator(iPlayer)) {
            continue;
        }

        iPlayers[iTotalPlayers++] = iPlayer;
    }

    NativeVote hVote = new NativeVote(HandlerVoteMatchStart, NativeVotesType_Custom_YesNo);
    hVote.Initiator = iClient;

    hVote.DisplayVote(iPlayers, iTotalPlayers, VOTE_TIME);

    return true;
}

/**
 * Called when a vote action is completed.
 *
 * @param hVote             The vote being acted upon.
 * @param tAction           The action of the vote.
 * @param iParam1           First action parameter.
 * @param iParam2           Second action parameter.
 */
Action HandlerVoteMatchStart(NativeVote hVote, VoteAction tAction, int iParam1, int iParam2)
{
    switch (tAction)
    {
        case VoteAction_Display:
        {
            ArrayList aMapsForGamemode;
            g_smMapsForGamemodes.GetValue(g_szGamemode, aMapsForGamemode);

            MapInfo map;
            aMapsForGamemode.GetArray(g_iTargetMapIndex, map);

            int iClient = iParam1;

            char sVoteDisplayMessage[128];
            if (TranslationPhraseExists(map.displayname)) {
                char szDisplayName[MAX_MAP_DISPLAYNAME_LENGTH];
                FormatEx(szDisplayName, sizeof(szDisplayName), "%T", map.displayname, iClient);
                FormatEx(sVoteDisplayMessage, sizeof(sVoteDisplayMessage), "%T", "VOTE_TITLE", iClient, szDisplayName);
            } else {
                FormatEx(sVoteDisplayMessage, sizeof(sVoteDisplayMessage), "%T", "VOTE_TITLE", iClient, map.displayname);
            }

            hVote.SetDetails(sVoteDisplayMessage);

            return Plugin_Changed;
        }

        case VoteAction_Finish:
        {
            if (iParam1 == NATIVEVOTES_VOTE_NO)
            {
                hVote.DisplayFail();

                return Plugin_Continue;
            }

            hVote.DisplayPass();

            CreateTimer(1.0, Timer_ChangeMap, .flags = TIMER_FLAG_NO_MAPCHANGE);
        }

        case VoteAction_Cancel: hVote.DisplayFail();

        case VoteAction_End: hVote.Close();
    }

    return Plugin_Continue;
}

Action Timer_ChangeMap(Handle hTimer)
{
    ArrayList aMapsForGamemode;
    g_smMapsForGamemodes.GetValue(g_szGamemode, aMapsForGamemode);

    MapInfo map;
    aMapsForGamemode.GetArray(g_iTargetMapIndex, map);

    ChangeMap(map.filename);

    return Plugin_Stop;
}

/**
 *
 */
bool IsClientSpectator(int iClient) {
    return (GetClientTeam(iClient) == TEAM_SPECTATE);
}

void ChangeMap(char[] szMap)
{
    if (g_bChangeLevelAvailable) {
        L4D2_ChangeLevel(szMap);
    } else {
        ServerCommand("changelevel %s", szMap);
    }
}
