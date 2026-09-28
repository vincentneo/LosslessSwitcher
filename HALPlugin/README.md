# LSOutput.driver: Exclusive Mode's virtual output device

An AudioServerPlugIn (HAL plug-in) based on Apple's NullAudio sample (MIT, LICENSE-NullAudio.txt).
It shows up as **LosslessSwitcher** in Audio MIDI Setup: a 2-channel output whose mix is looped
back to its 2-channel input, at 44.1-192 kHz, with a clock the renderer steers to the DAC.

Custom properties (CFNumber / CFDictionary, device object):
- `'LSrs'` rate scalar (AudioTimeStamp.mRateScalar meaning, 0.99-1.01): the clock lock
- `'LSst'` status snapshot (clock, loopback counters)
- `'LShd'` hold experiments (research only; unused by the engine)
- `'LSac'` attached renderer pid (0 = none). The device can be the **default output only while a
  renderer is attached**; it is cleared when that process stops being a client of the device.
  Never the default input (the loopback) or the alert-sound device.

Build: `./build.sh` (clang, ad-hoc signed; the app's build scripts run it and copy the bundle into
Contents/Resources). Test in-process before installing: `clang -O1 -o harness harness.c -framework
CoreAudio -framework CoreFoundation && ./harness LSOutput.driver`. Install/update/remove from the app
(menu "Virtual Output Device", one administrator prompt, restarts coreaudiod) or by hand:
`sudo ditto LSOutput.driver /Library/Audio/Plug-Ins/HAL/LSOutput.driver && sudo chmod -R a+rX
/Library/Audio/Plug-Ins/HAL/LSOutput.driver && sudo killall coreaudiod` (coreaudiod loads plug-ins as
_coreaudiod, so the bundle must be world-readable).
