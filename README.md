<p align="center">
  <img width="550" alt="header image with app icon" src="https://user-images.githubusercontent.com/23420208/164895903-1c95fe89-6198-433a-9100-8d9af32ca24f.png">

</p>

#  

LosslessSwitcher switches your current audio device's sample rate to match the currently playing lossless song on your Apple Music app, automatically.

Let's say if the next song that you are playing, is a Hi-Res Lossless track with a sample rate of 192kHz, LosslessSwitcher will switch your device to that sample rate as soon as possible. 

The opposite happens, when the next track happens to have a lower sample rate. 

## Installation
Simply go to the Releases page of this repository. [(Link to latest release)](https://github.com/vincentneo/LosslessSwitcher/releases/latest)

### Alternatively, try the beta! [(link)](https://github.com/vincentneo/LosslessSwitcher/releases/)

Drag the app to your Applications folder. If you wish to have it running when logging in, you should be able to add LosslessSwitcher in System Preferences:

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

### Why make this?
Ever since Apple Music Lossless launched along with macOS 11.4, the app would never switch the sample rates according to the song that was playing. A trip down to the Audio MIDI Setup app was required.
This still happens today, with macOS 12.3.1, despite iOS's Music app having such an ability.

I think this improvement might be well appreciated by many, hence this project is here, free and open source.

## Prerequisites
Due to how the app works, this app is not, and cannot be sandboxed.
It also has the following requirement, due to the use of `OSLog` API: 
- The user running LosslessSwitcher must be an admin. This is not tested and assumed due to this [Apple Developer Forums thread](https://developer.apple.com/forums/thread/677068).
- Apple Music app must have Lossless mode on. (well, of course)

Other than that, it should run on any Mac running macOS 11.4 or later.

## Disclaimer
By using LosslessSwitcher, you agree that under no circumstances will the developer or any contributors be held responsible or liable in any way for any claims, damages, losses, expenses, costs or liabilities whatsoever or any other consequences suffered by you or incurred by you directly or indirectly in connection with any form of usages of LosslessSwitcher.

## Devices tested
I did not test on any Macs running macOS 11, ~~or any Apple Silicon based Macs (I don't have one 😢)~~  Use at your own risk.

UPDATE: A [reddit user](https://www.reddit.com/r/audiophile/comments/t6l3pb/comment/i69v5fe/?utm_source=share&utm_medium=web2x&context=3) has updated to me that LosslessSwitcher is working on Apple Silicon Macs! Thanks!

| CPU             | Mac Model                                            | macOS Version  | Beta? | Audio Device    |
| --------------- | ---------------------------------------------------- | -------------- | ----- | --------------- |
|      Intel      | Mac Mini (2018)                                      | 12.2 / 12.4    | No    | Denon PMA-50    |
|      Intel      | MacBook Pro 13 inch (2018)                           | 12.3.1         | No    | Denon PMA-50    |
|      Intel      | MacBook Pro 13 inch, four Thunderbolt 3 ports (2016) | 12.3.1         | No    | Topping DX7 Pro |
|  Apple Silicon  | MacBook Pro 13 inch (M1, 2020)                       | 12.3.1         | No    | FX Audio DAC-X6 |
|      Intel      | MacBook Pro 15 inch (2016)                           | 12.4           | No    | Topping D30Pro  |
|      Intel      | Hackintosh (XPS 9570, i7-8750H)                      | 12.4           | No    | Universal Audio Apollo X4 & FiiO Q3 & FiiO M5 (DAC mode) |
|  Apple Silicon  | Mac mini (M1, 2020)                                  | 13.0            | Developer Beta 2 (22A5286j) | Topping D50s    |

You can add to this list by modifying this README and opening a new pull request!

## License
LosslessSwitcher is licensed under GPL-3.0.

## Love the idea of this?
If you appreciate the development of this application, feel free to spread the word around so more people get to know about LosslessSwitcher. 
You can also show your support by [sponsoring](https://github.com/sponsors/vincentneo) this project!

## Dependencies
- [Sweep](https://github.com/JohnSundell/Sweep), by @JohnSundell, a easy to use Swift `String` scanner.
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio), by @rnine, a framework that makes `CoreAudio` so much easier to use.

