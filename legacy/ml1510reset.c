/*
 * ml1510reset - re-enumerate a USB printer to clear a stuck interface state.
 *
 * Some Samsung GDI printers (ML-1510/1520/1610/1710/2010/... families) are
 * left in a state after each job where the next job is ignored until the USB
 * cable is unplugged and replugged.  Replugging makes the USB stack
 * re-enumerate the device, which resets it.  This tool performs exactly that
 * re-enumeration in software through IOKit (the same call the libusb
 * "reset" uses on macOS: IOUSBDeviceInterface::USBDeviceReEnumerate).
 *
 * Build:
 *   clang -O2 -Wall -framework IOKit -framework CoreFoundation \
 *         -o ml1510reset ml1510reset.c
 *
 * Usage:
 *   ml1510reset [-s serial] [-w seconds] [-v]
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define DEFAULT_VID 0x04e8
#define DEFAULT_PID 0x3242

static int g_verbose = 0;

static void logmsg(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

/*
 * Find the IOUSBHostDevice/IOUSBDevice matching vendor/product (and serial).
 */
static io_service_t find_device(int vid, int pid, const char *serial)
{
  const char *classes[] = { kIOUSBDeviceClassName, "IOUSBHostDevice", NULL };

  for (int c = 0; classes[c]; c++)
  {
    CFMutableDictionaryRef match = IOServiceMatching(classes[c]);
    if (!match)
      continue;

    CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS)
      continue;

    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != 0)
    {
      int ok = 1;
      if (serial && *serial)
      {
        ok = 0;
        CFTypeRef s = IORegistryEntryCreateCFProperty(
            svc, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
        if (s && CFGetTypeID(s) == CFStringGetTypeID())
        {
          char buf[256];
          if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8))
            ok = (strcmp(buf, serial) == 0);
        }
        if (s)
          CFRelease(s);
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

/*
 * Obtain IOUSBDeviceInterface187 (the first version that exposes
 * USBDeviceReEnumerate).
 */
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
  {
    /* kIOUSBDeviceInterfaceIDxxx are CFUUIDRef objects */
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(ids[i]), (LPVOID *)&dev);
  }

  IODestroyPlugInInterface(plug);
  return dev;
}

static int reset_once(int vid, int pid, const char *serial)
{
  io_service_t svc = find_device(vid, pid, serial);
  if (!svc)
    return 2;

  IOUSBDeviceInterface187 **dev = plug_device(svc);
  if (!dev)
  {
    logmsg("ml1510reset: could not get IOUSBDeviceInterface187");
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
    logmsg("ml1510reset: USBDeviceOpen failed: 0x%08x", kr);
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
    logmsg("ml1510reset: USBDeviceReEnumerate failed: 0x%08x", kr);
    return 5;
  }
  return 0;
}

static void usage(const char *prog)
{
  fprintf(stderr,
          "Usage: %s [-s serial] [-w seconds] [-d seconds] [-v]\n"
          "  -s serial   only match this USB serial number\n"
          "  -w seconds  wait for the device to come back after the reset\n"
          "  -d seconds  extra settle time after the device is back\n"
          "  -v          verbose\n",
          prog);
}

int main(int argc, char **argv)
{
  int vid = DEFAULT_VID, pid = DEFAULT_PID;
  const char *serial = NULL;
  int wait_secs = 0;
  int settle = 0;
  int ch;

  while ((ch = getopt(argc, argv, "s:w:d:vh")) != -1)
  {
    switch (ch)
    {
      case 's': serial = optarg; break;
      case 'w': wait_secs = atoi(optarg); break;
      case 'd': settle = atoi(optarg); break;
      case 'v': g_verbose++; break;
      case 'h':
      default:  usage(argv[0]); return 1;
    }
  }

  if (g_verbose)
    logmsg("ml1510reset: looking for %04x:%04x%s%s", vid, pid,
           serial ? " serial=" : "", serial ? serial : "");

  int rc = reset_once(vid, pid, serial);
  if (rc == 2)
  {
    logmsg("ml1510reset: device %04x:%04x not present", vid, pid);
    return 0; /* not fatal: the print backend will wait for the device */
  }
  if (rc != 0)
    return rc;

  if (g_verbose)
    logmsg("ml1510reset: re-enumeration requested%s",
           wait_secs > 0 ? ", waiting..." : "");

  if (wait_secs > 0)
  {
    int back = 0;
    for (int i = 0; i < wait_secs * 10; i++)
    {
      usleep(100000);
      io_service_t svc = find_device(vid, pid, serial);
      if (svc)
      {
        IOObjectRelease(svc);
        back = 1;
        break;
      }
    }
    if (!back)
    {
      logmsg("ml1510reset: device did not come back within %d s", wait_secs);
      return 6;
    }
    if (g_verbose)
      logmsg("ml1510reset: device is back");
  }

  /*
   * Let the printer finish its own initialisation before the backend opens it.
   */
  if (settle > 0)
  {
    if (g_verbose)
      logmsg("ml1510reset: settling %d s", settle);
    sleep(settle);
  }

  return 0;
}
