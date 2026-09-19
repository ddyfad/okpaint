#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <profiler>
#include <shavit/core>

// Optional: without StaticProps, nonsolid static props can't be painted.
#undef REQUIRE_EXTENSIONS
#include <StaticProps>
#define REQUIRE_EXTENSIONS

// Optional: finds the showbrushes prop standing in for a trigger or clip.
#tryinclude <showbrushes>

#define PLUGIN_VERSION "1.0.0"
#define CHAT_LOADED_COUNT "\x0700FF00"
#define CHAT_ERASED_COUNT "\x07FF6B6B"
#define PAINT_COLOUR_DEFAULT 1
#define PAINT_LOAD_DELAY 0.50
#define PAINT_CLIENT_READY_DELAY 2.00
#define PAINT_CLEAR_SETTLE_DELAY 0.10
#define PAINT_REDRAW_DELAY 0.12
#define PAINT_DECALS_PER_FRAME 48
#define PAINT_GRID_SIZE 128.0
#define PAINT_MAX_ERASE_RADIUS 56.0
#define PAINT_ERASE_HINT_TICKS 16
#define PAINT_MAX_SQL_ROWS 4096
#define PAINT_ENTRY_SIZE 13
#define PAINT_NOSOLID_RANGE 8192.0
#define PAINT_EF_NODRAW 32
#define PAINT_SIZE_LAYOUT_VERSION 3

enum PaintEntry
{
    PaintEntry_Id,
    PaintEntry_InsertToken,
    PaintEntry_X,
    PaintEntry_Y,
    PaintEntry_Z,
    PaintEntry_NormalX,
    PaintEntry_NormalY,
    PaintEntry_NormalZ,
    PaintEntry_Colour,
    PaintEntry_Size,
    PaintEntry_Hitbox,
    PaintEntry_HammerId,
    PaintEntry_Alive
};

char g_sColourNames[][] =
{
    "Random", "White", "Black", "Blue", "Light Blue", "Brown", "Cyan", "Green",
    "Dark Green", "Red", "Orange", "Yellow", "Pink", "Light Pink", "Purple"
};

char g_sColourFiles[][] =
{
    "", "paint_white", "paint_black", "paint_blue", "paint_lightblue", "paint_brown", "paint_cyan", "paint_green",
    "paint_darkgreen", "paint_red", "paint_orange", "paint_yellow", "paint_pink", "paint_lightpink", "paint_purple"
};

char g_sColourChatCodes[][] =
{
    "", "\x07FFFFFF", "\x07000000", "\x073D6EFF", "\x0767D8FF", "\x07A56B43", "\x0700FFFF", "\x074CAF50",
    "\x07006400", "\x07FF3030", "\x07FFA500", "\x07FFE600", "\x07FF69B4", "\x07FFB6C1", "\x07B26CFF"
};

char g_sSizeNames[][] = {"Small", "Medium", "Large"};
char g_sSizeSuffixes[][] = {"", "_med", "_large"};

public Plugin myinfo =
{
    name = "okpaint",
    author = "zas & daf",
    description = "Reliable persistent personal map decals for Counter-Strike: Source",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDatabase;
ConVar g_cvDatabase;
ConVar g_cvLimit;
ConVar g_cvEnabled;
ConVar g_cvEntityDecals;
ConVar g_cvNoSolid;
ConVar g_cvDebug;
ConVar g_cvStaticProps;
ConVar g_cvClips;
ConVar g_cvProxyOffset;
ConVar g_cvDisplacements;
ConVar g_cvProxyFlip;
ConVar g_cvProxyRay;
ConVar g_cvProxySpacing;
ConVar g_cvFlushToWorld;
bool g_bStaticProps;
bool g_bShowBrushes;
bool g_bPaintInside[MAXPLAYERS + 1];

// Nonsolid displacements are dropped by three engine checks. These get patched
// out for the length of one trace only.
#define PAINT_DISP_PATCHES 3
Address g_aDispPatch[PAINT_DISP_PATCHES];
int g_iDispPatchLen[PAINT_DISP_PATCHES];
int g_iDispOriginal[PAINT_DISP_PATCHES][6];
bool g_bDispPatchReady;
bool g_bDispPatched;
// Why a paint tick produced nothing, counted per stroke.
int g_iStrokeTicks[MAXPLAYERS + 1];
int g_iStrokeNoSurface[MAXPLAYERS + 1];
int g_iStrokeTooClose[MAXPLAYERS + 1];
int g_iStrokeNoRoute[MAXPLAYERS + 1];
int g_iStrokeDrawn[MAXPLAYERS + 1];
int g_iStrokeRedraws[MAXPLAYERS + 1];
int g_iStrokeBrushHit[MAXPLAYERS + 1];
int g_iStrokeBrushMiss[MAXPLAYERS + 1];
float g_fStrokeTime[MAXPLAYERS + 1];
float g_fStrokeMaxTick[MAXPLAYERS + 1];
Profiler g_hProfiler;

Cookie g_ckColour;
Cookie g_ckSize;
Cookie g_ckSizeLayout;

int g_iSprites[sizeof(g_sColourNames) - 1][sizeof(g_sSizeNames)];
int g_iColour[MAXPLAYERS + 1];
int g_iSize[MAXPLAYERS + 1];
int g_iLiveCount[MAXPLAYERS + 1];
int g_iGeneration[MAXPLAYERS + 1];
int g_iRenderOffset[MAXPLAYERS + 1];
int g_iLastEraseTick[MAXPLAYERS + 1];
int g_iLastEraseHintTick[MAXPLAYERS + 1];
int g_iErasedThisSession[MAXPLAYERS + 1];
int g_iStolenCount[MAXPLAYERS + 1];
int g_iStrokeColour[MAXPLAYERS + 1];
int g_iRandomNextColour[MAXPLAYERS + 1];
int g_iNextInsertToken;

bool g_bDatabaseReady;
bool g_bLoadRequested[MAXPLAYERS + 1];
bool g_bLoadTimerPending[MAXPLAYERS + 1];
bool g_bLoaded[MAXPLAYERS + 1];
bool g_bPainting[MAXPLAYERS + 1];
bool g_bErasing[MAXPLAYERS + 1];
bool g_bRenderActive[MAXPLAYERS + 1];
bool g_bRenderQueued[MAXPLAYERS + 1];
bool g_bRenderAgain[MAXPLAYERS + 1];
bool g_bEraseRedrawPending[MAXPLAYERS + 1];
bool g_bRenderStolenPaint[MAXPLAYERS + 1];

float g_fRenderAt[MAXPLAYERS + 1];

ArrayList g_hPaints[MAXPLAYERS + 1];
StringMap g_hGrid[MAXPLAYERS + 1];
ArrayList g_hGridBuckets[MAXPLAYERS + 1];
ArrayList g_hStolenPaints[MAXPLAYERS + 1];
StringMap g_hStolenGrid[MAXPLAYERS + 1];
ArrayList g_hStolenGridBuckets[MAXPLAYERS + 1];
StringMap g_hCancelledInsertTokens;

char g_sMap[PLATFORM_MAX_PATH];
int g_iMapSerial;
ArrayList g_hNoSolidHits;
StringMap g_hHammerIds;
int g_iHammerIdsSerial = -1;
chatstrings_t g_ChatStrings;

public void Shavit_OnChatConfigLoaded()
{
    Shavit_GetChatStringsStruct(g_ChatStrings);
}

void RefreshChatStrings()
{
    Shavit_GetChatStringsStruct(g_ChatStrings);
}

void PrintPaint(int client, const char[] format, any ...)
{
    char message[256];
    VFormat(message, sizeof(message), format, 3);
    RefreshChatStrings();
    ReplaceString(message, sizeof(message), "{pink}", g_ChatStrings.sVariable, false);
    ReplaceString(message, sizeof(message), "{text}", g_ChatStrings.sText, false);
    ReplaceString(message, sizeof(message), "{green}", g_ChatStrings.sVariable2, false);
    Shavit_PrintToChat(client, "%s", message);
}

void PrintPaintLoaded(int client, int count)
{
    if (count < 1)
    {
        return;
    }

    RefreshChatStrings();
    Shavit_PrintToChat(client, "Loaded %s%d%s decals.",
        CHAT_LOADED_COUNT,
        count,
        g_ChatStrings.sText);
}

void PrintPaintErased(int client, int count)
{
    RefreshChatStrings();
    Shavit_PrintToChat(client, "Erased %s%d%s decal%s.",
        CHAT_ERASED_COUNT,
        count,
        g_ChatStrings.sText,
        count == 1 ? "" : "s");
}

void PrintPaintColourSelected(int client, int colour)
{
    RefreshChatStrings();

    if (colour == 0)
    {
        Shavit_PrintToChat(client, "Paint Colour: %s%s%s.", g_ChatStrings.sVariable2, g_sColourNames[colour], g_ChatStrings.sText);
        return;
    }

    Shavit_PrintToChat(client, "Paint Colour: %s%s%s.", g_sColourChatCodes[colour], g_sColourNames[colour], g_ChatStrings.sText);
}

void PrintPaintSizeSelected(int client, int size)
{
    RefreshChatStrings();
    Shavit_PrintToChat(client, "Paint Size: %s%s%s.", g_ChatStrings.sVariable, g_sSizeNames[size], g_ChatStrings.sText);
}

// The last value r_maxmodeldecal was seen at, -1 until the query answers.
int g_iMaxModelDecal[MAXPLAYERS + 1];

// reset false re-asks without blanking the old value, so the menu doesn't flicker
void ApplyPaintDecalLimits(int client, bool reset = true)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    // Can't set it: the decal cvars lack FCVAR_SERVER_CAN_EXECUTE. Read only.
    if (reset)
    {
        g_iMaxModelDecal[client] = -1;
    }
    QueryClientConVar(client, "r_maxmodeldecal", OnMaxModelDecalQueried);
}

public void OnMaxModelDecalQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
    if (result == ConVarQuery_Okay && IsClientInGame(client))
    {
        g_iMaxModelDecal[client] = StringToInt(cvarValue);
    }
}

// Low enough that paint on props and triggers vanishes as fast as it is drawn.
bool WantsMoreDecals(int client)
{
    return g_iMaxModelDecal[client] > 0 && g_iMaxModelDecal[client] <= 50;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("GetTotalNumberOfStaticProps");
    MarkNativeAsOptional("GetIndexesOfStaticPropsOverlappingAABB");
    MarkNativeAsOptional("StaticProp_GetOrigin");
    MarkNativeAsOptional("StaticProp_GetAngles");
    MarkNativeAsOptional("StaticProp_GetOBBBounds");
    return APLRes_Success;
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "showbrushes"))
    {
        g_bShowBrushes = true;
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "showbrushes"))
    {
        g_bShowBrushes = false;
    }
}

public void OnAllPluginsLoaded()
{
    g_bShowBrushes = LibraryExists("showbrushes");
    g_bStaticProps = GetFeatureStatus(FeatureType_Native, "GetTotalNumberOfStaticProps") == FeatureStatus_Available;
    if (!g_bStaticProps)
    {
        LogMessage("okpaint: StaticProps extension not present, nonsolid static props will not be paintable.");
    }
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_hCancelledInsertTokens = new StringMap();
    g_hNoSolidHits = new ArrayList();
    SetupDisplacementPatches();
    g_hProfiler = new Profiler();

    g_cvDatabase = CreateConVar("sm_okpaint_database", "storage-local", "Database entry in databases.cfg.");
    g_cvLimit = CreateConVar("sm_okpaint_limit", "2048", "Maximum saved decals per player and map.", FCVAR_NONE, true, 1.0, true, float(PAINT_MAX_SQL_ROWS));
    g_cvEnabled = CreateConVar("sm_okpaint_enabled", "1", "Allow players to paint.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvEntityDecals = CreateConVar("sm_okpaint_entity_decals", "1", "Use Entity Decal for world and solid displacement surfaces.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvNoSolid = CreateConVar("sm_okpaint_nosolid", "1", "Also paint on nonsolid map entities such as triggers, clips and func_brush.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("sm_okpaint_debug", "0", "Log every decal sent to the server console.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvStaticProps = CreateConVar("sm_okpaint_staticprops", "1", "Also paint on nonsolid static props. Needs the StaticProps extension.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvProxyOffset = CreateConVar("sm_okpaint_proxy_offset", "4.0", "How far in front of the surface the proxy decal ray starts. The engine extends the ray 10% past the surface, so keep this small or thin brushes get their far face painted too.", FCVAR_NONE, true, 1.0, true, 64.0);
    g_cvProxyRay = CreateConVar("sm_okpaint_proxy_ray", "0", "Project proxy decals along the surface normal (0, deterministic, redraws reproduce the same decal) or the player's line of sight (1).", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvProxyFlip = CreateConVar("sm_okpaint_proxy_flip", "1", "Start the proxy decal ray just behind the surface. CS:S paints the faces whose normals point along the ray, so this is what lands paint on the face being looked at. Measured in game; leave on.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvFlushToWorld = CreateConVar("sm_okpaint_flush_to_world", "1", "Paint the wall behind a trigger or clip brush when the two are flush, so the stroke is not held to the client's per model decal limit.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvProxySpacing = CreateConVar("sm_okpaint_proxy_spacing", "0.28", "Spacing between decals on a showbrushes proxy, as a fraction of the erase radius. The client only keeps 50 decals per model, so they have to be spread to cover anything.", FCVAR_NONE, true, 0.05, true, 1.0);
    g_cvDisplacements = CreateConVar("sm_okpaint_displacements", "1", "Also paint on nonsolid displacements. Needs the engine checks patched for the length of each trace; turns itself off if the engine does not match.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvClips = CreateConVar("sm_okpaint_clips", "1", "Also paint on clip and nodraw brushes, drawn on the showbrushes proxy props.", FCVAR_NONE, true, 0.0, true, 1.0);
    AutoExecConfig(true, "okpaint");

    g_ckColour = RegClientCookie("okpaint_colour", "okpaint colour", CookieAccess_Protected);
    g_ckSize = RegClientCookie("okpaint_size", "okpaint size", CookieAccess_Protected);
    g_ckSizeLayout = RegClientCookie("okpaint_size_layout", "okpaint size layout version", CookieAccess_Protected);

    RegConsoleCmd("+paint", Command_PaintStart);
    RegConsoleCmd("-paint", Command_PaintStop);
    RegConsoleCmd("+erasepaint", Command_EraseStart);
    RegConsoleCmd("-erasepaint", Command_EraseStop);
    RegConsoleCmd("sm_paint", Command_PaintMenu);
    RegConsoleCmd("sm_paintcolour", Command_ColourMenu);
    RegConsoleCmd("sm_paintcolor", Command_ColourMenu);
    RegConsoleCmd("sm_paintsize", Command_SizeMenu);
    RegConsoleCmd("sm_clearpaint", Command_ClearPaint);
    RegConsoleCmd("sm_stealpaint", Command_StealPaint);

    GetCurrentMap(g_sMap, sizeof(g_sMap));
    g_iMapSerial = 1;
    PrecachePaintDecals();
    ConnectDatabase();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            InitializeClient(client);
        }
    }
}

public void OnMapStart()
{
    g_iMapSerial++;
    GetCurrentMap(g_sMap, sizeof(g_sMap));
    PrecachePaintDecals();

    if (g_hHammerIds != null)
    {
        g_hHammerIds.Clear();
    }
    g_iHammerIdsSerial = -1;

    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClientPaint(client, true);
        g_bLoadRequested[client] = IsClientInGame(client) && !IsFakeClient(client);
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        ScheduleClientLoad(client);
    }
}

public void OnConfigsExecuted()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            ScheduleClientLoad(client);
        }
    }
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsFakeClient(client))
    {
        InitializeClient(client);
    }
}

public void OnClientCookiesCached(int client)
{
    char value[12];

    GetClientCookie(client, g_ckColour, value, sizeof(value));
    if (value[0] != '\0')
    {
        g_iColour[client] = ClampColour(StringToInt(value));
        if (!IsSelectablePaintColour(g_iColour[client]))
        {
            g_iColour[client] = PAINT_COLOUR_DEFAULT;
            SetClientCookieInt(client, g_ckColour, g_iColour[client]);
        }
    }

    GetClientCookie(client, g_ckSize, value, sizeof(value));
    if (value[0] != '\0')
    {
        g_iSize[client] = ClampSize(StringToInt(value));

        char layoutVersion[8];
        GetClientCookie(client, g_ckSizeLayout, layoutVersion, sizeof(layoutVersion));
        int savedLayout = StringToInt(layoutVersion);
        if (savedLayout < PAINT_SIZE_LAYOUT_VERSION)
        {
            g_iSize[client] = ConvertSavedSize(g_iSize[client], savedLayout);
            SetClientCookieInt(client, g_ckSize, g_iSize[client]);
            SetClientCookieInt(client, g_ckSizeLayout, PAINT_SIZE_LAYOUT_VERSION);
        }
    }
}

public void OnClientDisconnect(int client)
{
    g_bLoadRequested[client] = false;
    g_bLoadTimerPending[client] = false;
    ResetClientPaint(client, true);
}

void InitializeClient(int client)
{
    g_iColour[client] = PAINT_COLOUR_DEFAULT;
    g_iSize[client] = 0;
    g_iStrokeColour[client] = 0;
    g_iRandomNextColour[client] = 1;

    if (AreClientCookiesCached(client))
    {
        OnClientCookiesCached(client);
    }

    RememberClientProfile(client);
    ScheduleClientLoad(client);
}

void ConnectDatabase()
{
    char databaseName[64];
    g_cvDatabase.GetString(databaseName, sizeof(databaseName));
    Database.Connect(SQL_OnDatabaseConnected, databaseName);
}

public void SQL_OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        SetFailState("okpaint database connection failed: %s", error);
        return;
    }

    g_hDatabase = db;

    char driver[32];
    db.Driver.GetIdentifier(driver, sizeof(driver));

    char query[1024];
    if (StrEqual(driver, "sqlite", false))
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_decals (id INTEGER PRIMARY KEY AUTOINCREMENT, steamid TEXT NOT NULL, map TEXT NOT NULL, pos_x REAL NOT NULL, pos_y REAL NOT NULL, pos_z REAL NOT NULL, normal_x REAL NOT NULL, normal_y REAL NOT NULL, normal_z REAL NOT NULL, colour INTEGER NOT NULL, size INTEGER NOT NULL, hitbox INTEGER NOT NULL DEFAULT 0, hammerid INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)");
    }
    else
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_decals (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, steamid VARCHAR(64) NOT NULL, map VARCHAR(255) NOT NULL, pos_x FLOAT NOT NULL, pos_y FLOAT NOT NULL, pos_z FLOAT NOT NULL, normal_x FLOAT NOT NULL, normal_y FLOAT NOT NULL, normal_z FLOAT NOT NULL, colour INT NOT NULL, size INT NOT NULL, hitbox INT NOT NULL DEFAULT 0, hammerid INT NOT NULL DEFAULT 0, created_at INT NOT NULL, INDEX okpaint_owner_map (steamid, map))");
    }
    db.Query(SQL_SchemaCallback, query, 1);

    if (StrEqual(driver, "sqlite", false))
    {
        db.Query(SQL_SchemaCallback, "CREATE INDEX IF NOT EXISTS okpaint_owner_map ON okpaint_decals (steamid, map, id)");
    }

}

public void SQL_SchemaCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        SetFailState("okpaint database schema failed: %s", error);
        return;
    }

    if (data != 1)
    {
        return;
    }

    db.Query(SQL_NormalColumnsCallback, "SELECT normal_x, normal_y, normal_z FROM okpaint_decals LIMIT 1");
}

public void SQL_NormalColumnsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results != null)
    {
        EnsureHitboxColumn();
        return;
    }

    Transaction transaction = new Transaction();
    transaction.AddQuery("ALTER TABLE okpaint_decals ADD COLUMN normal_x REAL NOT NULL DEFAULT 0");
    transaction.AddQuery("ALTER TABLE okpaint_decals ADD COLUMN normal_y REAL NOT NULL DEFAULT 0");
    transaction.AddQuery("ALTER TABLE okpaint_decals ADD COLUMN normal_z REAL NOT NULL DEFAULT 0");
    db.Execute(transaction, SQL_NormalColumnsUpgradeSuccess, SQL_NormalColumnsUpgradeFailure);
}

public void SQL_NormalColumnsUpgradeSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    EnsureHitboxColumn();
}

public void SQL_NormalColumnsUpgradeFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    SetFailState("okpaint schema upgrade failed at query %d: %s", failIndex, error);
}

void EnsureHitboxColumn()
{
    g_hDatabase.Query(SQL_HitboxColumnsCallback, "SELECT hitbox FROM okpaint_decals LIMIT 1");
}

public void SQL_HitboxColumnsCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results != null)
    {
        EnsureHammerIdColumn();
        return;
    }

    Transaction transaction = new Transaction();
    transaction.AddQuery("ALTER TABLE okpaint_decals ADD COLUMN hitbox INTEGER NOT NULL DEFAULT 0");
    db.Execute(transaction, SQL_HitboxColumnsUpgradeSuccess, SQL_HitboxColumnsUpgradeFailure);
}

public void SQL_HitboxColumnsUpgradeSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    EnsureHammerIdColumn();
}

public void SQL_HitboxColumnsUpgradeFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    SetFailState("okpaint hitbox schema upgrade failed at query %d: %s", failIndex, error);
}

void EnsureHammerIdColumn()
{
    g_hDatabase.Query(SQL_HammerIdColumnCallback, "SELECT hammerid FROM okpaint_decals LIMIT 1");
}

public void SQL_HammerIdColumnCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results != null)
    {
        CreatePlayerTable();
        return;
    }

    Transaction transaction = new Transaction();
    transaction.AddQuery("ALTER TABLE okpaint_decals ADD COLUMN hammerid INTEGER NOT NULL DEFAULT 0");
    db.Execute(transaction, SQL_HammerIdColumnUpgradeSuccess, SQL_HammerIdColumnUpgradeFailure);
}

public void SQL_HammerIdColumnUpgradeSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    CreatePlayerTable();
}

public void SQL_HammerIdColumnUpgradeFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    SetFailState("okpaint hammerid schema upgrade failed at query %d: %s", failIndex, error);
}

void CreatePlayerTable()
{
    char driver[32];
    g_hDatabase.Driver.GetIdentifier(driver, sizeof(driver));

    char query[512];
    if (StrEqual(driver, "sqlite", false))
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_players (steamid TEXT PRIMARY KEY, last_name TEXT NOT NULL, updated_at INTEGER NOT NULL)");
    }
    else
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_players (steamid VARCHAR(64) NOT NULL PRIMARY KEY, last_name VARCHAR(128) NOT NULL, updated_at INT NOT NULL)");
    }

    g_hDatabase.Query(SQL_PlayerTableCallback, query);
}

public void SQL_PlayerTableCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        SetFailState("okpaint player table creation failed: %s", error);
        return;
    }

    CreateSizeLayoutTable();
}

void CreateSizeLayoutTable()
{
    char driver[32];
    g_hDatabase.Driver.GetIdentifier(driver, sizeof(driver));

    char query[512];
    if (StrEqual(driver, "sqlite", false))
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_meta (setting TEXT PRIMARY KEY, layout_version INTEGER NOT NULL)");
    }
    else
    {
        FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS okpaint_meta (setting VARCHAR(64) NOT NULL PRIMARY KEY, layout_version INT NOT NULL)");
    }
    g_hDatabase.Query(SQL_SizeLayoutTableCallback, query);
}

public void SQL_SizeLayoutTableCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        SetFailState("okpaint size layout table creation failed: %s", error);
        return;
    }
    db.Query(SQL_SizeLayoutCallback, "SELECT layout_version FROM okpaint_meta WHERE setting = 'paint_size_layout'");
}

public void SQL_SizeLayoutCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        SetFailState("okpaint size layout check failed: %s", error);
        return;
    }

    if (results.FetchRow() && results.FetchInt(0) >= PAINT_SIZE_LAYOUT_VERSION)
    {
        MarkDatabaseReady();
        return;
    }

    Transaction transaction = new Transaction();
    transaction.AddQuery("UPDATE okpaint_decals SET size = CASE size WHEN 0 THEN 0 WHEN 1 THEN 0 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 2 ELSE 0 END");
    transaction.AddQuery("REPLACE INTO okpaint_meta (setting, layout_version) VALUES ('paint_size_layout', 3)");
    db.Execute(transaction, SQL_SizeLayoutMigrationSuccess, SQL_SizeLayoutMigrationFailure);
}

public void SQL_SizeLayoutMigrationSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    MarkDatabaseReady();
}

public void SQL_SizeLayoutMigrationFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    SetFailState("okpaint size layout migration failed at query %d: %s", failIndex, error);
}

void MarkDatabaseReady()
{
    g_bDatabaseReady = true;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && g_bLoadRequested[client])
        {
            RememberClientProfile(client);
            ScheduleClientLoad(client);
        }
    }
}

void RememberClientProfile(int client)
{
    if (!g_bDatabaseReady || g_hDatabase == null || !IsClientInGame(client) || IsFakeClient(client) || !IsClientAuthorized(client))
    {
        return;
    }

    char steamId[64], name[MAX_NAME_LENGTH], escapedSteamId[128], escapedName[MAX_NAME_LENGTH * 2 + 1];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
    GetClientName(client, name, sizeof(name));
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(name, escapedName, sizeof(escapedName));

    char query[512];
    FormatEx(query, sizeof(query), "REPLACE INTO okpaint_players (steamid, last_name, updated_at) VALUES ('%s', '%s', %d)", escapedSteamId, escapedName, GetTime());
    g_hDatabase.Query(SQL_GenericCallback, query);
}

void PrecachePaintDecals()
{
    AddFileToDownloadsTable("materials/paint/paint_decal.vtf");

    char material[PLATFORM_MAX_PATH];
    for (int colour = 1; colour < sizeof(g_sColourNames); colour++)
    {
        for (int size = 0; size < sizeof(g_sSizeNames); size++)
        {
            FormatEx(material, sizeof(material), "paint/%s%s.vmt", g_sColourFiles[colour], g_sSizeSuffixes[size]);
            g_iSprites[colour - 1][size] = PrecachePaint(material, true);
            FormatEx(material, sizeof(material), "materials/paint/%s%s.vmt", g_sColourFiles[colour], g_sSizeSuffixes[size]);
            AddFileToDownloadsTable(material);
        }
    }
}

int PrecachePaint(const char[] material, bool preload)
{
    return PrecacheDecal(material, preload);
}

void ScheduleClientLoad(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    g_bLoadRequested[client] = true;
    if (g_bLoadTimerPending[client])
    {
        return;
    }

    g_bLoadTimerPending[client] = true;
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iMapSerial);
    pack.WriteString(g_sMap);
    CreateTimer(PAINT_CLIENT_READY_DELAY, Timer_ScheduleClientLoad, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ScheduleClientLoad(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int mapSerial = pack.ReadCell();
    char map[PLATFORM_MAX_PATH];
    pack.ReadString(map, sizeof(map));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0)
    {
        return Plugin_Stop;
    }

    g_bLoadTimerPending[client] = false;
    if (mapSerial != g_iMapSerial || !StrEqual(map, g_sMap) || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }

    RequestClientLoad(client);
    return Plugin_Stop;
}

void RequestClientLoad(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    g_bLoadRequested[client] = true;
    if (!g_bDatabaseReady || !IsClientAuthorized(client))
    {
        return;
    }

    ResetClientPaint(client, false);
    g_bLoadRequested[client] = false;

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iGeneration[client]);
    pack.WriteString(g_sMap);
    CreateTimer(PAINT_LOAD_DELAY, Timer_LoadClientPaint, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_LoadClientPaint(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int generation = pack.ReadCell();
    char map[PLATFORM_MAX_PATH];
    pack.ReadString(map, sizeof(map));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || generation != g_iGeneration[client] || !StrEqual(map, g_sMap))
    {
        return Plugin_Stop;
    }

    char steamId[64], escapedSteamId[128], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(map, escapedMap, sizeof(escapedMap));

    char query[768];
    FormatEx(query, sizeof(query), "SELECT id, pos_x, pos_y, pos_z, normal_x, normal_y, normal_z, hitbox, hammerid, colour, size FROM okpaint_decals WHERE steamid = '%s' AND map = '%s' ORDER BY id ASC LIMIT %d", escapedSteamId, escapedMap, PAINT_MAX_SQL_ROWS);

    DataPack queryPack = new DataPack();
    queryPack.WriteCell(userid);
    queryPack.WriteCell(generation);
    queryPack.WriteString(map);
    g_hDatabase.Query(SQL_LoadPaintCallback, query, queryPack);
    return Plugin_Stop;
}

public void SQL_LoadPaintCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int generation = pack.ReadCell();
    char map[PLATFORM_MAX_PATH];
    pack.ReadString(map, sizeof(map));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || generation != g_iGeneration[client] || !StrEqual(map, g_sMap))
    {
        return;
    }

    if (results == null)
    {
        LogError("okpaint load failed: %s", error);
        PrintPaint(client, "Could not load your paint. See server logs.");
        return;
    }

    int limit = g_cvLimit.IntValue;
    while (results.FetchRow() && g_iLiveCount[client] < limit)
    {
        float position[3];
        position[0] = results.FetchFloat(1);
        position[1] = results.FetchFloat(2);
        position[2] = results.FetchFloat(3);
        float normal[3];
        normal[0] = results.FetchFloat(4);
        normal[1] = results.FetchFloat(5);
        normal[2] = results.FetchFloat(6);
        AddCacheEntry(client, results.FetchInt(0), position, normal, results.FetchInt(7), results.FetchInt(8), ClampColour(results.FetchInt(9)), ClampSize(results.FetchInt(10)));
    }

    g_bLoaded[client] = true;
    if (g_iLiveCount[client] > 0)
    {
        QueuePaintRedraw(client, 0.0);
    }

    PrintPaintLoaded(client, g_iLiveCount[client]);
}

public Action Command_PaintStart(int client, int args)
{
    if (!CanEditPaint(client))
    {
        return Plugin_Handled;
    }

    if (g_bErasing[client])
    {
        PrintPaint(client, "Stop erasing before painting.");
        return Plugin_Handled;
    }

    ApplyPaintDecalLimits(client);
    g_iStrokeTicks[client] = 0;
    g_iStrokeNoSurface[client] = 0;
    g_iStrokeTooClose[client] = 0;
    g_iStrokeNoRoute[client] = 0;
    g_iStrokeDrawn[client] = 0;
    g_iStrokeRedraws[client] = 0;
    g_iStrokeBrushHit[client] = 0;
    g_iStrokeBrushMiss[client] = 0;
    g_fStrokeTime[client] = 0.0;
    g_fStrokeMaxTick[client] = 0.0;
    g_bPainting[client] = true;
    g_iStrokeColour[client] = 0;
        PaintFromCrosshair(client);
    return Plugin_Handled;
}

public Action Command_PaintStop(int client, int args)
{
    if (client > 0 && client <= MaxClients && g_bPainting[client])
    {
        PaintFromCrosshair(client);
    }

    if (client > 0 && client <= MaxClients)
    {
        g_bPainting[client] = false;
        g_iStrokeColour[client] = 0;

        if (g_cvDebug.BoolValue && g_iStrokeTicks[client] > 0)
        {
            PrintToServer("[okpaint] stroke: %d ticks, %d drawn, %d no surface, %d too close, %d no route, %d redraws | showbrushes %d, brush hit %d of %d asked | %.2f ms total, %.0f us avg, %.0f us max tick",
                g_iStrokeTicks[client], g_iStrokeDrawn[client], g_iStrokeNoSurface[client],
                g_iStrokeTooClose[client], g_iStrokeNoRoute[client], g_iStrokeRedraws[client],
                g_bShowBrushes, g_iStrokeBrushHit[client], g_iStrokeBrushMiss[client],
                g_fStrokeTime[client] * 1000.0,
                g_iStrokeTicks[client] > 0 ? g_fStrokeTime[client] * 1000000.0 / float(g_iStrokeTicks[client]) : 0.0,
                g_fStrokeMaxTick[client] * 1000000.0);
        }
    }
    return Plugin_Handled;
}

public Action Command_EraseStart(int client, int args)
{
    if (!CanEditPaint(client))
    {
        return Plugin_Handled;
    }

    g_bPainting[client] = false;
    BeginErasing(client);
    PrintPaint(client, "Eraser enabled. Hold your bind and point at your paint.");
    return Plugin_Handled;
}

public Action Command_EraseStop(int client, int args)
{
    if (client > 0 && client <= MaxClients)
    {
        FinishErasing(client);
    }
    return Plugin_Handled;
}

public Action Command_PaintMenu(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
    {
        ShowPaintMenu(client);
    }
    return Plugin_Handled;
}

public Action Command_ColourMenu(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
    {
        ShowColourMenu(client);
    }
    return Plugin_Handled;
}

public Action Command_SizeMenu(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
    {
        ShowSizeMenu(client);
    }
    return Plugin_Handled;
}

public Action Command_ClearPaint(int client, int args)
{
    if (!CanManagePaint(client))
    {
        return Plugin_Handled;
    }

    ShowClearConfirmMenu(client);
    return Plugin_Handled;
}

public Action Command_StealPaint(int client, int args)
{
    if (!CanManagePaint(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ShowStealMenu(client);
        return Plugin_Handled;
    }

    char targetName[MAX_TARGET_LENGTH];
    GetCmdArgString(targetName, sizeof(targetName));
    TrimString(targetName);

    int matchedClient;
    int matches;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || IsFakeClient(target) || !IsClientAuthorized(target))
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(target, name, sizeof(name));
        if (StrContains(name, targetName, false) != -1)
        {
            matchedClient = target;
            matches++;
        }
    }

    if (matches == 1)
    {
        char steamId[64];
        GetClientAuthId(matchedClient, AuthId_Steam2, steamId, sizeof(steamId), true);
        BeginStealPaintBySteamId(client, steamId);
        return Plugin_Handled;
    }

    QueryStealOwners(client, targetName);
    return Plugin_Handled;
}

void ShowStealMenu(int client)
{
    QueryStealOwners(client, "");
}

void QueryStealOwners(int client, const char[] nameFilter)
{
    if (!CanManagePaint(client))
    {
        return;
    }

    char steamId[64], escapedSteamId[128], escapedMap[PLATFORM_MAX_PATH * 2 + 1], escapedFilter[MAX_TARGET_LENGTH * 2 + 1];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(g_sMap, escapedMap, sizeof(escapedMap));

    char query[1024];
    if (nameFilter[0] == '\0')
    {
        FormatEx(query, sizeof(query), "SELECT DISTINCT d.steamid, COALESCE(p.last_name, d.steamid) FROM okpaint_decals d LEFT JOIN okpaint_players p ON p.steamid = d.steamid WHERE d.map = '%s' AND d.steamid != '%s' ORDER BY 2 ASC LIMIT 128", escapedMap, escapedSteamId);
    }
    else
    {
        g_hDatabase.Escape(nameFilter, escapedFilter, sizeof(escapedFilter));
        FormatEx(query, sizeof(query), "SELECT DISTINCT d.steamid, COALESCE(p.last_name, d.steamid) FROM okpaint_decals d LEFT JOIN okpaint_players p ON p.steamid = d.steamid WHERE d.map = '%s' AND d.steamid != '%s' AND (p.last_name LIKE '%%%s%%' OR d.steamid LIKE '%%%s%%') ORDER BY 2 ASC LIMIT 128", escapedMap, escapedSteamId, escapedFilter, escapedFilter);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(g_sMap);
    pack.WriteString(nameFilter);
    g_hDatabase.Query(SQL_StealMenuCallback, query, pack);
}

public void SQL_StealMenuCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    char map[PLATFORM_MAX_PATH], nameFilter[MAX_TARGET_LENGTH];
    pack.ReadString(map, sizeof(map));
    pack.ReadString(nameFilter, sizeof(nameFilter));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !StrEqual(map, g_sMap))
    {
        return;
    }

    if (results == null)
    {
        LogError("okpaint steal menu query failed: %s", error);
        PrintPaint(client, "Could not list saved paint.");
        return;
    }

    Menu menu = new Menu(StealMenuHandler);
    menu.SetTitle("Steal paint");

    int count = 0;
    while (results.FetchRow())
    {
        char ownerSteamId[64], ownerName[MAX_NAME_LENGTH];
        results.FetchString(0, ownerSteamId, sizeof(ownerSteamId));
        results.FetchString(1, ownerName, sizeof(ownerName));
        menu.AddItem(ownerSteamId, ownerName);
        count++;
    }

    if (count == 0)
    {
        menu.AddItem("", nameFilter[0] == '\0' ? "No saved paint on this map" : "No matching saved paint", ITEMDRAW_DISABLED);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

bool CanEditPaint(int client)
{
    if (!CanManagePaint(client) || !IsPlayerAlive(client))
    {
        return false;
    }

    return true;
}

bool CanManagePaint(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    if (!g_cvEnabled.BoolValue)
    {
        PrintPaint(client, "Paint is disabled.");
        return false;
    }

    if (!g_bDatabaseReady || !g_bLoaded[client])
    {
        PrintPaint(client, "Your paint is still loading.");
        return false;
    }

    return true;
}

public void OnGameFrame()
{
    float now = GetGameTime();
    int tick = GetGameTickCount();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            g_bPainting[client] = false;
            FinishErasing(client, false);
            g_iStrokeColour[client] = 0;
        }

        if (g_bPainting[client])
        {
            g_hProfiler.Start();
            PaintFromCrosshair(client);
            g_hProfiler.Stop();

            float tickTime = g_hProfiler.Time;
            g_fStrokeTime[client] += tickTime;
            if (tickTime > g_fStrokeMaxTick[client])
            {
                g_fStrokeMaxTick[client] = tickTime;
            }
        }

        if (g_bErasing[client] && tick - g_iLastEraseTick[client] >= 2)
        {
            g_iLastEraseTick[client] = tick;
            EraseFromCrosshair(client);
        }

        if (g_bRenderQueued[client] && !g_bRenderActive[client] && now >= g_fRenderAt[client])
        {
            BeginPaintRedraw(client);
        }
    }
}

void PaintFromCrosshair(int client)
{
    if (!CanEditPaint(client))
    {
        g_bPainting[client] = false;
        return;
    }

    g_iStrokeTicks[client]++;

    float position[3], normal[3];
    int hitbox, hammerid;
    bool displacement;
    if (!TracePaintSurface(client, position, normal, hitbox, hammerid, displacement))
    {
        g_iStrokeNoSurface[client]++;
        return;
    }

    // Proxy decals are capped per model, so space them further apart.
    bool proxy = g_bShowBrushes && hammerid != 0 && ShowBrushes_GetProxyForBrush(client, hammerid) > 0;

    if (HasNearbyPaint(client, position, normal, g_iSize[client], displacement, proxy))
    {
        g_iStrokeTooClose[client]++;
        return;
    }

    int totalPaint = g_iLiveCount[client] + g_iStolenCount[client];
    if (totalPaint >= g_cvLimit.IntValue)
    {
        if (totalPaint == g_cvLimit.IntValue)
        {
            PrintPaint(client, "You reached the map limit of {green}%d{text} decals.", g_cvLimit.IntValue);
        }
        g_bPainting[client] = false;
        return;
    }

    int colour = g_iColour[client];
    if (colour == 0)
    {
        colour = GetStrokeRandomColour(client);
    }
    int size = g_iSize[client];

    if (g_iStolenCount[client] > 0)
    {
        CommitStolenPaint(client);
    }

    // Don't save paint that was never drawn (usually no proxy on the brush).
    if (!SendDecal(client, position, normal, hitbox, hammerid, colour, size))
    {
        g_iStrokeNoRoute[client]++;
        return;
    }

    g_iStrokeDrawn[client]++;

    int index = AddCacheEntry(client, 0, position, normal, hitbox, hammerid, colour, size);
    QueueInsertPaint(client, index);

}

float PaintDuplicateRadius(int client, int size, bool displacement, bool proxy)
{
    if (proxy)
    {
        // Decals cover area, so spacing shrinks by the sqrt of the raised limit.
        float spacing = g_cvProxySpacing.FloatValue;
        int limit = g_iMaxModelDecal[client];
        if (limit > 50)
        {
            spacing *= SquareRoot(50.0 / float(limit));
            if (spacing < 0.05)
            {
                spacing = 0.05;
            }
        }
        return EraseRadius(ClampSize(size)) * spacing;
    }

    if (displacement)
    {
        // Displacements have a small decal budget; overlapping evicts older paint.
        return EraseRadius(ClampSize(size)) * 0.40;
    }

    // World solids only reject essentially identical placements, not strokes.
    return 3.0 + 3.0 * float(ClampSize(size));
}

bool HasNearbyPaint(int client, const float position[3], const float normal[3], int size, bool displacement, bool proxy)
{
    if (g_hPaints[client] == null || g_hGrid[client] == null)
    {
        return false;
    }

    float searchRadius = PaintDuplicateRadius(client, size, displacement, proxy) + PaintDuplicateRadius(client, sizeof(g_sSizeNames) - 1, displacement, proxy);
    int lo[3], hi[3];
    for (int axis = 0; axis < 3; axis++)
    {
        lo[axis] = RoundToFloor((position[axis] - searchRadius) / PAINT_GRID_SIZE);
        hi[axis] = RoundToFloor((position[axis] + searchRadius) / PAINT_GRID_SIZE);
    }

    char key[48];
    for (int x = lo[0]; x <= hi[0]; x++)
    {
        for (int y = lo[1]; y <= hi[1]; y++)
        {
            for (int z = lo[2]; z <= hi[2]; z++)
            {
                FormatEx(key, sizeof(key), "%d.%d.%d", x, y, z);
                ArrayList bucket;
                if (!g_hGrid[client].GetValue(key, bucket))
                {
                    continue;
                }

                for (int item = 0; item < bucket.Length; item++)
                {
                    any entry[PaintEntry];
                    g_hPaints[client].GetArray(bucket.Get(item), entry, sizeof(entry));
                    if (!entry[PaintEntry_Alive])
                    {
                        continue;
                    }

                    float decalNormal[3];
                    decalNormal[0] = entry[PaintEntry_NormalX];
                    decalNormal[1] = entry[PaintEntry_NormalY];
                    decalNormal[2] = entry[PaintEntry_NormalZ];
                    if (GetVectorLength(decalNormal) > 0.1 && GetVectorDotProduct(normal, decalNormal) < 0.98)
                    {
                        continue;
                    }

                    float decalPosition[3];
                    decalPosition[0] = entry[PaintEntry_X];
                    decalPosition[1] = entry[PaintEntry_Y];
                    decalPosition[2] = entry[PaintEntry_Z];
                    float duplicateRadius = PaintDuplicateRadius(client, size, displacement, proxy);
                    float existingRadius = PaintDuplicateRadius(client, entry[PaintEntry_Size], displacement, proxy);
                    if (existingRadius > duplicateRadius)
                    {
                        duplicateRadius = existingRadius;
                    }
                    if (GetVectorDistance(position, decalPosition) < duplicateRadius)
                    {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

int GetStrokeRandomColour(int client)
{
    if (g_iStrokeColour[client] > 0)
    {
        return g_iStrokeColour[client];
    }

    int colour = g_iRandomNextColour[client];
    if (colour < 1 || colour >= sizeof(g_sColourNames))
    {
        colour = 1;
    }

    while (!IsSelectablePaintColour(colour))
    {
        colour++;
        if (colour >= sizeof(g_sColourNames))
        {
            colour = 1;
        }
    }

    g_iStrokeColour[client] = colour;
    g_iRandomNextColour[client] = colour + 1;
    while (g_iRandomNextColour[client] >= sizeof(g_sColourNames) || !IsSelectablePaintColour(g_iRandomNextColour[client]))
    {
        g_iRandomNextColour[client]++;
        if (g_iRandomNextColour[client] >= sizeof(g_sColourNames))
        {
            g_iRandomNextColour[client] = 1;
        }
    }

    return colour;
}

float EraseRadius(int size)
{
    return 24.0 + 16.0 * float(size);
}

bool TracePaintSurface(int client, float position[3], float normal[3], int &hitbox, int &hammerid, bool &displacement)
{
    float origin[3], angles[3];
    GetClientEyePosition(client, origin);
    GetClientEyeAngles(client, angles);

    hitbox = 0;
    hammerid = 0;
    displacement = false;

    bool hit = false;
    float distance = 0.0;

    bool patchDisplacements = g_bDispPatchReady && g_cvDisplacements.BoolValue;
    if (patchDisplacements)
    {
        PatchDisplacements(true);
    }

    TR_TraceRayFilter(origin, angles, MASK_SHOT, RayType_Infinite, TraceFilter_NoPlayers);

    if (patchDisplacements)
    {
        PatchDisplacements(false);
    }

    if (TR_DidHit())
    {
        TR_GetEndPosition(position);
        TR_GetPlaneNormal(null, normal);
        hitbox = TR_GetHitBoxIndex();
        if (hitbox < 0)
        {
            hitbox = 0;
        }
        displacement = TR_GetDisplacementFlags() != 0;
        distance = GetVectorDistance(origin, position);
        hit = true;

        // Brush entities need the decal addressed to them, not the world.
        int worldEntity = TR_GetEntityIndex();
        if (worldEntity > 0 && HasEntProp(worldEntity, Prop_Data, "m_iHammerID"))
        {
            hammerid = GetEntProp(worldEntity, Prop_Data, "m_iHammerID");
        }
    }

    float nearPosition[3], nearNormal[3], nearDistance;
    int nearHammerId, nearHitbox;
    if (g_cvNoSolid.BoolValue && TraceNoSolidSurface(origin, angles, nearPosition, nearNormal, nearDistance, nearHammerId, nearHitbox)
        && (!hit || nearDistance < distance))
    {
        position = nearPosition;
        normal = nearNormal;
        hitbox = nearHitbox;
        hammerid = nearHammerId;
        displacement = false;
        distance = nearDistance;
        hit = true;
    }

    float propPosition[3], propNormal[3], propDistance;
    int propIndex;
    if (g_bStaticProps && g_cvStaticProps.BoolValue
        && TraceStaticProp(origin, angles, hit ? distance : PAINT_NOSOLID_RANGE, propPosition, propNormal, propDistance, propIndex)
        && (!hit || propDistance < distance))
    {
        // Static props aren't entities: world decal, prop index in m_nHitbox.
        position = propPosition;
        normal = propNormal;
        hitbox = propIndex + 1;
        hammerid = 0;
        displacement = false;
        distance = propDistance;
        hit = true;
    }

    if (g_bShowBrushes && g_cvClips.BoolValue)
    {
        g_iStrokeBrushMiss[client]++;
        float brushPosition[3], brushNormal[3];
        int brushId;
        bool brushInside;
        if (ShowBrushes_TraceBrush(client, brushPosition, brushNormal, brushId, brushInside) > 0 && brushId != 0)
        {
            g_iStrokeBrushHit[client]++;
            // Keep the normal outward; the engine paints faces that face the ray start.
            // A drawn brush flush with the world wins a tie, within the native's 1u reach.
            float brushDistance = GetVectorDistance(origin, brushPosition);
            // Flush on the world: paint the world instead. Same look, no 50-per-model cap.
            bool flush = hit && g_cvFlushToWorld.BoolValue && hitbox == 0 && !displacement
                && FloatAbs(brushDistance - distance) <= 2.0
                && GetVectorDotProduct(brushNormal, normal) > 0.98;
            if (!flush && (!hit || brushDistance <= distance + 1.0))
            {
                // brushId is stable across maps; SendDecal resolves it to the current prop.
                position = brushPosition;
                normal = brushNormal;
                hitbox = 0;
                hammerid = brushId;
                g_bPaintInside[client] = brushInside;
                displacement = false;
                distance = brushDistance;
                hit = true;
            }
        }
    }

    return hit;
}

// Collision-off static props are invisible to rays, so ask the static prop
// manager what the ray crosses.
bool TraceStaticProp(const float origin[3], const float angles[3], float range, float position[3], float normal[3], float &distance, int &propIndex)
{
    int total = GetTotalNumberOfStaticProps();
    if (total <= 0)
    {
        return false;
    }

    float direction[3], end[3], mins[3], maxs[3];
    GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);
    end = direction;
    ScaleVector(end, range);
    AddVectors(origin, end, end);

    for (int i = 0; i < 3; i++)
    {
        mins[i] = ((origin[i] < end[i]) ? origin[i] : end[i]) - 8.0;
        maxs[i] = ((origin[i] > end[i]) ? origin[i] : end[i]) + 8.0;
    }

    int[] indexes = new int[total];
    int found = GetIndexesOfStaticPropsOverlappingAABB(indexes, total, mins, maxs);

    bool hit = false;
    for (int item = 0; item < found; item++)
    {
        int index = indexes[item];

        float propOrigin[3], propAngles[3], obbMins[3], obbMaxs[3];
        if (!StaticProp_GetOrigin(index, propOrigin) || !StaticProp_GetAngles(index, propAngles)
            || !StaticProp_GetOBBBounds(index, obbMins, obbMaxs))
        {
            continue;
        }

        float hitDistance, hitNormal[3];
        if (!RayHitsOBB(origin, direction, propOrigin, propAngles, obbMins, obbMaxs, range, hitDistance, hitNormal))
        {
            continue;
        }

        if (hit && hitDistance >= distance)
        {
            continue;
        }

        distance = hitDistance;
        normal = hitNormal;
        propIndex = index;
        hit = true;
    }

    if (hit)
    {
        position = direction;
        ScaleVector(position, distance);
        AddVectors(origin, position, position);
    }

    return hit;
}

// Slab test on an oriented box. Source's right vector runs along -Y.
bool RayHitsOBB(const float origin[3], const float direction[3], const float propOrigin[3], const float propAngles[3], const float mins[3], const float maxs[3], float range, float &distance, float normal[3])
{
    float fwd[3], right[3], up[3], delta[3];
    GetAngleVectors(propAngles, fwd, right, up);
    SubtractVectors(origin, propOrigin, delta);

    float localOrigin[3], localDir[3];
    localOrigin[0] = GetVectorDotProduct(delta, fwd);
    localOrigin[1] = -GetVectorDotProduct(delta, right);
    localOrigin[2] = GetVectorDotProduct(delta, up);
    localDir[0] = GetVectorDotProduct(direction, fwd);
    localDir[1] = -GetVectorDotProduct(direction, right);
    localDir[2] = GetVectorDotProduct(direction, up);

    float tMin = 0.0, tMax = range;
    int axis = -1;
    bool atMaxFace = false;

    for (int i = 0; i < 3; i++)
    {
        if (FloatAbs(localDir[i]) < 0.000001)
        {
            if (localOrigin[i] < mins[i] || localOrigin[i] > maxs[i])
            {
                return false;
            }
            continue;
        }

        float inverse = 1.0 / localDir[i];
        float tNear = (mins[i] - localOrigin[i]) * inverse;
        float tFar = (maxs[i] - localOrigin[i]) * inverse;
        bool flipped = false;

        if (tNear > tFar)
        {
            float swap = tNear;
            tNear = tFar;
            tFar = swap;
            flipped = true;
        }

        if (tNear > tMin)
        {
            tMin = tNear;
            axis = i;
            atMaxFace = flipped;
        }

        if (tFar < tMax)
        {
            tMax = tFar;
        }

        if (tMin > tMax)
        {
            return false;
        }
    }

    // No entry face: the ray started inside the box.
    if (axis < 0 || tMin <= 0.0)
    {
        return false;
    }

    float localNormal[3];
    localNormal[axis] = atMaxFace ? 1.0 : -1.0;

    for (int i = 0; i < 3; i++)
    {
        normal[i] = localNormal[0] * fwd[i] - localNormal[1] * right[i] + localNormal[2] * up[i];
    }
    NormalizeVector(normal, normal);

    distance = tMin;
    return true;
}

// Nonsolid brushes aren't in the solid partition; enumerate and clip each.
bool TraceNoSolidSurface(const float origin[3], const float angles[3], float position[3], float normal[3], float &distance, int &hammerid, int &hitbox)
{
    float direction[3], end[3];
    GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(direction, PAINT_NOSOLID_RANGE);
    AddVectors(origin, direction, end);

    g_hNoSolidHits.Clear();
    TR_EnumerateEntities(origin, end, PARTITION_NON_STATIC_EDICTS, RayType_EndPoint, EnumerateNoSolid);

    bool found = false;
    for (int item = 0; item < g_hNoSolidHits.Length; item++)
    {
        int entity = g_hNoSolidHits.Get(item);
        if (!IsValidEntity(entity))
        {
            continue;
        }

        // Self-drawn brushes only; showbrushes proxies go through its natives.
        int id = GetEntProp(entity, Prop_Data, "m_iHammerID");
        if (id <= 0 || !IsEntityDrawn(entity))
        {
            continue;
        }

        TR_ClipRayToEntity(origin, angles, MASK_ALL, RayType_Infinite, entity);

        // Inside a zone trigger a forward clip hits nothing, so clip toward the eye.
        bool inside = TR_StartSolid();
        if (inside)
        {
            TR_ClipRayToEntity(end, origin, MASK_ALL, RayType_EndPoint, entity);
        }

        if (!TR_DidHit() || TR_StartSolid())
        {
            continue;
        }

        float hitPosition[3];
        TR_GetEndPosition(hitPosition);
        float hitDistance = GetVectorDistance(origin, hitPosition);
        if (found && hitDistance >= distance)
        {
            continue;
        }

        float hitNormal[3];
        TR_GetPlaneNormal(null, hitNormal);
        if (inside)
        {
            // The reverse clip reports the face pointing away from the player.
            NegateVector(hitNormal);
        }

        // Needed for studio models (nonsolid prop_dynamic), ignored for brushes.
        int hitHitbox = TR_GetHitBoxIndex();

        position = hitPosition;
        normal = hitNormal;
        distance = hitDistance;
        hammerid = id;
        hitbox = (hitHitbox > 0) ? hitHitbox : 0;
        found = true;
    }

    return found;
}

public bool EnumerateNoSolid(int entity, any data)
{
    if (entity > MaxClients && IsValidEntity(entity) && HasEntProp(entity, Prop_Data, "m_iHammerID"))
    {
        g_hNoSolidHits.Push(entity);
    }

    return true;
}

// Not every entity has m_fEffects (func_dustmotes); reading it blind throws.
bool IsEntityDrawn(int entity)
{
    if (!HasEntProp(entity, Prop_Send, "m_fEffects"))
    {
        return true;
    }

    return (GetEntProp(entity, Prop_Send, "m_fEffects") & PAINT_EF_NODRAW) == 0;
}

// Checks the bytes of all three branches first; any mismatch disables the
// feature instead of patching.
void SetupDisplacementPatches()
{
    Handle config = LoadGameConfigFile("okpaint.games");
    if (config == null)
    {
        LogMessage("okpaint: no gamedata, nonsolid displacements will not be paintable.");
        return;
    }

    Address traceToLeaf = GameConfGetAddress(config, "CM_TraceToLeaf_POINT");
    Address aabbRay = GameConfGetAddress(config, "CDispCollTree::AABBTree_Ray");
    delete config;

    if (traceToLeaf == Address_Null || aabbRay == Address_Null)
    {
        LogMessage("okpaint: could not find the displacement trace functions, nonsolid displacements will not be paintable.");
        return;
    }

    // CM_TraceToLeaf contents test, then AABBTree_Ray raytest flag and contents.
    g_aDispPatch[0] = traceToLeaf + view_as<Address>(0x37D);
    g_iDispPatchLen[0] = 2;
    int expected0[] = {0x74, 0x70};

    g_aDispPatch[1] = aabbRay + view_as<Address>(0x7F);
    g_iDispPatchLen[1] = 6;
    int expected1[] = {0x0F, 0x85, 0x8B, 0x00, 0x00, 0x00};

    g_aDispPatch[2] = aabbRay + view_as<Address>(0x91);
    g_iDispPatchLen[2] = 2;
    int expected2[] = {0x74, 0x7F};

    for (int patch = 0; patch < PAINT_DISP_PATCHES; patch++)
    {
        for (int i = 0; i < g_iDispPatchLen[patch]; i++)
        {
            int actual = LoadFromAddress(g_aDispPatch[patch] + view_as<Address>(i), NumberType_Int8);
            int want = patch == 0 ? expected0[i] : (patch == 1 ? expected1[i] : expected2[i]);
            if (actual != want)
            {
                LogMessage("okpaint: engine byte %d of displacement patch %d is 0x%02X, expected 0x%02X. Not patching.", i, patch, actual, want);
                return;
            }
            g_iDispOriginal[patch][i] = actual;
        }
    }

    g_bDispPatchReady = true;
}

void PatchDisplacements(bool patched)
{
    if (!g_bDispPatchReady || g_bDispPatched == patched)
    {
        return;
    }

    g_bDispPatched = patched;
    for (int patch = 0; patch < PAINT_DISP_PATCHES; patch++)
    {
        for (int i = 0; i < g_iDispPatchLen[patch]; i++)
        {
            // nop, so the branch falls through.
            StoreToAddress(g_aDispPatch[patch] + view_as<Address>(i),
                patched ? 0x90 : g_iDispOriginal[patch][i], NumberType_Int8);
        }
    }
}

// Entity indexes are not stable across a map load, Hammer IDs are.
int FindEntityByHammerId(int hammerid)
{
    if (hammerid <= 0)
    {
        return 0;
    }

    if (g_hHammerIds == null || g_iHammerIdsSerial != g_iMapSerial)
    {
        BuildHammerIdCache();
    }

    char key[12];
    int entity;
    IntToString(hammerid, key, sizeof(key));
    if (!g_hHammerIds.GetValue(key, entity) || !IsValidEntity(entity))
    {
        return 0;
    }

    return entity;
}

void BuildHammerIdCache()
{
    if (g_hHammerIds == null)
    {
        g_hHammerIds = new StringMap();
    }

    g_hHammerIds.Clear();
    g_iHammerIdsSerial = g_iMapSerial;

    char key[12];
    int maxEntities = GetMaxEntities();
    for (int entity = MaxClients + 1; entity < maxEntities; entity++)
    {
        if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Data, "m_iHammerID"))
        {
            continue;
        }

        int hammerid = GetEntProp(entity, Prop_Data, "m_iHammerID");
        if (hammerid <= 0)
        {
            continue;
        }

        IntToString(hammerid, key, sizeof(key));
        g_hHammerIds.SetValue(key, entity, false);
    }
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
    return entity == 0 || entity > MaxClients;
}

bool SendDecal(int client, const float position[3], const float normal[3], int hitbox, int hammerid, int colour, int size)
{
    colour = ClampColour(colour);
    size = ClampSize(size);
    if (colour == 0)
    {
        colour = PAINT_COLOUR_DEFAULT;
    }

    int entity = 0;
    bool viaProxy = false;
    if (hammerid != 0)
    {
        // A showbrushes prop takes the decal if one draws the brush, otherwise the
        // self-drawn brush entity. Neither: the brush is hidden, don't paint behind it.
        if (g_bShowBrushes)
        {
            entity = ShowBrushes_GetProxyForBrush(client, hammerid);
            viaProxy = entity > 0;
        }

        if (entity <= 0 && hammerid > 0)
        {
            entity = FindEntityByHammerId(hammerid);
        }

        if (entity <= 0)
        {
            return false;
        }
    }

    if (entity > 0 || (g_cvEntityDecals.BoolValue && GetVectorLength(normal) > 0.1))
    {
        // Start just off the surface along the normal so redraws match. Proxy brushes
        // are thin and stacked, so a far start lands on the wrong face.
        float start[3], offset[3];
        // The decal lands on the face opposite the start; standing inside flips that.
        float scale = viaProxy ? g_cvProxyOffset.FloatValue : 64.0;
        if (viaProxy && g_cvProxyFlip.BoolValue != g_bPaintInside[client])
        {
            scale = -scale;
        }

        // CS:S paints studio-model faces whose normals point ALONG the ray (measured
        // 2026-09-18; the leaked source says otherwise). Start just behind the surface.
        if (viaProxy && g_cvProxyRay.BoolValue)
        {
            // Point at the eye like the normal, so the flip below works for both.
            float eye[3];
            GetClientEyePosition(client, eye);
            SubtractVectors(eye, position, offset);
            NormalizeVector(offset, offset);
        }
        else
        {
            offset = normal;
        }

        ScaleVector(offset, scale);
        AddVectors(position, offset, start);

        if (viaProxy && g_cvDebug.BoolValue)
        {
            PrintToServer("[okpaint] proxy ent %d brush %d inside %d scale %.1f | hit %.1f %.1f %.1f | normal %.2f %.2f %.2f | start %.1f %.1f %.1f",
                entity, hammerid, g_bPaintInside[client], scale,
                position[0], position[1], position[2],
                normal[0], normal[1], normal[2],
                start[0], start[1], start[2]);
        }

        TE_Start("Entity Decal");
        TE_WriteVector("m_vecOrigin", position);
        TE_WriteVector("m_vecStart", start);
        TE_WriteNum("m_nEntity", entity);
        TE_WriteNum("m_nHitbox", hitbox);
        TE_WriteNum("m_nIndex", g_iSprites[colour - 1][size]);
    }
    else
    {
        TE_Start("World Decal");
        TE_WriteVector("m_vecOrigin", position);
        TE_WriteNum("m_nIndex", g_iSprites[colour - 1][size]);
    }
    TE_SendToClient(client);
    return true;
}

int AddCacheEntry(int client, int id, const float position[3], const float normal[3], int hitbox, int hammerid, int colour, int size)
{
    if (g_hPaints[client] == null)
    {
        g_hPaints[client] = new ArrayList(PAINT_ENTRY_SIZE);
    }

    any entry[PaintEntry];
    entry[PaintEntry_Id] = id;
    entry[PaintEntry_InsertToken] = 0;
    entry[PaintEntry_X] = position[0];
    entry[PaintEntry_Y] = position[1];
    entry[PaintEntry_Z] = position[2];
    entry[PaintEntry_NormalX] = normal[0];
    entry[PaintEntry_NormalY] = normal[1];
    entry[PaintEntry_NormalZ] = normal[2];
    entry[PaintEntry_Colour] = colour;
    entry[PaintEntry_Size] = size;
    entry[PaintEntry_Hitbox] = hitbox;
    entry[PaintEntry_HammerId] = hammerid;
    entry[PaintEntry_Alive] = 1;

    int index = g_hPaints[client].PushArray(entry, sizeof(entry));
    AddGridEntry(client, position, index);
    g_iLiveCount[client]++;
    return index;
}

void CommitStolenPaint(int client)
{
    ArrayList stolenPaints = g_hStolenPaints[client];
    if (stolenPaints == null || g_iStolenCount[client] == 0)
    {
        return;
    }

    for (int item = 0; item < stolenPaints.Length; item++)
    {
        any entry[PaintEntry];
        stolenPaints.GetArray(item, entry, sizeof(entry));
        if (!entry[PaintEntry_Alive])
        {
            continue;
        }

        float position[3], normal[3];
        position[0] = entry[PaintEntry_X];
        position[1] = entry[PaintEntry_Y];
        position[2] = entry[PaintEntry_Z];
        normal[0] = entry[PaintEntry_NormalX];
        normal[1] = entry[PaintEntry_NormalY];
        normal[2] = entry[PaintEntry_NormalZ];

        int index = AddCacheEntry(client, 0, position, normal, entry[PaintEntry_Hitbox], entry[PaintEntry_HammerId], entry[PaintEntry_Colour], entry[PaintEntry_Size]);
        QueueInsertPaint(client, index);
    }

    ResetStolenPaint(client);
    QueuePaintRedraw(client, 0.0);
}

void QueueInsertPaint(int client, int index)
{
    if (g_hDatabase == null || g_hPaints[client] == null)
    {
        return;
    }

    any entry[PaintEntry];
    g_hPaints[client].GetArray(index, entry, sizeof(entry));

    if (entry[PaintEntry_InsertToken] == 0)
    {
        g_iNextInsertToken++;
        if (g_iNextInsertToken <= 0)
        {
            g_iNextInsertToken = 1;
        }

        entry[PaintEntry_InsertToken] = g_iNextInsertToken;
        g_hPaints[client].SetArray(index, entry, sizeof(entry));
    }

    char steamId[64], escapedSteamId[128], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(g_sMap, escapedMap, sizeof(escapedMap));

    char query[640];
    FormatEx(query, sizeof(query), "INSERT INTO okpaint_decals (steamid, map, pos_x, pos_y, pos_z, normal_x, normal_y, normal_z, hitbox, hammerid, colour, size, created_at) VALUES ('%s', '%s', %.6f, %.6f, %.6f, %.5f, %.5f, %.5f, %d, %d, %d, %d, %d)", escapedSteamId, escapedMap, entry[PaintEntry_X], entry[PaintEntry_Y], entry[PaintEntry_Z], entry[PaintEntry_NormalX], entry[PaintEntry_NormalY], entry[PaintEntry_NormalZ], entry[PaintEntry_Hitbox], entry[PaintEntry_HammerId], entry[PaintEntry_Colour], entry[PaintEntry_Size], GetTime());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iGeneration[client]);
    pack.WriteCell(index);
    pack.WriteCell(entry[PaintEntry_InsertToken]);
    g_hDatabase.Query(SQL_InsertPaintCallback, query, pack);
}

void CancelPendingInsert(int insertToken)
{
    if (insertToken <= 0 || g_hCancelledInsertTokens == null)
    {
        return;
    }

    char key[12];
    IntToString(insertToken, key, sizeof(key));
    g_hCancelledInsertTokens.SetValue(key, 1);
}

bool IsInsertCancelled(int insertToken)
{
    if (insertToken <= 0 || g_hCancelledInsertTokens == null)
    {
        return false;
    }

    char key[12];
    int value;
    IntToString(insertToken, key, sizeof(key));
    return g_hCancelledInsertTokens.GetValue(key, value);
}

void ForgetCancelledInsert(int insertToken)
{
    if (insertToken <= 0 || g_hCancelledInsertTokens == null)
    {
        return;
    }

    char key[12];
    IntToString(insertToken, key, sizeof(key));
    g_hCancelledInsertTokens.Remove(key);
}

public void SQL_InsertPaintCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int generation = pack.ReadCell();
    int index = pack.ReadCell();
    int insertToken = pack.ReadCell();
    delete pack;

    if (results == null)
    {
        ForgetCancelledInsert(insertToken);
        LogError("okpaint insert failed: %s", error);
        return;
    }

    int id = results.InsertId;
    if (IsInsertCancelled(insertToken))
    {
        ForgetCancelledInsert(insertToken);
        DeletePaintRow(id);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client <= 0 || generation != g_iGeneration[client] || g_hPaints[client] == null || index >= g_hPaints[client].Length)
    {
        return;
    }

    any entry[PaintEntry];
    g_hPaints[client].GetArray(index, entry, sizeof(entry));
    if (entry[PaintEntry_InsertToken] != insertToken)
    {
        return;
    }
    entry[PaintEntry_Id] = id;
    g_hPaints[client].SetArray(index, entry, sizeof(entry));

    if (!entry[PaintEntry_Alive])
    {
        DeletePaintRow(id);
    }
}

void EraseFromCrosshair(int client)
{
    if (!CanEditPaint(client) || (g_iLiveCount[client] == 0 && g_iStolenCount[client] == 0))
    {
        if (!g_cvEnabled.BoolValue || !g_bLoaded[client])
        {
            g_bErasing[client] = false;
        }
        return;
    }

    float aim[3], aimNormal[3];
    int ignoredHitbox, ignoredHammerId;
    bool ignoredDisplacement;
    if (!TracePaintSurface(client, aim, aimNormal, ignoredHitbox, ignoredHammerId, ignoredDisplacement))
    {
        return;
    }

    if (g_iStolenCount[client] > 0 && (HasErasablePaint(g_hPaints[client], g_hGrid[client], aim, aimNormal) || HasErasablePaint(g_hStolenPaints[client], g_hStolenGrid[client], aim, aimNormal)))
    {
        CommitStolenPaint(client);
    }

    int erased = ErasePaintCache(client, g_hPaints[client], g_hGrid[client], aim, aimNormal, true);
    erased += ErasePaintCache(client, g_hStolenPaints[client], g_hStolenGrid[client], aim, aimNormal, false);
    if (erased <= 0)
    {
        return;
    }

    g_iErasedThisSession[client] += erased;
    g_bEraseRedrawPending[client] = true;
    QueuePaintRedraw(client, PAINT_REDRAW_DELAY);

    int tick = GetGameTickCount();
    if (tick - g_iLastEraseHintTick[client] >= PAINT_ERASE_HINT_TICKS)
    {
        g_iLastEraseHintTick[client] = tick;
        PrintHintText(client, "Erased %d decal%s", g_iErasedThisSession[client], g_iErasedThisSession[client] == 1 ? "" : "s");
    }
}

int ErasePaintCache(int client, ArrayList paints, StringMap grid, const float aim[3], const float aimNormal[3], bool savedPaint)
{
    if (paints == null || grid == null)
    {
        return 0;
    }

    int lo[3], hi[3];
    for (int axis = 0; axis < 3; axis++)
    {
        lo[axis] = RoundToFloor((aim[axis] - PAINT_MAX_ERASE_RADIUS) / PAINT_GRID_SIZE);
        hi[axis] = RoundToFloor((aim[axis] + PAINT_MAX_ERASE_RADIUS) / PAINT_GRID_SIZE);
    }

    int erased = 0;
    char key[48];
    for (int x = lo[0]; x <= hi[0]; x++)
    {
        for (int y = lo[1]; y <= hi[1]; y++)
        {
            for (int z = lo[2]; z <= hi[2]; z++)
            {
                FormatEx(key, sizeof(key), "%d.%d.%d", x, y, z);
                ArrayList bucket;
                if (!grid.GetValue(key, bucket))
                {
                    continue;
                }

                for (int item = 0; item < bucket.Length; item++)
                {
                    int index = bucket.Get(item);
                    any entry[PaintEntry];
                    paints.GetArray(index, entry, sizeof(entry));
                    if (!entry[PaintEntry_Alive])
                    {
                        continue;
                    }

                    if (!IsErasablePaintEntry(entry, aim, aimNormal))
                    {
                        continue;
                    }

                    entry[PaintEntry_Alive] = 0;
                    paints.SetArray(index, entry, sizeof(entry));
                    erased++;

                    if (savedPaint)
                    {
                        g_iLiveCount[client]--;
                        if (entry[PaintEntry_Id] > 0)
                        {
                            DeletePaintRow(entry[PaintEntry_Id]);
                        }
                        else
                        {
                            CancelPendingInsert(entry[PaintEntry_InsertToken]);
                        }
                    }
                    else
                    {
                        g_iStolenCount[client]--;
                    }
                }
            }
        }
    }

    return erased;
}

bool HasErasablePaint(ArrayList paints, StringMap grid, const float aim[3], const float aimNormal[3])
{
    if (paints == null || grid == null)
    {
        return false;
    }

    int lo[3], hi[3];
    for (int axis = 0; axis < 3; axis++)
    {
        lo[axis] = RoundToFloor((aim[axis] - PAINT_MAX_ERASE_RADIUS) / PAINT_GRID_SIZE);
        hi[axis] = RoundToFloor((aim[axis] + PAINT_MAX_ERASE_RADIUS) / PAINT_GRID_SIZE);
    }

    char key[48];
    for (int x = lo[0]; x <= hi[0]; x++)
    {
        for (int y = lo[1]; y <= hi[1]; y++)
        {
            for (int z = lo[2]; z <= hi[2]; z++)
            {
                FormatEx(key, sizeof(key), "%d.%d.%d", x, y, z);
                ArrayList bucket;
                if (!grid.GetValue(key, bucket))
                {
                    continue;
                }

                for (int item = 0; item < bucket.Length; item++)
                {
                    any entry[PaintEntry];
                    paints.GetArray(bucket.Get(item), entry, sizeof(entry));
                    if (entry[PaintEntry_Alive] && IsErasablePaintEntry(entry, aim, aimNormal))
                    {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

bool IsErasablePaintEntry(any entry[PaintEntry], const float aim[3], const float aimNormal[3])
{
    float position[3];
    position[0] = entry[PaintEntry_X];
    position[1] = entry[PaintEntry_Y];
    position[2] = entry[PaintEntry_Z];

    float decalNormal[3];
    decalNormal[0] = entry[PaintEntry_NormalX];
    decalNormal[1] = entry[PaintEntry_NormalY];
    decalNormal[2] = entry[PaintEntry_NormalZ];
    if (GetVectorLength(decalNormal) > 0.1 && GetVectorDotProduct(aimNormal, decalNormal) < 0.90)
    {
        return false;
    }

    float radius = EraseRadius(entry[PaintEntry_Size]) + 4.0;
    return GetVectorDistance(aim, position, true) <= radius * radius;
}

void BeginErasing(int client)
{
    if (!g_bErasing[client])
    {
        g_iErasedThisSession[client] = 0;
        g_bEraseRedrawPending[client] = false;
    }

    g_bErasing[client] = true;
}

void FinishErasing(int client, bool announce = true)
{
    if (!g_bErasing[client])
    {
        return;
    }

    g_bErasing[client] = false;
    if (!g_bEraseRedrawPending[client])
    {
        return;
    }

    g_bEraseRedrawPending[client] = false;
    QueuePaintRedraw(client, PAINT_REDRAW_DELAY);

    if (announce && g_iErasedThisSession[client] > 0)
    {
        PrintPaintErased(client, g_iErasedThisSession[client]);
    }

    g_iErasedThisSession[client] = 0;
}

void DeletePaintRow(int id)
{
    if (g_hDatabase == null || id <= 0)
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query), "DELETE FROM okpaint_decals WHERE id = %d", id);
    g_hDatabase.Query(SQL_GenericCallback, query);
}

void AddGridEntry(int client, const float position[3], int index)
{
    if (g_hGrid[client] == null)
    {
        g_hGrid[client] = new StringMap();
        g_hGridBuckets[client] = new ArrayList();
    }

    char key[48];
    FormatEx(key, sizeof(key), "%d.%d.%d", RoundToFloor(position[0] / PAINT_GRID_SIZE), RoundToFloor(position[1] / PAINT_GRID_SIZE), RoundToFloor(position[2] / PAINT_GRID_SIZE));

    ArrayList bucket;
    if (!g_hGrid[client].GetValue(key, bucket))
    {
        bucket = new ArrayList();
        g_hGrid[client].SetValue(key, bucket);
        g_hGridBuckets[client].Push(bucket);
    }
    bucket.Push(index);
}

void AddStolenGridEntry(int client, const float position[3], int index)
{
    if (g_hStolenGrid[client] == null)
    {
        g_hStolenGrid[client] = new StringMap();
        g_hStolenGridBuckets[client] = new ArrayList();
    }

    char key[48];
    FormatEx(key, sizeof(key), "%d.%d.%d", RoundToFloor(position[0] / PAINT_GRID_SIZE), RoundToFloor(position[1] / PAINT_GRID_SIZE), RoundToFloor(position[2] / PAINT_GRID_SIZE));

    ArrayList bucket;
    if (!g_hStolenGrid[client].GetValue(key, bucket))
    {
        bucket = new ArrayList();
        g_hStolenGrid[client].SetValue(key, bucket);
        g_hStolenGridBuckets[client].Push(bucket);
    }
    bucket.Push(index);
}

void QueuePaintRedraw(int client, float delay)
{
    if (g_bRenderActive[client])
    {
        g_bRenderAgain[client] = true;
        return;
    }

    if (g_bRenderQueued[client])
    {
        return;
    }

    g_bRenderQueued[client] = true;
    g_fRenderAt[client] = GetGameTime() + delay;
}

void BeginPaintRedraw(int client)
{
    if (g_bPainting[client])
    {
        g_iStrokeRedraws[client]++;
    }

    // A redraw re-sends every decal, the one thing here that can burst packets.
    if (g_cvDebug.BoolValue)
    {
        PrintToServer("[okpaint] redraw client %d: %d live, %d stolen, painting %d, erasing %d",
            client, g_iLiveCount[client], g_iStolenCount[client], g_bPainting[client], g_bErasing[client]);
    }

    g_bRenderQueued[client] = false;
    g_bRenderActive[client] = true;
    g_bRenderStolenPaint[client] = false;
    g_iRenderOffset[client] = 0;

    ApplyPaintDecalLimits(client);

    // World decals have no handle: clear and replay the cache to remove one.
    ClientCommand(client, "r_cleardecals");

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iGeneration[client]);
    CreateTimer(PAINT_CLEAR_SETTLE_DELAY, Timer_BeginPaintReplay, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_BeginPaintReplay(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int generation = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && generation == g_iGeneration[client] && g_bRenderActive[client])
    {
        RequestFrame(Frame_DrawPaint, userid);
    }
    return Plugin_Stop;
}

public void Frame_DrawPaint(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !g_bRenderActive[client])
    {
        return;
    }

    int sent = 0;
    while (sent < PAINT_DECALS_PER_FRAME)
    {
        ArrayList paints = g_bRenderStolenPaint[client] ? g_hStolenPaints[client] : g_hPaints[client];
        if (paints == null || g_iRenderOffset[client] >= paints.Length)
        {
            if (!g_bRenderStolenPaint[client])
            {
                g_bRenderStolenPaint[client] = true;
                g_iRenderOffset[client] = 0;
                continue;
            }

            g_bRenderActive[client] = false;
            if (g_bRenderAgain[client])
            {
                g_bRenderAgain[client] = false;
                QueuePaintRedraw(client, PAINT_REDRAW_DELAY);
            }
            return;
        }

        int index = g_iRenderOffset[client];
        for (; index < paints.Length && sent < PAINT_DECALS_PER_FRAME; index++)
        {
            any entry[PaintEntry];
            paints.GetArray(index, entry, sizeof(entry));
            if (!entry[PaintEntry_Alive])
            {
                continue;
            }

            float position[3];
            position[0] = entry[PaintEntry_X];
            position[1] = entry[PaintEntry_Y];
            position[2] = entry[PaintEntry_Z];
            float normal[3];
            normal[0] = entry[PaintEntry_NormalX];
            normal[1] = entry[PaintEntry_NormalY];
            normal[2] = entry[PaintEntry_NormalZ];
            SendDecal(client, position, normal, entry[PaintEntry_Hitbox], entry[PaintEntry_HammerId], entry[PaintEntry_Colour], entry[PaintEntry_Size]);
            sent++;
        }

        g_iRenderOffset[client] = index;
        if (index < paints.Length)
        {
            RequestFrame(Frame_DrawPaint, userid);
            return;
        }

        if (!g_bRenderStolenPaint[client])
        {
            g_bRenderStolenPaint[client] = true;
            g_iRenderOffset[client] = 0;
            if (sent >= PAINT_DECALS_PER_FRAME)
            {
                RequestFrame(Frame_DrawPaint, userid);
                return;
            }
            continue;
        }
    }

    g_bRenderActive[client] = false;
    if (g_bRenderAgain[client])
    {
        g_bRenderAgain[client] = false;
        QueuePaintRedraw(client, PAINT_REDRAW_DELAY);
    }
}

void ShowPaintMenu(int client)
{
    // Ask again each time, so the entry goes away once they have raised it.
    ApplyPaintDecalLimits(client, false);
    Menu menu = new Menu(PaintMenuHandler);
    char title[128];
    FormatEx(title, sizeof(title), "Paint  [%d / %d]", g_iLiveCount[client], g_cvLimit.IntValue);
    menu.SetTitle(title);
    menu.AddItem("colour", "Paint colour");
    menu.AddItem("size", "Paint size");
    menu.AddItem("erase", g_bErasing[client] ? "Stop erasing" : "Start erasing");
    menu.AddItem("steal", "Steal paint");
    menu.AddItem("clear", "Clear my paint");
    if (WantsMoreDecals(client))
    {
        char label[64];
        FormatEx(label, sizeof(label), "Your decal limit is %d - fix it", g_iMaxModelDecal[client]);
        menu.AddItem("decals", label);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

public int PaintMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char choice[16];
        menu.GetItem(item, choice, sizeof(choice));
        if (StrEqual(choice, "decals"))
        {
            Shavit_PrintToChat(client, "Your game keeps only %s%d%s decals on models, so paint disappears as you add it.",
                g_ChatStrings.sVariable2, g_iMaxModelDecal[client], g_ChatStrings.sText);
            Shavit_PrintToChat(client, "Paste this in console: %sr_maxmodeldecal 2048", g_ChatStrings.sVariable2);
            Shavit_PrintToChat(client, "The server is not allowed to set it for you; this one is yours to change.");
            ApplyPaintDecalLimits(client, false);
            return 0;
        }
        if (StrEqual(choice, "colour"))
        {
            ShowColourMenu(client);
        }
        else if (StrEqual(choice, "size"))
        {
            ShowSizeMenu(client);
        }
        else if (StrEqual(choice, "erase"))
        {
            if (g_bErasing[client])
            {
                FinishErasing(client);
                PrintPaint(client, "Eraser disabled.");
            }
            else if (CanEditPaint(client))
            {
                g_bPainting[client] = false;
                BeginErasing(client);
                PrintPaint(client, "Eraser enabled. Point at your paint.");
            }
            ShowPaintMenu(client);
        }
        else if (StrEqual(choice, "steal"))
        {
            ShowStealMenu(client);
        }
        else if (StrEqual(choice, "clear"))
        {
            ShowClearConfirmMenu(client);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowColourMenu(int client)
{
    Menu menu = new Menu(ColourMenuHandler);
    menu.SetTitle("Paint colour");
    for (int colour = 0; colour < sizeof(g_sColourNames); colour++)
    {
        if (!IsSelectablePaintColour(colour))
        {
            continue;
        }

        char info[8];
        IntToString(colour, info, sizeof(info));
        menu.AddItem(info, g_sColourNames[colour]);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int ColourMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        g_iColour[client] = ClampColour(StringToInt(info));
        SetClientCookieInt(client, g_ckColour, g_iColour[client]);
        PrintPaintColourSelected(client, g_iColour[client]);
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ShowSizeMenu(int client)
{
    Menu menu = new Menu(SizeMenuHandler);
    menu.SetTitle("Paint size");
    for (int size = 0; size < sizeof(g_sSizeNames); size++)
    {
        char info[8];
        IntToString(size, info, sizeof(info));
        menu.AddItem(info, g_sSizeNames[size]);
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int SizeMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        g_iSize[client] = ClampSize(StringToInt(info));
        SetClientCookieInt(client, g_ckSize, g_iSize[client]);
        SetClientCookieInt(client, g_ckSizeLayout, PAINT_SIZE_LAYOUT_VERSION);
        PrintPaintSizeSelected(client, g_iSize[client]);
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

public int StealMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char steamId[64];
        menu.GetItem(item, steamId, sizeof(steamId));
        BeginStealPaintBySteamId(client, steamId);
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void BeginStealPaintBySteamId(int client, const char[] steamId)
{
    if (!CanManagePaint(client) || steamId[0] == '\0')
    {
        return;
    }

    char escapedSteamId[128], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(g_sMap, escapedMap, sizeof(escapedMap));

    char query[768];
    FormatEx(query, sizeof(query), "SELECT pos_x, pos_y, pos_z, normal_x, normal_y, normal_z, hitbox, hammerid, colour, size FROM okpaint_decals WHERE steamid = '%s' AND map = '%s' ORDER BY id ASC LIMIT %d", escapedSteamId, escapedMap, g_cvLimit.IntValue + 1);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(g_sMap);
    g_hDatabase.Query(SQL_StealPaintCallback, query, pack);
}

public void SQL_StealPaintCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    char map[PLATFORM_MAX_PATH];
    pack.ReadString(map, sizeof(map));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !StrEqual(map, g_sMap))
    {
        return;
    }

    if (results == null)
    {
        LogError("okpaint steal query failed: %s", error);
        PrintPaint(client, "Could not read that paint.");
        return;
    }

    ArrayList copy = new ArrayList(PAINT_ENTRY_SIZE);
    while (results.FetchRow())
    {
        any entry[PaintEntry];
        entry[PaintEntry_Id] = 0;
        entry[PaintEntry_X] = results.FetchFloat(0);
        entry[PaintEntry_Y] = results.FetchFloat(1);
        entry[PaintEntry_Z] = results.FetchFloat(2);
        entry[PaintEntry_NormalX] = results.FetchFloat(3);
        entry[PaintEntry_NormalY] = results.FetchFloat(4);
        entry[PaintEntry_NormalZ] = results.FetchFloat(5);
        entry[PaintEntry_Hitbox] = results.FetchInt(6);
        entry[PaintEntry_HammerId] = results.FetchInt(7);
        entry[PaintEntry_Colour] = ClampColour(results.FetchInt(8));
        entry[PaintEntry_Size] = ClampSize(results.FetchInt(9));
        entry[PaintEntry_Alive] = 1;
        copy.PushArray(entry, sizeof(entry));
    }

    if (copy.Length == 0)
    {
        delete copy;
        PrintPaint(client, "That player has no saved paint on this map.");
        return;
    }

    if (g_iLiveCount[client] + copy.Length > g_cvLimit.IntValue)
    {
        delete copy;
        PrintPaint(client, "That paint exceeds your remaining limit of {green}%d{text} decals.", g_cvLimit.IntValue - g_iLiveCount[client]);
        return;
    }

    SetStolenPaint(client, copy);
}

void SetStolenPaint(int client, ArrayList copy)
{
    ResetStolenPaint(client);
    g_hStolenPaints[client] = copy;

    for (int item = 0; item < copy.Length; item++)
    {
        any entry[PaintEntry];
        copy.GetArray(item, entry, sizeof(entry));
        float position[3];
        position[0] = entry[PaintEntry_X];
        position[1] = entry[PaintEntry_Y];
        position[2] = entry[PaintEntry_Z];
        AddStolenGridEntry(client, position, item);
        g_iStolenCount[client]++;
    }

    QueuePaintRedraw(client, 0.0);
    PrintPaint(client, "Previewing {green}%d{text} stolen decals. Paint to save them.", g_iStolenCount[client]);
}

void ShowClearConfirmMenu(int client)
{
    Menu menu = new Menu(ClearConfirmHandler);
    menu.SetTitle("Clear all saved paint on this map?");
    menu.AddItem("yes", "Yes, clear my paint");
    menu.AddItem("no", "No");
    menu.Display(client, 20);
}

public int ClearConfirmHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char choice[8];
        menu.GetItem(item, choice, sizeof(choice));
        if (StrEqual(choice, "yes"))
        {
            ClearClientPaint(client);
        }
        ShowPaintMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void ClearClientPaint(int client)
{
    if (!CanManagePaint(client))
    {
        return;
    }

    ResetClientPaint(client, false);
    ClientCommand(client, "r_cleardecals");

    char steamId[64], escapedSteamId[128], escapedMap[PLATFORM_MAX_PATH * 2 + 1];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
    g_hDatabase.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));
    g_hDatabase.Escape(g_sMap, escapedMap, sizeof(escapedMap));

    char query[512];
    FormatEx(query, sizeof(query), "DELETE FROM okpaint_decals WHERE steamid = '%s' AND map = '%s'", escapedSteamId, escapedMap);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iGeneration[client]);
    g_hDatabase.Query(SQL_ClearPaintCallback, query, pack);
}

public void SQL_ClearPaintCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int generation = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (results == null)
    {
        LogError("okpaint clear failed: %s", error);
        if (client > 0)
        {
            PrintPaint(client, "Could not clear your saved paint. See server logs.");
        }
        return;
    }

    if (client <= 0 || generation != g_iGeneration[client])
    {
        return;
    }

    g_bLoaded[client] = true;
    PrintPaint(client, "Cleared your saved paint for this map.");
}

public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("okpaint database query failed: %s", error);
    }
}

void ResetClientPaint(int client, bool destroy)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_iGeneration[client]++;
    g_iLiveCount[client] = 0;
    g_iStolenCount[client] = 0;
    g_iRenderOffset[client] = 0;
    g_iLastEraseTick[client] = 0;
    g_iLastEraseHintTick[client] = 0;
    g_iErasedThisSession[client] = 0;
    g_iStrokeColour[client] = 0;
    g_bLoadTimerPending[client] = false;
    g_bLoaded[client] = false;
    g_bPainting[client] = false;
    g_bErasing[client] = false;
    g_bRenderActive[client] = false;
    g_bRenderQueued[client] = false;
    g_bRenderAgain[client] = false;
    g_bRenderStolenPaint[client] = false;
    g_bEraseRedrawPending[client] = false;
    g_fRenderAt[client] = 0.0;

    ClearGrid(client);
    if (destroy)
    {
        delete g_hPaints[client];
    }
    else if (g_hPaints[client] != null)
    {
        g_hPaints[client].Clear();
    }

    delete g_hStolenPaints[client];
}

void ClearGrid(int client)
{
    if (g_hGridBuckets[client] != null)
    {
        for (int item = 0; item < g_hGridBuckets[client].Length; item++)
        {
            ArrayList bucket = g_hGridBuckets[client].Get(item);
            delete bucket;
        }
    }
    delete g_hGridBuckets[client];
    delete g_hGrid[client];

    ClearStolenGrid(client);
}

void ClearStolenGrid(int client)
{
    if (g_hStolenGridBuckets[client] != null)
    {
        for (int item = 0; item < g_hStolenGridBuckets[client].Length; item++)
        {
            ArrayList bucket = g_hStolenGridBuckets[client].Get(item);
            delete bucket;
        }
    }
    delete g_hStolenGridBuckets[client];
    delete g_hStolenGrid[client];
}

void ResetStolenPaint(int client)
{
    g_iStolenCount[client] = 0;
    delete g_hStolenPaints[client];
    ClearStolenGrid(client);
}

int ClampColour(int colour)
{
    return (colour >= 0 && colour < sizeof(g_sColourNames)) ? colour : PAINT_COLOUR_DEFAULT;
}

bool IsSelectablePaintColour(int colour)
{
    return colour != 2 && colour != 3 && colour != 5 && colour != 8;
}

int ClampSize(int size)
{
    return (size >= 0 && size < sizeof(g_sSizeNames)) ? size : 0;
}

int ConvertSavedSize(int size, int layoutVersion)
{
    if (layoutVersion >= 2)
    {
        switch (size)
        {
            case 0, 1: return 0;
            case 2: return 1;
            case 3, 4: return 2;
        }
        return 0;
    }

    switch (size)
    {
        case 0: return 0;
        case 1: return 1;
        case 2: return 2;
    }
    return 0;
}

void SetClientCookieInt(int client, Cookie cookie, int value)
{
    char buffer[12];
    IntToString(value, buffer, sizeof(buffer));
    SetClientCookie(client, cookie, buffer);
}
