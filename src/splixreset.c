/*
 * splixreset - re-enumerate a USB printer so it stops getting "stuck" after
 *              a print job.
 *
 * Many Samsung QPDL/SPL (GDI) printers on macOS need the USB cable to be
 * unplugged and replugged before they accept a second job.  Replugging makes
 * the USB stack re-enumerate the device, which resets it.  This tool performs
 * that re-enumeration in software through IOKit - the same call the libusb
 * "reset" uses on macOS: IOUSBDeviceInterface::USBDeviceReEnumerate.
 *
 * Build (universal):
 *   clang -O2 -arch arm64  -framework IOKit -framework CoreFoundation -o a src/splixreset.c
 *   clang -O2 -arch x86_64 -framework IOKit -framework CoreFoundation -o b src/splixreset.c
 *   lipo -create a b -output splixreset
 *
 * Usage:
 *   splixreset [-u usb-uri] [-s serial] [-n name] [-V vid] [-P pid]
 *              [-w seconds] [-d seconds] [-v]
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define SAMSUNG_VID 0x04e8

static int g_verbose = 0;

static void logmsg(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

static int ci_contains(const char *hay, const char *needle)
{
  size_t nl = strlen(needle);
  if (!nl)
    return 1;
  for (const char *p = hay; *p; p++)
  {
    size_t i = 0;
    while (i < nl && p[i] &&
           tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i]))
      i++;
    if (i == nl)
      return 1;
  }
  return 0;
}

/* Percent-decode URI component in place-safe fashion (returns malloc'd copy). */
static char *pct_decode(const char *in)
{
  size_t n = strlen(in);
  char *out = malloc(n + 1);
  size_t j = 0;
  if (!out)
    return NULL;
  for (size_t i = 0; i < n; i++)
  {
    if (in[i] == '%' && i + 2 < n &&
        isxdigit((unsigned char)in[i + 1]) && isxdigit((unsigned char)in[i + 2]))
    {
      char h[3] = { in[i + 1], in[i + 2], 0 };
      out[j++] = (char)strtol(h, NULL, 16);
      i += 2;
    }
    else
      out[j++] = in[i];
  }
  out[j] = 0;
  return out;
}

/*
 * Parse a CUPS usb:// URI into make / model / serial / location.
 */
static void parse_uri(const char *uri, char **make, char **model,
                      char **serial, char **location)
{
  *make = *model = *serial = *location = NULL;
  if (strncmp(uri, "usb://", 6) != 0)
    return;

  char *dup = strdup(uri + 6);
  if (!dup)
    return;

  char *query = strchr(dup, '?');
  if (query)
    *query++ = 0;

  char *slash = strchr(dup, '/');
  if (slash)
  {
    *slash = 0;
    *model = pct_decode(slash + 1);
  }
  *make = pct_decode(dup);

  if (query)
  {
    char *save = NULL;
    for (char *tok = strtok_r(query, "&", &save); tok;
         tok = strtok_r(NULL, "&", &save))
    {
      if (strncmp(tok, "serial=", 7) == 0)
        *serial = pct_decode(tok + 7);
      else if (strncmp(tok, "location=", 9) == 0)
        *location = pct_decode(tok + 9);
    }
  }

  free(dup);
}

static int get_int_prop(io_service_t svc, CFStringRef key, int *out)
{
  CFTypeRef n = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
  if (!n || CFGetTypeID(n) != CFNumberGetTypeID())
  {
    if (n)
      CFRelease(n);
    return 0;
  }
  int ok = CFNumberGetValue((CFNumberRef)n, kCFNumberIntType, out);
  CFRelease(n);
  return ok;
}

static int get_str_prop(io_service_t svc, CFStringRef key, char *buf, size_t len)
{
  CFTypeRef s = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
  if (!s || CFGetTypeID(s) != CFStringGetTypeID())
  {
    if (s)
      CFRelease(s);
    return 0;
  }
  int ok = CFStringGetCString((CFStringRef)s, buf, len, kCFStringEncodingUTF8);
  CFRelease(s);
  return ok;
}

/*
 * Enumerate the USB device natively and apply the constraints in user space
 * (matching dictionary based filtering for idVendor alone does not work
 * reliably for IOUSBHostDevice).
 */
static io_service_t find_device(int have_vid, int vid, int have_pid, int pid,
                                const char *serial, const char *name)
{
  const char *classes[] = { kIOUSBDeviceClassName, "IOUSBHostDevice", NULL };

  for (int c = 0; classes[c]; c++)
  {
    CFMutableDictionaryRef match = IOServiceMatching(classes[c]);
    if (!match)
      continue;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS)
      continue;

    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != 0)
    {
      int ok = 1;
      int got;

      if (ok && have_vid)
      {
        ok = get_int_prop(svc, CFSTR("idVendor"), &got) && got == vid;
      }
      if (ok && have_pid)
      {
        ok = get_int_prop(svc, CFSTR("idProduct"), &got) && got == pid;
      }
      if (ok && serial && *serial)
      {
        char buf[512] = "";
        ok = get_str_prop(svc, CFSTR("USB Serial Number"), buf, sizeof(buf)) &&
             strcmp(buf, serial) == 0;
      }
      if (ok && name && *name)
      {
        char buf[512] = "";
        ok = get_str_prop(svc, CFSTR("USB Product Name"), buf, sizeof(buf)) &&
             ci_contains(buf, name);
      }

      if (ok)
      {
        IOObjectRelease(iter);
        return svc;
      }
      IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
  }
  return 0;
}

static IOUSBDeviceInterface187 **plug_device(io_service_t svc)
{
  IOCFPlugInInterface **plug = NULL;
  SInt32 score = 0;

  if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                        kIOCFPlugInInterfaceID, &plug,
                                        &score) != KERN_SUCCESS || !plug)
    return NULL;

  IOUSBDeviceInterface187 **dev = NULL;
  CFUUIDRef ids[] = {
      kIOUSBDeviceInterfaceID187, kIOUSBDeviceInterfaceID197,
      kIOUSBDeviceInterfaceID245, kIOUSBDeviceInterfaceID300,
      kIOUSBDeviceInterfaceID500,
  };
  for (size_t i = 0; i < sizeof(ids) / sizeof(ids[0]) && !dev; i++)
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(ids[i]), (LPVOID *)&dev);

  IODestroyPlugInInterface(plug);
  return dev;
}

static int reset_once(int have_vid, int vid, int have_pid, int pid,
                      const char *serial, const char *name)
{
  io_service_t svc = find_device(have_vid, vid, have_pid, pid, serial, name);
  if (!svc)
    return 2;

  IOUSBDeviceInterface187 **dev = plug_device(svc);
  if (!dev)
  {
    logmsg("splixreset: could not get IOUSBDeviceInterface187");
    IOObjectRelease(svc);
    return 3;
  }

  IOReturn kr = kIOReturnError;
  for (int i = 0; i < 5; i++)
  {
    kr = (*dev)->USBDeviceOpen(dev);
    if (kr == kIOReturnSuccess)
      break;
    if (kr != kIOReturnExclusiveAccess && kr != kIOReturnNotOpen)
      break;
    usleep(500000);
  }

  if (kr != kIOReturnSuccess)
  {
    logmsg("splixreset: USBDeviceOpen failed: 0x%08x", kr);
    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return 4;
  }

  kr = (*dev)->USBDeviceReEnumerate(dev, 0);

  (*dev)->USBDeviceClose(dev);
  (*dev)->Release(dev);
  IOObjectRelease(svc);

  if (kr != kIOReturnSuccess)
  {
    logmsg("splixreset: USBDeviceReEnumerate failed: 0x%08x", kr);
    return 5;
  }
  return 0;
}

static void usage(const char *prog)
{
  fprintf(stderr,
          "Usage: %s [-u usb-uri] [-s serial] [-n name] [-V vid] [-P pid]\n"
          "          [-w seconds] [-d seconds] [-v]\n"
          "  -u uri    CUPS usb:// device URI of the printer to reset\n"
          "  -s serial USB serial number to match\n"
          "  -n name   substring of the USB product name to match\n"
          "  -V vid    USB vendor id (hex)\n"
          "  -P pid    USB product id (hex)\n"
          "  -w secs   wait for the device to come back after the reset\n"
          "  -d secs   extra settle time after the device is back\n"
          "  -v        verbose\n", prog);
}

int main(int argc, char **argv)
{
  const char *uri = NULL;
  const char *opt_serial = NULL, *opt_name = NULL;
  int have_vid = 0, have_pid = 0;
  int vid = 0, pid = 0;
  int wait_secs = 0, settle = 0;
  char *uri_serial = NULL, *uri_model = NULL, *uri_make = NULL, *uri_loc = NULL;
  int ch;

  while ((ch = getopt(argc, argv, "u:s:n:V:P:w:d:vh")) != -1)
  {
    switch (ch)
    {
      case 'u': uri = optarg; break;
      case 's': opt_serial = optarg; break;
      case 'n': opt_name = optarg; break;
      case 'V': vid = (int)strtol(optarg, NULL, 16); have_vid = 1; break;
      case 'P': pid = (int)strtol(optarg, NULL, 16); have_pid = 1; break;
      case 'w': wait_secs = atoi(optarg); break;
      case 'd': settle = atoi(optarg); break;
      case 'v': g_verbose++; break;
      case 'h':
      default:  usage(argv[0]); return 1;
    }
  }

  const char *serial = opt_serial;
  const char *name = opt_name;

  if (uri && *uri)
  {
    parse_uri(uri, &uri_make, &uri_model, &uri_serial, &uri_loc);
    if (!uri_make)
    {
      if (g_verbose)
        logmsg("splixreset: not a usb:// URI (%s), nothing to do", uri);
      return 0;
    }
    if (!serial && uri_serial)
      serial = uri_serial;
    if (!name && uri_model)
      name = uri_model;
  }

  /* Default to any Samsung USB device if nothing else was specified. */
  if (!have_vid && !have_pid && !serial && !name)
  {
    have_vid = 1;
    vid = SAMSUNG_VID;
  }
  else if (!have_vid && uri_make && ci_contains(uri_make, "samsung"))
  {
    have_vid = 1;
    vid = SAMSUNG_VID;
  }

  (void)uri_loc;

  if (g_verbose)
    logmsg("splixreset: looking for vid=%s%04x pid=%s%04x serial=%s name=%s",
           have_vid ? "" : "*", have_vid ? vid : 0,
           have_pid ? "" : "*", have_pid ? pid : 0,
           serial ? serial : "*", name ? name : "*");

  int rc = reset_once(have_vid, vid, have_pid, pid, serial, name);
  if (rc == 2)
  {
    logmsg("splixreset: no matching USB device found");
    return 0; /* not fatal: the backend will wait for the printer */
  }
  if (rc != 0)
    return rc;

  if (wait_secs > 0)
  {
    int back = 0;
    for (int i = 0; i < wait_secs * 10; i++)
    {
      usleep(100000);
      io_service_t svc = find_device(have_vid, vid, have_pid, pid, serial, name);
      if (svc)
      {
        IOObjectRelease(svc);
        back = 1;
        break;
      }
    }
    if (!back)
    {
      logmsg("splixreset: device did not come back within %d s", wait_secs);
      return 6;
    }
    if (g_verbose)
      logmsg("splixreset: device is back");
  }

  if (settle > 0)
  {
    if (g_verbose)
      logmsg("splixreset: settling %d s", settle);
    sleep(settle);
  }

  free(uri_make);
  free(uri_model);
  free(uri_serial);
  free(uri_loc);
  return 0;
}
