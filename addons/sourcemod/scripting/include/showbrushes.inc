#if defined _showbrushes_included
 #endinput
#endif
#define _showbrushes_included

/**
 * Resolve what the client is aiming at among the brushes showbrushes draws.
 *
 * Covers trigger brushes and world clip brushes alike. Only reports a brush
 * this client is currently being shown, so a brush type they have turned off,
 * or one hidden by a confirmed selection, is never returned. The ray stops at
 * the first opaque world surface, and a player standing inside a brush gets
 * the face they are looking at.
 *
 * The result is cached per client per frame, so calling it every tick costs
 * one trace per client.
 *
 * @param client    Client index.
 * @param position  World space point on the brush surface the ray hits.
 * @param normal    Outward surface normal at that point, facing the viewer.
 * @param inside    Optional. True when the player is standing in the brush, so
 *                  the face they are looking at is its inner surface. A decal
 *                  ray has to be aimed from the other side in that case.
 * @param brushId   Identifier of the brush that was hit, stable across map
 *                  loads. Positive is the hammer id of a trigger entity,
 *                  negative is a world clip brush. Zero when nothing was hit.
 * @return          Entity index of the prop currently rendering that brush for
 *                  this client, or 0 if nothing applies.
 */
native int ShowBrushes_TraceBrush(int client, float position[3], float normal[3], int &brushId, bool &inside = false);

/**
 * The prop currently drawing a brush for a client, by the identifier that
 * ShowBrushes_TraceBrush handed out earlier.
 *
 * Use this to put a decal back on a brush after a map load, where there is a
 * stored position but no crosshair to trace from. Returns 0 when the brush is
 * gone or this client is not being shown it, so the caller can skip it rather
 * than draw it somewhere wrong.
 *
 * @param client    Client index.
 * @param brushId   Identifier from ShowBrushes_TraceBrush.
 * @return          Entity index of the prop, or 0 if none applies.
 */
native int ShowBrushes_GetProxyForBrush(int client, int brushId);

public SharedPlugin __pl_showbrushes =
{
	name = "showbrushes",
	file = "showbrushes.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_showbrushes_SetNTVOptional()
{
	MarkNativeAsOptional("ShowBrushes_TraceBrush");
	MarkNativeAsOptional("ShowBrushes_GetProxyForBrush");
}
#endif
