# ffmpeg-splitter
FFmpeg Splitter: A PowerShell and Windows Forms front end for FFmpeg. It lets you split, convert and combine media files without typing commands, and you can review and edit the generated FFmpeg command before running it. Requires: Windows, PowerShell 5.1+, FFmpeg.
# FFmpeg Splitter

A PowerShell and Windows Forms front end for FFmpeg. Split, convert and combine video and audio, edit audio, and change BPM, without typing FFmpeg commands. You can review and edit the generated command before running it.

## Requirements
- Windows with PowerShell 5.1 or newer
- FFmpeg (includes ffprobe), installed **before** you run the tool

## 1. Install FFmpeg
Open PowerShell and run:

```powershell
winget install Gyan.FFmpeg
```

Close and reopen PowerShell, then check it works:

```powershell
ffmpeg -version
```

(Or download FFmpeg from https://ffmpeg.org/download.html and add its `bin` folder to your PATH.)

## 2. Run the tool
Download `FFmpegSplitter27.ps1`, open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\FFmpegSplitter27.ps1
```

## Features
- Split, convert and combine video and audio
- Audio editing, extract/combine and BPM changer tabs
- Presets, undo and an editable command preview
