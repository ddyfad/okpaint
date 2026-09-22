// Symbols Valve's prebuilt libs bind to glibc newer than the servers' 2.35,
// defined locally at hidden visibility. fmod is pinned back with .symver.
__asm__(".symver fmod,fmod@GLIBC_2.0");

extern "C" {

double sqrt(double);
double acos(double);
double asin(double);
double atan2(double, double);
double fmod(double, double);

#define LOCAL __attribute__((visibility("hidden")))

LOCAL float sqrtf(float x)              { return (float)sqrt(x); }
LOCAL float acosf(float x)              { return (float)acos(x); }
LOCAL float asinf(float x)              { return (float)asin(x); }
LOCAL float atan2f(float y, float x)    { return (float)atan2(y, x); }
LOCAL float fmodf(float x, float y)     { return (float)fmod(x, y); }

}
