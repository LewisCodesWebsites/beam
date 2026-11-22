# Beam

An ad-free iPhone app that sends video links to a DLNA TV (built for a Panasonic Viera, works with most smart TVs).

## Features
- Finds the TV on your wifi automatically (or type its IP)
- Paste a link and cast it
- Remote control: play/pause, back 10s, forward 30s, scrub bar, stop, TV volume
- Remembers your TV and your last 10 links
- Accepts links from apps that offer "Open in VLC / Infuse / Outplayer" (Beam registers those link types), so you can send streams straight from Nuvio

## Build
Push to `main` and GitHub Actions builds an unsigned `Beam.ipa` and publishes it to the `latest` release. Sign and install it with Feather.

## First run
1. Allow **Local Network** access when iOS asks (needed to talk to the TV). If you said no: Settings > Privacy & Security > Local Network > Beam.
2. Tap **Find my TV**. If it isn't found, type the TV's IP address (TV menu > Network > Network Status).
3. Paste a link and tap **Cast**.

## How it plays
Many older TVs (e.g. Panasonic FX600) can't open HTTPS links. Beam runs a small relay on the phone: the TV fetches the video from the phone over plain HTTP on your wifi, and Beam fetches it from the real link as the TV asks for each part (so seeking works). Keep Beam open while watching.

## Notes
- If you later install the real VLC, iOS may pick either app for `vlc://` links. Remove `vlc` and `vlc-x-callback` from `project.yml` if that bothers you.
- Error "can't play this file type": the TV doesn't support that video/audio format. Pick a stream with H.264 video and AAC or AC3 audio.
