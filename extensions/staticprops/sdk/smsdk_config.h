#ifndef _INCLUDE_SOURCEMOD_EXTENSION_CONFIG_H_
#define _INCLUDE_SOURCEMOD_EXTENSION_CONFIG_H_

#define SMEXT_CONF_NAME			"StaticProps"
#define SMEXT_CONF_DESCRIPTION	"SourcePawn interface for static prop information"
#define SMEXT_CONF_VERSION		"20160805-4"
#define SMEXT_CONF_AUTHOR		"sigsegv"
#define SMEXT_CONF_URL			"https://github.com/sigsegv-mvm/"
#define SMEXT_CONF_LOGTAG		"STATICPROPS"
#define SMEXT_CONF_LICENSE		"Simplified BSD"
#define SMEXT_CONF_DATESTRING	__DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD

#endif // _INCLUDE_SOURCEMOD_EXTENSION_CONFIG_H_
