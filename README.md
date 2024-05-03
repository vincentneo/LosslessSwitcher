<p align="center">
  <img width="550" alt="header image with app icon" src="https://user-images.githubusercontent.com/23420208/164895903-1c95fe89-6198-433a-9100-8d9af32ca24f.png">

</p>

#  

LosslessSwitcher switches your current audio device's sample rate to match the currently playing lossless song on your Apple Music app, automatically.

Let's say if the next song that you are playing, is a Hi-Res Lossless track with a sample rate of 192kHz, LosslessSwitcher will switch your device to that sample rate as soon as possible. 

The opposite happens, when the next track happens to have a lower sample rate. 

## Installation
Simply go to the Releases page of this repository or via [link to latest release](https://github.com/vincentneo/LosslessSwitcher/releases/latest)

Drag the app to your Applications folder. If you wish to have it running when logging in, you should be able to add LosslessSwitcher in System Settings:

```
> User & Groups > Login Items > Add LosslessSwitcher app
``` 

## App details

There isn't much going on, when it comes to the UI of the app, as most of the logic is to:
1. Read Apple Music's logs to know the song's sample rate.
2. Set the sample rate to the device that you are currently playing to.


As such, the app lives on your menu bar. The screenshot above shows it's only UI component that it offers, which is to show the sample rate that it has parsed from Apple Music's logs.

<img width="252" alt="app screenshot, with music note icon shown as UI button" src="https://user-images.githubusercontent.com/23420208/164895657-35a6d8a3-7e85-4c7c-bcba-9d03bfd88b4d.png">

If you wish, the sample rate can also be directly visible as the menu bar item.

<img width="252" alt="app screenshot with sample rate shown as UI button" src="https://user-images.githubusercontent.com/23420208/164896404-c6d27328-47e5-4eb3-bd8b-71e3c9013c46.png">

Do also note that:
- There may be short interuptions to your audio playback, during the time where the app attempts to switch the sample rates.
- Prolonged use on MacBooks may accelerate battery usages, due to the frequent querying of the latest sample rate.

Bit Depth switching is also supported, although, enabling it will reduce detection accuracy, hence, it is not recommended.

### Why make this?
Ever since Apple Music Lossless launched along with macOS 11.4, the app would never switch the sample rates according to the song that was playing. A trip down to the Audio MIDI Setup app was required.
This still happens today, with macOS 12.3.1, despite iOS's Music app having such an ability.

I think this improvement might be well appreciated by many, hence this project is here, free and open source.

## Prerequisites
Due to how the app works, this app is not, and cannot be sandboxed.
It also has the following requirement, due to the use of `OSLog` API: 
- The user running LosslessSwitcher must be an **admin**. This is not tested and assumed due to this [Apple Developer Forums thread](https://developer.apple.com/forums/thread/677068).
- Apple Music app must have Lossless mode on. (well, of course)

Other than that, it should run on any Mac running macOS 11.4 or later.

## Disclaimer
By using LosslessSwitcher, you agree that under no circumstances will the developer or any contributors be held responsible or liable in any way for any claims, damages, losses, expenses, costs or liabilities whatsoever or any other consequences suffered by you or incurred by you directly or indirectly in connection with any form of usages of LosslessSwitcher.

## Devices tested

Here are some device combinations tested to be working, by users of LosslessSwitcher.
Regardless, you are still reminded to use LosslessSwitcher at your own risk.

| CPU             | Mac Model                                            | macOS Version   | Beta macOS? | Audio Device    |
| --------------- | ---------------------------------------------------- | --------------- | ----------- | --------------- |
|      Intel      | MacBook Pro 13 inch (Early 2015, Dual Core i5)       | 11.6.2          | No    | Denon AVR-X4400H |
|      Intel      | Mac mini (2018)                                      | 12.2<br/>12.4   | No    | Denon PMA-50    |
|      Intel      | MacBook Pro 13 inch (2018)                           | 12.3.1          | No    | Denon PMA-50    |
|      Intel      | MacBook Pro 13 inch, four Thunderbolt 3 ports (2016) | 12.3.1          | No    | Topping DX7 Pro |
|  Apple Silicon  | MacBook Pro 13 inch (M1, 2020)                       | 12.3.1          | No    | FX Audio DAC-X6 |
|      Intel      | MacBook Pro 15 inch (2016)                           | 12.4            | No    | Topping D30Pro  |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 12.4            | No    | Meridian Explorer 2 |
|      Intel      | Hackintosh (XPS 9570, i7-8750H)                      | 12.4            | No    | Universal Audio Apollo X4<br/>FiiO Q3<br/>FiiO M5 (DAC mode) |
|      Intel      | MacBook Pro 13 inch (2016)                           | 12.4<br/>12.6.1 | No    | AudioQuest Dragonfly Cobalt  |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 12.4            | No    | iFi Zen DAC V2  |
|      Intel      | MacBook Pro 15 inch (2018)                           | 12.4            | No    | PS Audio Sprout |
|  Apple Silicon  | MacBook Air 13 inch (2020)                           | 12.5.1          | No    | Shanling M8 |
|  Apple Silicon  | Mac Studio (M1 Max, 2022)                            | 12.6            | No    | Focusrite Scarlett 18i8 (2nd Gen) | 
|      Intel      | MacBook Pro 16 inch (2019)                           | 12.6            | No    | Mytek Brooklyn+ DAC |
|      Intel      | Mac mini (Late 2014)                                 | 12.6.3          | No    | NAD C658  |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.0            | 22A5286j | Topping D50s    |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.0            | No    | iBasso DC06<br/>Khadass Tone 2 Pro |
|  Apple Silicon  | MacBook Pro 14 inch (M1 Pro, 2021)                   | 13.0<br/>13.0.1 | No    | Topping D10 Balanced |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.0.1          | No    | Fiio K7<br/>Fiio K5 Pro (AKM DAC)<br/>Topping EX5 |
|  Apple Silicon  | MacBook Pro 14 inch (2021)                           | 13.0.1          | No    | AudioQuest Dragonfly Black v1.5 |
|  Apple Silicon  | MacBook Air (M1, 2020)                               | 13.1            | No    | Schiit Bifrost 2 |
|      Intel      | MacBook Pro 15 inch (2018)                           | 13.1            | No    | Apogee Groove |
|  Apple Silicon  | iMac 24 inch (M1, 2021)                              | 13.1            | No    | SMSL PO100 |
|  Apple Silicon  | MacBook Pro 14 inch (2021)                           | 13.1            | No    | Chord Mojo |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.2            | No    | RME ADI-2 DAC FS |
|  Apple Silicon  | MacBook Pro 16 inch (M1 Max, 2021)                   | 13.2            | No    | M-Audio Fast Track |
|  Apple Silicon  | MacBook Pro 14 inch (M1 Pro, 2021)                   | 13.2            | No    | Topping D10s |    
|  Apple Silicon  | Mac Studio (M1 Max, 2022)                            | 13.2.1          | No    | RME ADI-2 PRO FS R (Black Edition) |
|      Intel      | 27-inch iMac (2017)                                  | 13.2.1          | No    | Chord Hugo M Scaler + TT2 Combo |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.2.1          | No    | Moondrop Moonriver 2 |
|  Apple Silicon  | MacBook Pro 13 inch (M1, 2020)                       | 13.3.1          | No    | Gustard X18 |            
|      Intel      | 27-inch iMac (Late 2014)                             | 13.3.1 (a)      | No    | SMSL M500 |  
|  Apple Silicon  | Mac mini (M2 Pro, 2023)                              | 13.5            | No    | FiiO K5 Pro |  
|  Apple Silicon  | Mac mini (M2 Pro, 2023)                              | 13.5            | No    | JDS Labs Element III MK 2 |  
|      Intel      | Mac mini (Late 2014)                                 | 13.5 (Opencore) | No    | VLink192 to Rega DAC |
|      Intel      | MacBook Pro 16 inch (2019)                           | 13.6.4          | No    | VMV D1SE |
|      Intel      | MacBook Pro 16 inch (2019)                           | 13.6.4          | No    | Denon AVR-X6700H |
|  Apple Silicon  | MacBook Pro 16 inch (M1 Max, 2021)                   | 14.0            | 23A5328b | Focusrite Scarlett 2i2 3rd Gen, Internal MacBook DAC |
|      Intel      | MacBook Air 13 inch (2020 i5 1.1 Ghz Quad-Core)      | 14.0            | 23A5328d | PreSonus Studio 1810c |
|  Apple Silicon  | MacBoox Air 13 inch (M1, 2020)                       | 14.0            | No    | Cambridge Audio DacMagic 100 |
|  Apple Silicon  | Mac Studio (M1 Max, 2022)                            | 14.4.1          | No    | Hidizs S9 PRO |
|  Apple Silicon  | MacBook Air 13 inch (M2, 2022)                       | 14.4.1          | No    | Cambridge Audio DacMagic XS |
|  Apple Silicon  | MacBook Pro 14 inch (M3 Pro, 2024)                   | 14.4.1          | No    | RME ADI-2 PRO FS R (Black Edition) |
|      Intel      | Mac Pro 6.1 (2013)                                   | 14.4.1 (Opencore)| No   | Cambridge Audio Edge NQ |
|      Intel      | MacBook Pro 15 inch (2012)                                   | 14.5 (Opencore)| 23F5074a   | Fiio KA3 |

You can add to this list by modifying this README and opening a new pull request!

Do note that Steven Slate Audio VSX software may not be fully compatible with LosslessSwitcher, and both software may interfere with each other. Please refer to discussion https://github.com/vincentneo/LosslessSwitcher/discussions/100 for more information.

## License
LosslessSwitcher is licensed under GPL-3.0.

## Love the idea of this?
If you appreciate the development of this application, feel free to spread the word around so more people get to know about LosslessSwitcher. 
You can also show your support by [sponsoring](https://github.com/sponsors/vincentneo) this project!

## Dependencies
- [Sweep](https://github.com/JohnSundell/Sweep), by @JohnSundell, an easy to use Swift `String` scanner.
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio), by @rnine, a framework that makes `CoreAudio` so much easier to use.
- [PrivateMediaRemote](https://github.com/PrivateFrameworks/MediaRemote), by @DimitarNestorov, in order to use private media remote framework.
