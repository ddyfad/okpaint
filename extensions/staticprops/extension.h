#ifndef _INCLUDE_EXTENSION_H_
#define _INCLUDE_EXTENSION_H_


#include <map>


#include "smsdk_ext.h"


#include <icvar.h>
#include <IStaticPropMgr.h>
#include <ivmodelinfo.h>
#include <fmtstr.h>
#include <collisionutils.h>


#define DEBUG_LOG(...) \
	if (cv_staticprop_debug.GetBool()) { \
		g_pSM->LogMessage(myself, __VA_ARGS__); \
	}


extern ICvar *icvar;
extern IStaticPropMgrServer *staticpropmgr;
extern IVModelInfo *modelinfo;

extern ConVar cv_staticprop_debug;


class ExtStaticProps : public SDKExtension, public IConCommandBaseAccessor
{
public:
	virtual bool SDK_OnLoad(char *error, size_t maxlen, bool late);
	virtual void SDK_OnAllLoaded();
#if defined SMEXT_CONF_METAMOD
	virtual bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late);
#endif

	virtual bool RegisterConCommandBase(ConCommandBase *pCommand) override;
};

#endif // _INCLUDE_EXTENSION_H_
